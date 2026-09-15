---
name: bloom-dev-build
description: Build and test Bloom Dev locally, using current edits for everyday development or a committed revision for release-mode checks. Use when asked to create, update, or run a dev version of Bloom.
---

# Build Bloom Dev

Run commands from the Bloom repository root. Read `CLAUDE.md` for app isolation rules and
`Tools/dev-build.sh` when diagnosing the build.

## Choose the build

**Use fast mode for everyday local development.** It builds current files in debug mode, including
uncommitted edits and untracked files that Git does not ignore. No commit is needed. It uses a
persistent cache per checkout and four compiler jobs. The first build fills the cache; later builds
reuse unchanged sources. It keeps normal assets and App Intents metadata.

| Purpose | Command |
| --- | --- |
| Develop locally, install and restart the dev app | `make dev-fast` |
| Build current edits without installing or launching | `./Tools/dev-build.sh --fast --no-install` |
| Install current edits without restarting | `./Tools/dev-build.sh --fast --no-launch` |
| Test committed HEAD in release mode, install and restart | `make dev` |
| Install a specific committed revision in release mode without restarting | `./Tools/dev-build.sh <ref> --no-launch` |
| Compile only, without an app bundle | `make build` |

**Both modes install the same `~/Applications/Bloom Dev.app` and use the same existing dev data.**
They are debug and release builds of one dev app, not two separate apps or databases. Installing
either replaces the previous dev build. Production Bloom can keep running alongside it.

Release mode builds a committed revision in a detached worktree and excludes uncommitted edits.
Use it when the requested check needs a specific commit or release optimisation. Do not commit
changes merely to try them locally. Fast mode cannot be combined with a revision.

## Build and verify

1. Check `git status --short` and choose the mode above. For agent verification, prefer
   `--fast --no-install` unless installation is part of the task. This also allows building from a
   session hosted by Bloom Dev without replacing its app.
2. The Mac needs Xcode 26 or later selected, Swift 6.2, macOS 26 and Python 3. Check
   `xcode-select -p` and `xcrun swift --version` when setup is uncertain. Signing is ad hoc by default;
   no release certificate or notarisation credentials are needed. Running App Intents through
   Shortcuts requires a real signing identity.
3. Run the selected command. Only restart the dev app when authorised. `make dev-fast` and
   `make dev` both quit and relaunch the verified dev copy after its replacement is ready.
   `--no-launch` refuses installation while the destination app is running. Use `--no-install`
   to verify a build while keeping that copy open.
4. Verify the bundle at the path printed by the script. With `--no-install`, use that build path;
   otherwise use `~/Applications/Bloom Dev.app`. Check its `Contents/Info.plist` and signature:
   - `CFBundleIdentifier` is `be.spatie.bloom.dev`.
   - `BloomMasterCommit` is the selected short commit hash, with `-working` appended in fast mode.
     This suffix identifies a build of current files; it does not identify their exact contents.
   - `LSEnvironment:BLOOM_DB_PATH` points under `~/Library/Application Support/Bloom Dev/`.
   - `codesign --verify --deep --strict <app-path>` passes.
5. When opening the installed app, use LaunchServices: `open -g "$HOME/Applications/Bloom Dev.app"`.
   Do not run its executable directly. Opening an already running app does not reload its code.

Report the mode, whether the build was installed or launched, and any verification limits. Run
relevant tests and linters as described in `CLAUDE.md`; `make test` covers the core and does not
prove the app compiles.

## Isolation and failures

Leave the production app, database and preferences alone. Do not use `make master`, `make run`,
or `make app` to obtain an isolated dev app: they retain the production identity. Keep existing
dev data; copying production data with `make dev-db` is optional and replaces dev data, so only
use it when requested.

Do not bypass `Tools/guard.sh`. If installation is refused because Bloom Dev hosts this session,
use `--no-install` for verification or install from an external terminal. Both modes lock publication because they share the destination. Fast mode also locks its cache
per checkout. Release mode locks the shared `/tmp/bloom-dev-src` and `/tmp/bloom-dev-build`
across checkouts. A failed candidate leaves the installed app untouched.

On failure, read the log path printed by the script. Fast mode uses
`/tmp/bloom-dev-fast-<checkout-hash>/build.log`; release mode uses `/tmp/bloom-dev-build.log`.
Compilation and signing finish before installation, so failure in either leaves the previous
installed app in place. Report the actual failure stage.

## Bloom Remote

Use the same fast snapshot workflow for the isolated Remote app:

| Purpose | Command |
| --- | --- |
| Build current edits, install and restart Remote | `make remote-fast` |
| Verify current edits without changing the installed Remote app | `./Tools/remote-build.sh --fast --no-install` |
| Install current edits without launching | `./Tools/remote-build.sh --fast --no-launch` |
| Install committed HEAD without launching | `make remote` |
| Install a specific committed revision without launching | `./Tools/remote-build.sh <ref>` |

`--launch` gracefully quits only the verified Bloom Remote app after its replacement has been
built, copied and signature-checked. If Remote will not quit, installation stops. Launch uses
`open -g`. `--no-install` never quits, replaces or launches an app and may run from Remote itself.
Installation still refuses to replace the app hosting the current agent. `--fast` cannot take a
revision. The existing `BLOOM_REMOTE_BUILD_ONLY=1` exports `/tmp/Bloom-Remote-ready.app` without
installing or launching, including in fast mode.

Remote caches survive reboot under `~/Library/Caches/BloomBuild/remote/<checkout-hash>/`;
committed release builds use the sibling `release/` cache. Each cache has its own lock and
`build.log`; installations have a shared lock because all caches install the same app. Do not
remove a lock while its build is running. Fast snapshots include current tracked and nonignored
untracked files, exclude build caches, and preserve repository symlinks. Identity-transform inputs
must be regular files without symlink ancestors. Dev and Remote share `Tools/build-snapshot.py`.
Unchanged transformed sources keep their cache timestamps, preserving incremental compilation.

Both modes retain `be.spatie.bloom.remote`, the existing Bloom Remote data, its saved connection
preset and client-key path. Remote claims no production URL scheme or Finder services. Normal
assets, App Intents metadata and all bundled Mac executables are packaged in fast mode too.
`BloomMasterCommit` uses `<short-hash>-working` in fast mode and the committed hash in release mode.

Provide `BLOOM_LINUX_SERVER_ARCHIVE` for a newly tested Linux runtime. Otherwise the build retains
the installed Remote app's embedded server archive. A missing archive stops the build, and normal
packaging rejects a protocol mismatch. The script prints the archive path and SHA-256. Reusing a
protocol-compatible archive does not establish that it contains current server source changes;
rebuild and test that archive whenever Linux server code changes. Fast mode rebuilds the Mac
client and its local executables, while retaining this separately tested Linux payload.

The candidate is signature-verified before publication. Installation stages beside the destination
and exchanges app directories atomically, so copy/signing/publication failures retain the old app.
Report whether installation or launch occurred and use the printed candidate path for no-install
verification. For a warm-build comparison, run the same `--fast --no-install` command twice without
source changes and compare elapsed time and Swift compilation lines in the same cache's build log.
