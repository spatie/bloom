---
name: bloom-server-release
description: Verify, publish and check the Linux Bloom Server assets of a release, test a supervised update from the previous release on a real Ubuntu server, and diagnose a failed server update or rollback. Use when a release touches the server, when asked whether servers can update, or when a server update failed.
---

# Release Bloom Server

The server is released by the Bloom release, from this repository, under the same tag. There is no
server tag, no server beta channel and no separate repository. Read `RELEASING.md#bloom-server` for
the pipeline and the reasons; this skill is the procedure. Use `gh` for GitHub. Run commands from
the repository root.

## Files to read

- `.github/workflows/release.yml`: the `server-package` job, the embedded copy check, the attach and
  verify steps.
- `.github/workflows/server.yml`: the same packaging on pull requests and the Ubuntu 24.04 and 26.04
  runs without Swift.
- `Tools/package-linux-server.py`: builds the tarball and its `manifest.json`.
- `Tools/server-release-assets.py` and `Tools/test-server-release-assets.py`: the sidecars and the
  checks, which import the supervisor's own code.
- `Tools/bloom-maintenance.py`: `release_asset`, `extract_release`, `validate_release_manifest`,
  `Supervisor.components`, `prepare`, `download` and `rollback`. This is what a server runs.
- `Tools/bloom_maintenance_install.py`: the supervisor's installed configuration and protocol.
- `docs/SERVER.md#server-updates` and `docs/SERVER-MAINTENANCE.md`: what the app shows.

## Before publishing

1. The Server workflow is green on the commit being tagged. A green run on another commit is not
   evidence. Pull requests build debug, so also dispatch the release build on that commit's branch,
   `gh workflow run server.yml --repo spatie/bloom --ref <branch> -f release_build=true`, and wait
   for its `release-package` job. Dispatching is a CI run, not a release, but ask before doing it.
2. Compare `BloomWire.version` in `Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift`
   with the previous release's tag. A raised wire protocol needs nothing extra: supervisors offer
   it and install it in place, and only an older one is refused. If `MAINTENANCE_PROTOCOL_VERSION`
   changed, every installed supervisor shows the release as incompatible and does not offer it.
   That is not a reason to stop the release, but the notes must say that servers need
   **Update Server…** in the new app.
3. A patch to an older line is published with `--latest=false`, or every server is pointed at it.

## Publish

Follow the `bloom-release` skill. A prerelease publishes server assets too, but no server is
offered it. Watch the Release run: `server-package` builds in release configuration, then the macOS
job checks the artefact, embeds it, compares the embedded copy, and after the appcast attaches the
three files and runs **Check the supervisor would accept the published server**. A release is not
complete until that step is green.

## Check the published assets

```sh
tag=v1.4.0
dir="$(mktemp -d)"
gh release view "$tag" --repo spatie/bloom --json assets --jq '.assets[] | [.name, .size, .digest] | @tsv'
gh api repos/spatie/bloom/releases/latest --jq .tag_name
gh release download "$tag" --repo spatie/bloom --pattern 'bloom-server-linux-x86_64*' --dir "$dir"
(cd "$dir" && shasum -a 256 -c bloom-server-linux-x86_64.tar.gz.sha256)
gh api "repos/spatie/bloom/releases/tags/$tag" > "$dir/release.json"
python3 Tools/server-release-assets.py verify "$dir/bloom-server-linux-x86_64.tar.gz" \
  --release "$dir/release.json" --description "$dir/bloom-server-linux-x86_64.json"
cat "$dir/bloom-server-linux-x86_64.json"
```

Expect `bloom-server-linux-x86_64.tar.gz`, `.tar.gz.sha256` and `.json`, each with a `sha256:`
digest; `releases/latest` printing the tag for a stable release; `verify` passing; and the JSON's
`version` equal to the tag without `v`. The `sha256` in
`Bloom.app/Contents/Resources/ServerSetup/package.json` inside the release zip must be the same digest.

## Test an update on a real Ubuntu server

The owner drives the app. Do not launch, focus or click Bloom, and do not SSH into a server without
the owner's explicit permission for that server. Prepare the steps, then read what the owner reports.

Preconditions: a disposable Ubuntu 24.04 or 26.04 x86_64 server, installed with supervised
maintenance from the previous release's app (Server Settings > Updates shows Bloom Server with an
installed version), a maintenance key in that Mac's Keychain, and a project with a finished
conversation to prove data survives.

Ask the owner to:

1. Open Server Settings > Updates and refresh. Bloom Server should show the previous version
   installed and the new tag available. Up to fifteen minutes of caching is normal.
2. Review the update. The plan names the exact target tag and the restart of Bloom Server.
3. Choose **Update**, and keep the panel open. The job moves through `downloading`, `installing`,
   `restarting` and `verifying` to `succeeded`. Only `succeeded` is success.
4. Reconnect, open the earlier conversation, and start a short turn.
5. Refresh Updates: the installed version is the new tag and no update is offered.

With permission, read-only checks on the server:

```sh
systemctl status bloom-server
journalctl -u bloom-server --since '30 min ago'
sudo cat /var/lib/bloom-maintenance/bloom-server/current.json
sudo ls /var/lib/bloom-maintenance/bloom-server/releases
```

`current.json` names the new version and an executable under `releases/<sha256>/`, and that
directory name is the published digest. `transaction.json` exists only while an update is in flight.

Rollback cannot be exercised safely with a real release. `Tools/maintenance-supervisor-smoke.py`
installs a broken package in a disposable container in the Server workflow and checks the previous
release and database come back; point to that run rather than breaking a server.

## Diagnose a failed update or rollback

Start with the job's final phase and its error code, which the app shows and copies.

| Code or phase | Meaning | Next step |
| --- | --- | --- |
| `release_unavailable` | No stable latest release, no server asset in it, no digest, a description whose `name`, `tag` or `sha256` differs from the release, or GitHub unreachable. | Run the asset check above. Check `releases/latest`. |
| Offered as incompatible | The description names another architecture or maintenance protocol, a wire protocol older than the installed release's, or a newer glibc than the server. Updates shows the reason; nothing is downloaded. | A maintenance protocol change goes through **Update Server…** from the new app; a glibc one needs a newer Ubuntu. |
| `release_changed` | The latest release changed between inspection and review. | Review again. |
| `checksum_mismatch` | The downloaded bytes are not the digest in the plan, usually an asset replaced after review. | Check whether the asset was re-uploaded; review again. |
| `incompatible_release` | Manifest maintenance protocol or architecture differs from the supervisor's, or its wire protocol is older than the installed release's. | For a maintenance protocol change, use **Update Server…** from the new app. |
| `release_version_mismatch` | The manifest version is not the tag. | A packaging fault: the release workflow should have refused it. Delete the asset and investigate. |
| `unsafe_release`, `release_too_large` | The archive shape or size is refused. | Packaging fault, as above. |
| `rolledBack` | The new release failed startup verification; previous release and database restored. | Read the job log and `journalctl -u bloom-server`. If other servers will hit it, delete the asset. |
| `interrupted` | The supervisor stopped mid job. | **Recover Update** in the app. Never start a new update first. |
| `failed` | Anything else, with the outcome stated in its message. | Read the message; the installed version is in `current.json`. |

To stop servers being offered a bad release, and for a missing or failed attachment, follow
`RELEASING.md#when-the-server-asset-is-broken`. Never upload different bytes under a published tag
and never move a tag. Report what was verified, the run URL, and anything left for the owner.
