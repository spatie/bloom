---
name: bloom-release
description: Release Bloom through GitHub and publish generated release notes on runbloom.app, or create signed local release artefacts. Use when asked to cut, ship, publish, or prepare a Bloom release.
---

# Release Bloom

Run app commands from this repository root. Read `RELEASING.md` for the pipeline and credentials,
and `.github/workflows/release.yml` for current implementation details. Use `gh` for GitHub.

## Publish a release

1. Establish the intended commit, version and stable or prerelease channel. Inspect repository
   status, existing tags/releases, and CI for that commit. Do not release uncommitted code or
   infer success from a different commit's green run. If the requested version is ambiguous,
   resolve it before creating the tag.
2. **Generate release notes** from the commits and merged PRs since the preceding release to the
   selected commit. Check the changes and describe user-visible additions and fixes in concise
   British English. Do not invent features or just paste the commit log. Use the same facts for
   GitHub and the website. Write the GitHub Markdown to a temporary file for `--notes-file`.
3. Prepare the tag and notes before publishing. A request to prepare a release stops at a
   reviewable draft; a request to publish authorises publication. For an existing pushed tag:

   ```sh
   gh release create <tag> --repo spatie/bloom --verify-tag --title 'Bloom <version>' --notes-file <notes-file>
   ```

   If GitHub should create the tag, replace `--verify-tag` with `--target <full-commit-sha>`.
   Add `--prerelease` for a prerelease. Tags use `v1.4.0` or `v1.4.0-beta.1`; the tag determines
   the bundle version. The build number comes from reachable commit count and must advance
   beyond the previous shipped build. A pushed tag alone does not trigger release packaging.
4. Watch the **Release** workflow associated with that tag using `gh run list`, `gh run view`
   and `gh run watch`. It signs, notarises and uploads the ZIP and DMG, attaches them to GitHub,
   and updates the Sparkle appcast. If it fails, inspect the failed job before retrying; do not
   delete or move a published tag. Prefer `gh run rerun <run-id>` on the original release-event
   run, which preserves its prerelease flag and asset attachment step. A `workflow_dispatch`
   rebuild has no GitHub prerelease flag: a plain tag marked prerelease on GitHub would become
   stable in the appcast. Use dispatch only when the tag itself preserves the intended channel
   (a stable release or a semver prerelease suffix), and verify GitHub assets separately because
   asset attachment only runs for release events.
5. **Publish the generated release notes on runbloom.app as part of the release.** Follow
   [the website procedure](../../../RELEASING.md#publish-the-website-release-notes). The website
   lives in `spatie/runbloom.app`; the app workflow does not publish its changelog. Importing a
   release or generating a draft is insufficient: review the headline and summary, enable
   publication for that version, save, and verify it is visible on the public changelog.
6. Verify the GitHub release and both assets, their public bucket URLs, the appcast version/build
   and channel, and `https://runbloom.app/changelog#<tag>`. For a stable release, also verify the
   website's download flow selects its DMG. A prerelease must not replace the stable download.
   Report the release URL, workflow result and published changelog URL. If website access is
   unavailable, provide the prepared notes and precise remaining step; report the release as
   incomplete rather than silently skipping website publication.

## Package locally

`./Tools/release.sh [<ref>] [--tag <tag>] [--no-dmg]` (or `make release`) creates signed,
notarised artefacts in `dist/` from committed code. It requires a Developer ID signing identity
and notarisation credentials; see `RELEASING.md`. It does **not** publish a GitHub release,
upload to the bucket, update the appcast, or publish website notes. A local packaging request
does not imply publishing. For an isolated app to test, use `bloom-dev-build` instead.
