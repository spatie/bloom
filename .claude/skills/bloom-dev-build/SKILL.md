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
   `make dev` both quit and relaunch the dev copy. `--no-launch` still replaces the installed bundle;
   an already running copy does not switch to the new code until restarted.
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
use `--no-install` for verification or install from an external terminal. Run only one installation
at a time because both modes share the destination. Fast mode also locks its cache per checkout;
release mode shares `/tmp/bloom-dev-src` and `/tmp/bloom-dev-build` across checkouts.

On failure, read the log path printed by the script. Fast mode uses
`/tmp/bloom-dev-fast-<checkout-hash>/build.log`; release mode uses `/tmp/bloom-dev-build.log`.
Compilation and signing finish before installation, so failure in either leaves the previous
installed app in place. Report the actual failure stage.
