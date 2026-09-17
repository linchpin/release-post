#!/usr/bin/env bash
#
# Report a published GitHub release to a WordPress site, which writes the post.
#
# Every value arrives through the environment — see action.yml for why. The
# response is read as text before anything tries to parse it as JSON: this
# request crosses Cloudflare Access and a WAF before it reaches WordPress, and
# all three answer with HTML when they are unhappy. Treating a challenge page as
# JSON is how integrations like this fail in a way nobody can read from the log.

set -euo pipefail

# site-url is the origin; endpoint is the route path beneath it. The endpoint
# falls back to the reference route from the README contract. Trailing and
# leading slashes are normalised so "https://x.com/" + "wp-json/..." and
# "https://x.com" + "/wp-json/..." land on the same URL.
ENDPOINT_PATH="${ENDPOINT_PATH:-/wp-json/release-post/v1/post}"
ENDPOINT="${SITE_URL%/}/${ENDPOINT_PATH#/}"

fail() {
  echo "::error::$1"

  if [ "${FAIL_ON_ERROR}" = "true" ]; then
    exit 1
  fi

  # Report the outcome and let the release carry on.
  {
    echo "action=error"
    echo "post-id="
    echo "skipped-reason="
    echo "edit-url="
  } >>"${GITHUB_OUTPUT}"

  exit 0
}

# Not configured is a different state from configured and broken, and it is
# checked before anything else: a product nobody has set up yet should not be
# told its release notes are missing either.
#
# A repository that has never been given credentials would otherwise get an
# ::error:: annotation stapled to every release it cuts, and an error nobody can
# act on until two secrets exist is one people learn to scroll past. So skip,
# loudly enough to be findable and quietly enough to be ignorable.
#
# Both empty means not set up. Exactly one empty is a genuine mistake and still
# fails below.
if [ -z "${WP_USER:-}" ] && [ -z "${WP_APP_PASSWORD:-}" ]; then
  echo "::warning::wp-user and wp-app-password are not set, so this release was not announced. Add them to enable the release post."

  {
    echo "action=skipped"
    echo "post-id="
    echo "skipped-reason=not_configured"
    echo "edit-url="
  } >>"${GITHUB_OUTPUT}"

  # Worth a summary line rather than only a log annotation: this is the state
  # somebody is most likely to be wondering about, and it persists across every
  # release until the secrets land.
  {
    echo "### Release blog post"
    echo
    echo "- **Outcome:** \`skipped\` (\`not_configured\`)"
    echo "- Set \`wp-user\` and \`wp-app-password\` to announce this product."
  } >>"${GITHUB_STEP_SUMMARY}"

  exit 0
fi

for required in SITE_URL ENDPOINT_PATH REPOSITORY TAG; do
  if [ -z "${!required:-}" ]; then
    fail "${required} is empty. site-url has no default and must always be set; repository, tag, release-notes and release-url must be passed explicitly when this action runs outside a 'release' event."
  fi
done

if [ -z "${RELEASE_NOTES:-}" ]; then
  fail "release-notes is empty. On a release event this comes from the release body; release-please writes one, so an empty value usually means the workflow is triggered by something else."
fi

# Reached only when exactly one of the pair is set, the both-empty case having
# skipped above. That is a typo or a missing secret, not an unconfigured repo.
if [ -z "${WP_USER:-}" ] || [ -z "${WP_APP_PASSWORD:-}" ]; then
  fail "wp-user and wp-app-password go together; one is set and the other is empty. Leave both unset to skip announcing this product."
fi

# Mask before the value can reach a log line. base64 of user:password is the
# credential itself, so it is as sensitive as the password.
AUTH="$(printf '%s:%s' "${WP_USER}" "${WP_APP_PASSWORD}" | base64 | tr -d '\n')"
echo "::add-mask::${AUTH}"

# jq builds the body: release notes are multi-line markdown full of backticks,
# quotes and backslashes, and no amount of shell quoting survives that intact.
PAYLOAD="$(
  jq -n \
    --arg repository "${REPOSITORY}" \
    --arg tag "${TAG}" \
    --arg product "${PRODUCT:-}" \
    --arg body "${RELEASE_NOTES}" \
    --arg html_url "${RELEASE_URL:-}" \
    --argjson prerelease "$([ "${PRERELEASE:-false}" = "true" ] && echo true || echo false)" \
    --argjson force "$([ "${FORCE:-false}" = "true" ] && echo true || echo false)" \
    '{
      repository: $repository,
      tag: $tag,
      product: $product,
      body: $body,
      html_url: $html_url,
      prerelease: $prerelease,
      force: $force
    }'
)"

if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "::notice::Dry run — POST ${ENDPOINT}"
  echo "${PAYLOAD}" | jq '.body |= (split("\n") | length | tostring + " lines of release notes")'
  {
    echo "action=skipped"
    echo "post-id="
    echo "skipped-reason=dry_run"
    echo "edit-url="
  } >>"${GITHUB_OUTPUT}"
  exit 0
fi

HEADERS_FILE="$(mktemp)"
BODY_FILE="$(mktemp)"
trap 'rm -f "${HEADERS_FILE}" "${BODY_FILE}"' EXIT

