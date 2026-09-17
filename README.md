# Release Post (release-post)

A composite GitHub Action that turns a published GitHub release into a draft blog post on a
WordPress site. When [release-please](https://github.com/googleapis/release-please) publishes
a release in a product repo, the action reports it — repository, tag, notes, URL — to a REST
endpoint on the site, and the site writes the post. A human reviews the draft and publishes
it.

What the post contains is up to the endpoint. Linchpin's endpoint generates a short
overview from the release notes and puts the rendered changelog beneath it, but a minimal
endpoint can simply create a post whose body is the changelog. The action does not care;
nothing is generated in CI. It only rings the bell and reports where the draft landed.

The action is site-agnostic. Every caller names its site with `site-url`, and the
[endpoint contract](#endpoint-contract) is documented so any WordPress site can implement
the receiving side. Linchpin's own values are in [Linchpin setup](#linchpin-setup).

Please see [CHANGELOG.md](CHANGELOG.md) for release history.

<!-- x-release-please-start-version -->
## Latest Release: 1.1.0
<!-- x-release-please-end -->

| Workflow | Status |
|----------|--------|
| CI | ![CI](https://github.com/linchpin/release-post/actions/workflows/ci.yml/badge.svg) |
| Release | ![Release](https://github.com/linchpin/release-post/actions/workflows/release.yml/badge.svg) |

## Key Features

| Feature | Details |
|---------|---------|
| Zero generation in CI | The runner sends the release and reads back a result. Whatever the site does with it — render the changelog, generate a summary, both — happens on the site, behind its own credentials. |
| Idempotent | The endpoint keys on repository plus tag. A re-run updates the draft it wrote earlier and leaves a published post, or a draft somebody has since edited, alone. `force: true` overrides that. |
| Quiet until configured | Leave `wp-user` and `wp-app-password` both unset and the action warns, reports `skipped` / `not_configured` and exits. A repo can adopt the workflow before anyone decides whether that product gets announced. |
| Never fails a release | Errors annotate and exit 0 by default. A blog outage cannot hold up a release. `fail-on-error: true` flips that. |
| Cloudflare Access aware | Sends `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers when given, and reads the response as text first, so an Access or WAF challenge page is reported as such rather than as a JSON parse error. |
| Injection-safe | Every input reaches the script through the environment; nothing is interpolated into the shell body. Release notes are built from commit messages, including bot ones, and are treated as untrusted. |
| Retries what a retry can fix | Three attempts with backoff on connection failure, `429` and `5xx`. A `4xx` is our own bad request and is not retried. |

## How it fits the stack

1. **release-please** in a product repo merges a release PR, tags it, and publishes a
   GitHub release with generated notes.
2. **This action**, triggered by `release: published`, POSTs the release to the site and
   writes the outcome to the job's outputs and summary.
3. **The site** authenticates the request and creates or updates a draft `post` from it.
   Linchpin's endpoint renders the changelog to blocks, generates an overview above it, and
   files the post under a **Releases** category tagged with the product name. Yours can do
   as little as post the changelog.
4. **A human** reviews the draft in wp-admin and publishes it.

The receiving endpoint is not part of this repo. See [Endpoint contract](#endpoint-contract)
to build one, or [Linchpin setup](#linchpin-setup) for where Linchpin's lives.

## Architecture

| Path | Role |
|------|------|
| `action.yml` | Inputs, outputs, and the single composite step. Maps every input to an environment variable and runs the script. |
| `release-post.sh` | Validates inputs, builds the JSON payload with `jq`, POSTs with `curl`, interprets the response, and writes `GITHUB_OUTPUT` and `GITHUB_STEP_SUMMARY`. |
| `.github/workflows/ci.yml` | actionlint, yamllint, shellcheck, zizmor, and a dry-run smoke test that exercises the action end to end without credentials. |
| `.github/workflows/release.yml` | release-please, plus a job that moves the floating `v1` tag onto each published `vX.Y.Z` release. |

## Requirements

* A GitHub repository that publishes releases (release-please or otherwise).
* A WordPress site exposing an endpoint that implements the
  [contract](#endpoint-contract) below.
* A WordPress user with an Application Password and the `publish_posts` capability.
* If the site sits behind Cloudflare Zero Trust, a Cloudflare Access service token whose
  policy covers the endpoint path.
* Runner tooling: `bash`, `curl`, `jq`. All present on `ubuntu-latest`.

## Usage

```yaml
name: Release blog post

on:
  release:
    types: [published, edited]

permissions:
  contents: read

concurrency:
  group: release-post-${{ github.event.release.tag_name }}
  cancel-in-progress: false

jobs:
  post:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: linchpin/release-post@v1
        with:
          site-url: https://blog.example.com
          product: Acme Blocks
          wp-user: ${{ secrets.WP_USER }}
          wp-app-password: ${{ secrets.WP_PASS }}
```

Everything except `site-url`, `product` and the credentials is read from the release event.
If the site registers the contract under its own namespace, add `endpoint`; if it sits
behind Cloudflare Access, add the two `cf-access-*` inputs:

```yaml
        with:
          site-url: https://blog.example.com
          endpoint: /wp-json/acme/v1/release-post
          cf-access-client-id: ${{ secrets.CF_ACCESS_CLIENT_ID }}
          cf-access-client-secret: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
          # …
```

### `release: published` only fires under a PAT

A release created by the default `GITHUB_TOKEN` raises no `release` event — GitHub
suppresses it so a workflow cannot trigger itself. If release-please in your repo runs as
`secrets.GITHUB_TOKEN`, the workflow above will never fire.

Fix it at the source by giving release-please a bot token:

```yaml
- uses: googleapis/release-please-action@v5
  id: release
  with:
    token: ${{ secrets.GH_BOT_TOKEN }}   # not GITHUB_TOKEN
```

Two things change when you do. Release PRs start running CI, because a PR opened by
`GITHUB_TOKEN` does not trigger workflows and one opened by a PAT does — generally an
improvement. And **any dormant `release:`-triggered workflow in the repo starts running**,
possibly for the first time ever. Check for those before flipping the token.

<details>
<summary>Fallback: hang the job off release-please's outputs instead</summary>

If a repo cannot use a PAT, skip the `on: release:` workflow and add a job to release-please
instead. This works but is a workaround for a misconfiguration, and it has to be repeated in
every repo.

```yaml
jobs:
  release-please:
    outputs:
      releases_created: ${{ steps.release.outputs.releases_created }}
      tag_name: ${{ steps.release.outputs.tag_name }}
      body: ${{ steps.release.outputs.body }}
    # …

  post:
    needs: release-please
    if: ${{ needs.release-please.outputs.releases_created == 'true' }}
    runs-on: ubuntu-latest
    steps:
      - uses: linchpin/release-post@v1
        with:
          site-url: https://blog.example.com
          product: Acme Blocks
          tag: ${{ needs.release-please.outputs.tag_name }}
          release-notes: ${{ needs.release-please.outputs.body }}
          release-url: https://github.com/${{ github.repository }}/releases/tag/${{ needs.release-please.outputs.tag_name }}
          wp-user: ${{ secrets.WP_USER }}
          wp-app-password: ${{ secrets.WP_PASS }}
```

Most release-please workflows only declare `release_created` in their `outputs` block —
`tag_name` and `body` have to be added.

</details>

## Configuration

### Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `site-url` | yes | | Origin of the site, e.g. `https://blog.example.com`. No trailing slash, no `/wp-json` |
| `wp-user` | see note | | WordPress username the Application Password belongs to |
| `wp-app-password` | see note | | The Application Password |
| `product` | no | repo name, prettified | Display name for the title and tag |
| `endpoint` | no | `/wp-json/release-post/v1/post` | REST route path, relative to `site-url` |
| `cf-access-client-id` | no | | Cloudflare Access service token ID. Required when the site is behind Access |
| `cf-access-client-secret` | no | | Cloudflare Access service token secret |
| `repository` | no | `github.repository` | Full `owner/repo` |
| `tag` | no | `github.event.release.tag_name` | Release tag, e.g. `v2.7.0` |
| `release-notes` | no | `github.event.release.body` | Release notes markdown |
| `release-url` | no | `github.event.release.html_url` | Canonical URL of the release |
| `prerelease` | no | `github.event.release.prerelease` | Skipped by the endpoint unless `force` is set |
| `force` | no | `false` | Rewrite even when published or hand-edited |
| `dry-run` | no | `false` | Print the payload, post nothing |
| `fail-on-error` | no | `false` | Fail the job when the post could not be written |

**Credentials note.** `wp-user` and `wp-app-password` go together. Both unset means "not
configured" and the action skips quietly. Exactly one set is treated as a mistake and fails.

### Outputs

| Output | Values |
| --- | --- |
| `action` | `created`, `updated`, `skipped`, `error` |
| `skipped-reason` | `not_configured`, `dry_run`, `prerelease`, `unchanged`, `human_edited`, `already_published` |
| `post-id` | WordPress post ID, empty when nothing was written |
| `edit-url` | wp-admin edit URL for the post |

The step also writes the outcome and a link to the draft into the job summary.

### Re-run behaviour

| State on the site | Result |
| --- | --- |
| Nothing exists yet | `created` |
| Draft we wrote, notes unchanged | `skipped` (`unchanged`) — no generation request either |
| Draft we wrote, notes changed | `updated` |
| Draft somebody has since edited | `skipped` (`human_edited`) |
| Already published | `skipped` (`already_published`) |
| Prerelease | `skipped` (`prerelease`) |

`force: true` overrides the last three. It rewrites the body and leaves the post's status
alone — forcing a published post rewrites it in place, it does not unpublish it.

### Failures

A failure annotates the log with `::error::`, sets `action=error`, and exits 0 unless
`fail-on-error` is `true`.

The most common failure is an HTML response instead of JSON, which almost always means
Cloudflare Access or a WAF answered instead of WordPress. The log prints the status,
`content-type`, `cf-ray` and the first 300 bytes of the body so it is obvious at a glance.

## Endpoint contract

The action is a thin client. Any site can receive from it by exposing a route that accepts
this request and returns this response. The simplest conforming endpoint converts `body`
from markdown to post content and creates a draft titled from `product` and `tag`. Anything
beyond that — a generated summary, categories, tags, custom blocks — is the site's choice.

**Request.** `POST {site-url}{endpoint}` with `Authorization: Basic` (WordPress
Application Password), `Content-Type: application/json`, and optionally the two
`CF-Access-*` headers. The reference route is `/wp-json/release-post/v1/post`; a site may
register the same contract under any namespace and callers pass it as `endpoint`. Body:

```json
{
  "repository": "acme/acme-blocks",
  "tag": "v2.7.0",
  "product": "Acme Blocks",
  "body": "## [2.7.0](…) (2026-09-01)\n\n### Features\n\n* …",
  "html_url": "https://github.com/acme/acme-blocks/releases/tag/v2.7.0",
  "prerelease": false,
  "force": false
}
```

`product` may be an empty string, in which case the site derives a name from `repository`.

**Response.** HTTP `200` with a JSON body:

```json
{
  "action": "created",
  "post_id": 1234,
  "skipped_reason": "",
  "edit_url": "https://example.com/wp-admin/post.php?post=1234&action=edit",
  "generated": true
}
```

| Field | Meaning |
| --- | --- |
| `action` | One of `created`, `updated`, `skipped` |
| `post_id` | The post that was created, updated or found. May be empty when skipped |
| `skipped_reason` | When `action` is `skipped`: `prerelease`, `unchanged`, `human_edited` or `already_published` |
| `edit_url` | wp-admin edit link for the post |
| `generated` | Optional. Include it only if the endpoint generates a summary: `false` means it tried and could not, so the post carries placeholder copy above a complete changelog, and the action warns. Omit it entirely from a changelog-only endpoint |

Any non-`200` status is reported as an error using the body's `message` or `code` field if
present. A non-JSON body is reported as a probable Access or WAF challenge.

### What a conforming endpoint should write

The contract leaves the post's shape to the site. For reference, Linchpin's endpoint writes:

- **Title** — product and version, e.g. *Linchpin Blocks 2.7.0*.
- **Masthead** — the title and a one-line summary, on the standard cyan page header.
- **What's new** — two or three paragraphs generated from the release notes.
- **Changelog** — release-please's own sections and entries, converted to blocks. Not
  generated, so it cannot misreport what shipped. Bare commit-hash links and the internal
  `NO-TASK` scope marker are dropped; both are restorable with a filter on the site.
- **Links** — the release on GitHub, and the compare diff when the notes carry one.

It is filed as a draft `post` in the **Releases** category, tagged with the product name.

## Setup

On the receiving site, once, before the first repo opts in:

1. **A bot user** — role **Author** is enough, as long as it has `publish_posts`.
2. **An Application Password** for that user. Store it in your password manager, and set
   `WP_USER` and `WP_PASS` as repository or organization secrets.
3. **A Cloudflare Access service token**, only if the site is behind Access, with a Service
   Auth policy scoped to the endpoint path. A dedicated token keeps the blast radius on that
   one path. Store as `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`.
4. **Whatever the endpoint expects to exist.** Linchpin's wants a `Releases` category
   created up front, because it files posts there without capability-checking terms.

The secrets can live on each repo or once at org level — the action does not care, it only
reads the inputs. Repo-level is the safer default while this is being proven out; promoting
them to org level later means every product repo opts in with one file and no secrets of
its own.

### Linchpin setup

Linchpin product repos post to [builditbelieveit.com][site], which sits behind Cloudflare
Access. Every caller passes these values explicitly; the action carries no Linchpin default.

```yaml
      - uses: linchpin/release-post@v1
        with:
          site-url: https://builditbelieveit.com
          endpoint: /wp-json/linchpin/v1/release-post
          product: Linchpin Blocks
          wp-user: ${{ secrets.WP_USER }}
          wp-app-password: ${{ secrets.WP_PASS }}
          cf-access-client-id: ${{ secrets.CF_ACCESS_CLIENT_ID }}
          cf-access-client-secret: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
```

The receiving endpoint lives in the `linchpin-functionality` plugin on [linchpin.com][repo],
gated behind the `release_posts` module, which is on for the network's main site only. The
overview is generated through the Linchpin AI Gateway. The Access service token is scoped to
that one path. release-please in Linchpin repos runs as `GH_BOT_TOKEN`, which is what makes
the `release: published` trigger fire.

## Local Development

There is nothing to install. The action is `action.yml` plus one bash script.

```bash
shellcheck release-post.sh
yamllint -c .ymllint.yml action.yml .github/workflows/
```

Run the script directly with a dry run to see the payload it would send, without touching a
site:

```bash
SITE_URL=https://example.invalid \
PRODUCT="Smoke Test" \
REPOSITORY=linchpin/release-post \
TAG=v0.0.0 \
RELEASE_NOTES=$'## 0.0.0\n\n* a change' \
RELEASE_URL=https://example.invalid/releases/tag/v0.0.0 \
WP_USER=smoke WP_APP_PASSWORD=smoke \
DRY_RUN=true \
GITHUB_OUTPUT=/tmp/out GITHUB_STEP_SUMMARY=/tmp/summary \
bash release-post.sh
```

CI runs the same dry run through the action itself (`uses: ./`) and asserts on the outputs,
so a change that breaks input wiring fails before it can be released.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/) with the task
key or `NO-TASK` as the scope, e.g. `feat(NO-TASK): Add the endpoint input`.

## Releases

Releases are automated with [release-please](https://github.com/googleapis/release-please).
Every push to `main` opens or updates a release PR that bumps `version.txt`, updates
`CHANGELOG.md` and the version marker in this README. Merging that PR tags `vX.Y.Z` and
publishes a GitHub Release; a second job then moves the floating `v1` tag onto it so callers
pinned to `@v1` pick up the change.

release-please owns `version.txt`, `CHANGELOG.md` and `.release-please-manifest.json`;
never edit them by hand.

A major tag is never created while a branch of the same name exists, or the ref would be
ambiguous. If that happens, delete the branch and re-run the Release workflow via
`workflow_dispatch` with the release tag.

## Known limitations

* **The receiving endpoint is not in this repo.** Linchpin's implementation lives in a
  private plugin. The [contract](#endpoint-contract) is documented; the server side is yours
  to build.
* **Basic auth only.** The action authenticates with a WordPress Application Password. There
  is no OAuth or token-header alternative.
* **No unit tests for the script.** Coverage is shellcheck plus the CI dry run; the response
  handling paths are exercised only against a live endpoint.

## License

MIT — see [LICENSE](LICENSE).

## Status

This project is **actively maintained** by Linchpin. For bugs or feature requests, open an
issue on GitHub. Linchpin staff should file work in ClickUp.

![Linchpin an award winning digital agency building immersive, high performing web experiences](https://assets.linchpin.com/github/linchpin-github-repo-banner.jpg)

[site]: https://builditbelieveit.com
[repo]: https://github.com/linchpin/linchpin.com
