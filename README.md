# release-post

Turn a published GitHub release into a draft blog post on the Linchpin blog.

When release-please publishes a release in a product repo, this action reports it to
[builditbelieveit.com][site] — repository, tag, notes, URL — and the site writes the post:
an overview generated through the Linchpin AI Gateway, followed by the changelog rendered
from the release notes. A human reviews the draft and publishes it.

Nothing is generated in CI. This action only rings the bell and reports where the draft
landed.

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
          product: Linchpin Blocks
          wp-user: ${{ secrets.RELEASE_POST_WP_USER }}
          wp-app-password: ${{ secrets.RELEASE_POST_WP_APP_PASSWORD }}
          cf-access-client-id: ${{ secrets.RELEASE_POST_CF_ACCESS_CLIENT_ID }}
          cf-access-client-secret: ${{ secrets.RELEASE_POST_CF_ACCESS_CLIENT_SECRET }}
```

Everything except `product` and the credentials is read from the release event.

## What the post looks like

- **Title** — product and version, e.g. *Linchpin Blocks 2.7.0*.
- **Masthead** — the title and a one-line summary, on the standard cyan page header.
  (`single.html` renders no post title of its own, so the body carries one.)
- **What's new** — two or three paragraphs written by the gateway from the release notes.
- **Changelog** — release-please's own sections and entries, converted to blocks. Not
  generated, so it cannot misreport what shipped. Bare commit-hash links and the internal
  `NO-TASK` scope marker are dropped; both are restorable with a filter on the site.
- **Links** — the release on GitHub, and the compare diff when the notes carry one.

It is filed as a draft `post` in the **Releases** category, tagged with the product name.

## Re-running is safe

The endpoint keys on repository plus tag, so a second run finds the post it wrote the first
time. What happens then depends on what has become of it:

| State | Result |
| --- | --- |
| Nothing exists yet | `created` |
| Draft we wrote, notes unchanged | `skipped` (`unchanged`) — no AI request either |
| Draft we wrote, notes changed | `updated` |
| Draft somebody has since edited | `skipped` (`human_edited`) |
| Already published | `skipped` (`already_published`) |
| Prerelease | `skipped` (`prerelease`) |

`force: true` overrides the last three. It rewrites the body and leaves the post's status
alone — forcing a published post rewrites it in place, it does not unpublish it.

## Inputs

| Input | Required | Default | |
| --- | --- | --- | --- |
| `wp-user` | yes | | WordPress username the Application Password belongs to |
| `wp-app-password` | yes | | The Application Password |
| `product` | no | repo name, prettified | Display name for the title and tag |
| `site-url` | no | `https://builditbelieveit.com` | Origin, no trailing slash, no `/wp-json` |
| `cf-access-client-id` | no | | Cloudflare Access service token ID — **required in practice**, see Setup |
| `cf-access-client-secret` | no | | Cloudflare Access service token secret |
| `repository` | no | `github.repository` | |
| `tag` | no | `github.event.release.tag_name` | |
| `release-notes` | no | `github.event.release.body` | |
| `release-url` | no | `github.event.release.html_url` | |
| `prerelease` | no | `github.event.release.prerelease` | |
| `force` | no | `false` | Rewrite even when published or hand-edited |
| `dry-run` | no | `false` | Print the payload, post nothing |
| `fail-on-error` | no | `false` | Fail the job when the post could not be written |

## Outputs

`post-id`, `action` (`created` / `updated` / `skipped` / `error`), `skipped-reason`,
`edit-url`.

The step also writes the outcome and a link to the draft into the job summary.

## Failures are not fatal by default

A release must not be held up because the blog was unreachable, so a failure annotates and
exits 0. Set `fail-on-error: true` where you would rather know loudly.

The most common failure is an HTML response instead of JSON, which almost always means
Cloudflare Access answered instead of WordPress. The log group prints the status,
`content-type`, `cf-ray` and the first 300 bytes so it is obvious at a glance.

## Setup

Four things, once, before the first repo opts in.

1. **A bot user** on the site — role **Author** is enough. It needs `publish_posts`; the
   category and tag are created by the endpoint, which does not capability-check terms.
2. **An Application Password** for that user. Store it in 1Password, and set the org
   secrets `RELEASE_POST_WP_USER` and `RELEASE_POST_WP_APP_PASSWORD`.
3. **A Cloudflare Access service token**, with a Service Auth policy scoped to
   `builditbelieveit.com/wp-json/linchpin/v1/release-post`. A dedicated token keeps the
   blast radius on that one path. Store as `RELEASE_POST_CF_ACCESS_CLIENT_ID` and
   `RELEASE_POST_CF_ACCESS_CLIENT_SECRET`.
4. **The `Releases` category**, created once so the first run does not have to.

The endpoint lives in `linchpin-functionality` on [linchpin.com][repo] and is gated behind
the `release_posts` module, which is on for the network's main site only.

### This repo is private

Private action repos are invisible to other repos until you say otherwise. Set
**Settings → Actions → General → Access → _Accessible from repositories in the linchpin
organization_**, or every caller fails with "repository not found".

### `release: published` only fires under a PAT

A release-please workflow running as the default `GITHUB_TOKEN` cannot trigger other
workflows, so the `release` event never arrives. `linchpin.com` uses `GH_BOT_TOKEN`
deliberately for this reason.

In a repo that does not, hang the job off release-please directly instead:

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
          product: Linchpin Blocks
          tag: ${{ needs.release-please.outputs.tag_name }}
          release-notes: ${{ needs.release-please.outputs.body }}
          release-url: https://github.com/${{ github.repository }}/releases/tag/${{ needs.release-please.outputs.tag_name }}
          wp-user: ${{ secrets.RELEASE_POST_WP_USER }}
          wp-app-password: ${{ secrets.RELEASE_POST_WP_APP_PASSWORD }}
          cf-access-client-id: ${{ secrets.RELEASE_POST_CF_ACCESS_CLIENT_ID }}
          cf-access-client-secret: ${{ secrets.RELEASE_POST_CF_ACCESS_CLIENT_SECRET }}
```

Most release-please workflows only declare `release_created` in their `outputs` block —
`tag_name` and `body` have to be added.

## Releasing this action

release-please owns `version.txt`, `CHANGELOG.md` and the manifest; never edit them by
hand. Merging to `main` opens a release PR, and merging that tags `vX.Y.Z` and moves the
floating `v1` tag so callers pinned to `@v1` pick it up.

> The initial release is pinned with `release-as: "1.0.0"` in `release-please-config.json`
> so the first tag matches the `@v1` contract callers use. **Remove that key once v1.0.0 has
> shipped**, or every subsequent release will try to be 1.0.0 again.

[site]: https://builditbelieveit.com
[repo]: https://github.com/linchpin/linchpin.com