STATUS=""

# Built as an array, not a string: a ${VAR:+--header "x: y"} expansion word-splits
# on the space inside the header value and curl receives three broken arguments.
CURL_ARGS=(
  --silent --show-error
  --request POST "${ENDPOINT}"
  --header "Authorization: Basic ${AUTH}"
  --header "Content-Type: application/json"
  --header "Accept: application/json"
)

if [ -n "${CF_ACCESS_CLIENT_ID:-}" ]; then
  CURL_ARGS+=(--header "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}")
fi

if [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  CURL_ARGS+=(--header "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")
fi

CURL_ARGS+=(
  --data-binary @-
  --dump-header "${HEADERS_FILE}"
  --output "${BODY_FILE}"
  --write-out '%{http_code}'
  --max-time 120
)

for attempt in 1 2 3; do
  STATUS="$( curl "${CURL_ARGS[@]}" <<<"${PAYLOAD}" )" || STATUS="000"

  # Retry only what a retry can fix. A 4xx is our own bad request and will fail
  # identically three times.
  case "${STATUS}" in
    000 | 429 | 5*)
      if [ "${attempt}" -lt 3 ]; then
        echo "::warning::Attempt ${attempt} got HTTP ${STATUS}; retrying"
        sleep $(( attempt * 5 ))
        continue
      fi
      ;;
  esac

  break
done

RESPONSE="$(cat "${BODY_FILE}")"

if ! echo "${RESPONSE}" | jq -e . >/dev/null 2>&1; then
  CF_RAY="$(grep -i '^cf-ray:' "${HEADERS_FILE}" | tr -d '\r' | head -1)"
  CTYPE="$(grep -i '^content-type:' "${HEADERS_FILE}" | tr -d '\r' | head -1)"
  echo "::group::Non-JSON response from ${ENDPOINT}"
  echo "HTTP ${STATUS}"
  echo "${CTYPE:-content-type: unknown}"
  echo "${CF_RAY:-cf-ray: none}"
  echo "--- first 300 bytes ---"
  echo "${RESPONSE}" | head -c 300
  echo
  echo "::endgroup::"
  fail "Endpoint did not return JSON (HTTP ${STATUS}). An HTML body here is usually Cloudflare Access or a WAF challenge — check the service token and that the Access policy covers ${ENDPOINT}."
fi

if [ "${STATUS}" != "200" ]; then
  fail "Endpoint returned HTTP ${STATUS}: $(echo "${RESPONSE}" | jq -r '.message // .code // "no message"')"
fi

POST_ID="$(echo "${RESPONSE}" | jq -r '.post_id // empty')"
ACTION="$(echo "${RESPONSE}" | jq -r '.action // "unknown"')"
REASON="$(echo "${RESPONSE}" | jq -r '.skipped_reason // empty')"
EDIT_URL="$(echo "${RESPONSE}" | jq -r '.edit_url // empty')"
# `generated` is optional in the contract. An endpoint that only renders the
# changelog omits it, and that is not a problem to warn about; only an explicit
# false means the site tried to write an overview and could not.
GENERATED="$(echo "${RESPONSE}" | jq -r 'if has("generated") then (.generated | tostring) else "n/a" end')"

{
  echo "action=${ACTION}"
  echo "post-id=${POST_ID}"
  echo "skipped-reason=${REASON}"
  echo "edit-url=${EDIT_URL}"
} >>"${GITHUB_OUTPUT}"

case "${ACTION}" in
  created)
    echo "::notice::Draft release post created — ${EDIT_URL}"
    ;;
  updated)
    echo "::notice::Release post updated — ${EDIT_URL}"
    ;;
  skipped)
    case "${REASON}" in
      unchanged)
        echo "::notice::Release post is already up to date — ${EDIT_URL}"
        ;;
      already_published)
        echo "::notice::Release post is already published; leaving it alone — ${EDIT_URL}"
        ;;
      human_edited)
        echo "::warning::Release post has been edited by hand; leaving it alone. Re-run with force: true to overwrite — ${EDIT_URL}"
        ;;
      prerelease)
        echo "::notice::Prerelease — no post written."
        ;;
      *)
        echo "::notice::Skipped (${REASON:-no reason given})."
        ;;
    esac
    ;;
  *)
    fail "Unexpected response action '${ACTION}'."
    ;;
esac

if [ "${ACTION}" != "skipped" ] && [ "${GENERATED}" = "false" ]; then
  echo "::warning::The overview was not generated — the post has placeholder copy above a complete changelog. Check the text-generation credentials on ${SITE_URL}."
fi

{
  echo "### Release blog post"
  echo
  echo "- **Outcome:** \`${ACTION}\`${REASON:+ (\`${REASON}\`)}"
  if [ -n "${EDIT_URL}" ]; then
    echo "- **Draft:** ${EDIT_URL}"
  fi
  if [ "${GENERATED}" != "n/a" ]; then
    echo "- **Overview generated:** ${GENERATED}"
  fi
} >>"${GITHUB_STEP_SUMMARY}"
