---
name: bloom-dev-build
description: Build and install Bloom Dev, the isolated development app, from a committed revision. Use when asked to create, update, or run a dev version of Bloom.
---

# Build Bloom Dev

Run commands from the Bloom repository root. Read `CLAUDE.md` for app isolation rules and
`Tools/dev-build.sh` when diagnosing the build.

1. Check `git status --short` and the intended revision. The script builds **committed code** in a
   detached worktree, so uncommitted edits are excluded. If this task includes committing changes,
   commit only the intended files first. Otherwise explain which changes the build will omit.
2. Check the Mac has Xcode 26 or later selected (`xcode-select -p`, `xcrun swift --version`). The
   package requires Swift 6.2 and macOS 26; app packaging also uses Xcode tools such as `actool`
   and `ibtool`. Python 3 is used by the dev icon and guard scripts. Signing is ad hoc by default;
   a colleague does not need the release certificate or notarisation credentials.
3. Build and install without launching:

   ```sh
   ./Tools/dev-build.sh --no-launch
   # Or select a committed revision:
   ./Tools/dev-build.sh <ref> --no-launch
   ```

   This installs `~/Applications/Bloom Dev.app`. The script uses fixed paths under
   `/tmp/bloom-dev-src` and `/tmp/bloom-dev-build`; run only one dev build at a time on a Mac.
   If it refuses because Bloom Dev hosts this session, run from an external terminal.
   Do not bypass `Tools/guard.sh`.
4. Verify the installed bundle, especially when using `--no-launch`:

   ```sh
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HOME/Applications/Bloom Dev.app/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Print :BloomMasterCommit' "$HOME/Applications/Bloom Dev.app/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Print :LSEnvironment:BLOOM_DB_PATH' "$HOME/Applications/Bloom Dev.app/Contents/Info.plist"
   codesign --verify --deep --strict "$HOME/Applications/Bloom Dev.app"
   ```

   Expect `be.spatie.bloom.dev`, the selected commit's short hash, and the database under
   `~/Library/Application Support/Bloom Dev/`. Report the installed path and revision.
5. When launching is part of the user's request, use LaunchServices:

   ```sh
   open -g "$HOME/Applications/Bloom Dev.app"
   ```

   `make dev` or the script without `--no-launch` also quits and relaunches existing dev processes.
   Use that only when restarting the dev app is authorised. `--no-launch` still replaces the
   installed bundle; it does not restart an already running copy into the new code.

For compile-only work use `make build`. Run relevant tests and linters as described in `CLAUDE.md`;
`make test` covers the core and does not prove the app compiles.

Do not use `make master`, `make run`, or `make app` to obtain an isolated dev app: they retain the
production identity. Leave the production app, database and preferences alone. Start dev with an
empty database unless copying data was requested; `make dev-db` replaces dev data and is optional.

On build failure, read `/tmp/bloom-dev-build.log`. A compile failure leaves the prior install in
place; a later signing failure can leave a broken new bundle. Report the actual failure stage.
