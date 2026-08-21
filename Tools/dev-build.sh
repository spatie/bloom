#!/bin/zsh
# Builds the second Bloom, the one Bloom is developed in, and installs it to
# ~/Applications/Bloom Dev.app.
#
#   ./Tools/dev-build.sh              build HEAD, install, relaunch the dev copy
#   ./Tools/dev-build.sh <ref>        build that commit or branch instead
#   ./Tools/dev-build.sh --no-launch  install without restarting the dev copy
#
# `make dev` is the first of those.
#
# WHY A SECOND IDENTITY AND NOT A SECOND BUILD. Two copies of the same bundle id
# are the same app twice: same Application Support container, same preferences
# domain, same saved window state, same tmux sockets, same database. An agent
# clicking around in one of them archives the other one's workspaces. So this
# does not build a different Bloom, it builds Bloom AS SOMEBODY ELSE, and every
# separation macOS gives us follows from the bundle id:
#
#   be.spatie.bloom.dev   its own `defaults` domain and its own saved window state
#   BLOOM_DB_PATH         its own database, through LSEnvironment in Info.plist,
#                         which `Store.defaultPath` already honours. The tmux
#                         socket is derived from the database path, so that
#                         separates too, and so does the notification identifier
#   bloomdev:             its own URL scheme, so the dev copy cannot steal a
#                         `bloom://` deep link meant for the copy in daily use
#
# HOW IT IS TOLD APART, which matters more than any of the above because the
# failure is the owner typing into the wrong window:
#
#   the icon      half a turn round the colour wheel, so the same drawing arrives
#                 in rust and orange instead of teal and navy. Tools/icon/dev-tint.py
#   the name      "Bloom Dev" in the Dock, in the Cmd-Tab switcher and as the
#                 first item of the menu bar
#   the title     every window title is prefixed "[DEV] "
#
# HOW THE THREE MARKS ARE APPLIED. Not by committing a second Info.plist, a
# second icon and a branch in a view. They are applied to the detached worktree
# this builds from, so the repository has one identity and this script owns the
# second one entirely. Each edit checks its own anchor and stops the build if it
# has moved, because a dev build wearing the real icon and the real name is the
# one outcome worth failing over.
#
# The rest is Tools/master.sh's shape and for its reasons: a detached worktree at
# a commit, because the working tree is mid edit at any moment and may not
# compile, and its own scratch path, because agents share `.build` and a build
# that races another agent's edits is a mixture of two states.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/Tools/guard.sh"

REF=HEAD
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) REF="$arg" ;;
  esac
done

RESOLVED="$(git rev-parse --short "$REF")"
SUBJECT="$(git log -1 --format=%s "$REF")"
WORK=/tmp/bloom-dev-src
DEST="$BLOOM_DEV_APP"

# This script has the same shape as Tools/master.sh and therefore the same
# hazard: an agent running inside the DEV copy would have this replace and kill
# its own host. The second line is belt and braces against a typo or a stale
# environment ever pointing DEST at the copy the owner is using.
bloom_refuse_if_own_host "$DEST" "$BLOOM_DEV_DB"
bloom_refuse_real_app "$DEST"

echo "==> $RESOLVED  $SUBJECT"

git worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git worktree add --detach "$WORK" "$RESOLVED" >/dev/null

# ---------------------------------------------------------------- the identity

PLIST="$WORK/Resources/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null; }

plist "Set :CFBundleName Bloom Dev"
plist "Set :CFBundleDisplayName Bloom Dev"
plist "Set :CFBundleIdentifier $BLOOM_DEV_BUNDLE_ID"
plist "Set :CFBundleURLTypes:0:CFBundleURLName $BLOOM_DEV_BUNDLE_ID.deeplink"
plist "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 bloomdev"
plist "Set :NSServices:0:NSPortName Bloom Dev"
plist "Set :NSServices:0:NSMenuItem:default New Bloom Dev Workspace"

# The database, and the only reason the dev copy is safe to click around in.
#
# LSEnvironment is a real dictionary of environment variables that LaunchServices
# puts into the process it starts, so `Store.defaultPath` finds BLOOM_DB_PATH in
# `ProcessInfo.processInfo.environment` exactly as it would from a shell. It has
# to be an absolute path: LSEnvironment expands nothing, so `$HOME` is resolved
# here and baked in.
#
# It is applied by LaunchServices, which means it applies when the app is opened
# and not when its executable is run directly. Open the dev copy with `open` or
# from the Dock. A build launched as ~/Applications/Bloom Dev.app/Contents/MacOS/Bloom
# has no BLOOM_DB_PATH and would fall back to the real database, which is the one
# way to defeat all of this. The check at the foot of this script reads the value
# back out of the launched process rather than assuming it arrived.
plist "Delete :LSEnvironment" 2>/dev/null || true
plist "Add :LSEnvironment dict"
plist "Add :LSEnvironment:BLOOM_DB_PATH string $BLOOM_DEV_DB"

# The icon, recoloured in place in the worktree. Same document, same layer names,
# same CFBundleIconName, so Tools/build.sh compiles it with actool unchanged.
python3 Tools/icon/dev-tint.py "$WORK/Resources/Bloom.icon/icon.json"

# The window title, in both of the places that set one.
#
# `WindowProxyIcon` writes the title from the selected workspace, so once
# anything is selected there is no static string in the scene left to change. But
# the scene's own title is what a freshly launched window shows, and SwiftUI
# applies it after that modifier's first pass, so marking only the modifier
# leaves the dev copy titled "Bloom" for as long as nobody has clicked a
# workspace. Measured rather than assumed: the first dev build carried the
# modifier mark alone and its window still read "Bloom" on launch.
#
# One anchored substitution each, and a build that stops if an anchor has moved.
# A dev copy wearing the real name is the one outcome worth failing over.
patch_source() {
  local file="$1" anchor="$2" replacement="$3" matches
  matches="$(grep -c -x -F -- "$anchor" "$file" || true)"
  if [[ "$matches" != "1" ]]; then
    cat >&2 <<EOF
==> an anchor Tools/dev-build.sh marks the dev build with has moved.

    Expected exactly one line reading

      $anchor

    in ${file#$WORK/}, found $matches.

    Refusing to build rather than installing a dev copy that looks like the real
    one. Point the anchor at wherever that line lives now.
EOF
    exit 1
  fi
  # Python rather than sed, so neither the anchor nor the replacement has to be
  # escaped for a regular expression. Both are Swift, and Swift is full of
  # characters sed reads as syntax.
  /usr/bin/python3 -c '
import sys

path, anchor, replacement = sys.argv[1:4]
with open(path) as handle:
    text = handle.read()
with open(path, "w") as handle:
    handle.write(text.replace(anchor + "\n", replacement + "\n", 1))
' "$file" "$anchor" "$replacement"
}

patch_source "$WORK/Sources/Bloom/Views/Chrome/WindowProxyIcon.swift" \
  '        window.title = value.title' \
  '        window.title = "[DEV] " + value.title'

patch_source "$WORK/Sources/Bloom/BloomApp.swift" \
  '        Window("Bloom", id: "main") {' \
  '        Window("[DEV] Bloom", id: "main") {'

# ------------------------------------------------------------------- the build

# The worktree's `.build` is a symlink into a scratch directory that outlives it.
#
# Two things at once. The worktree is thrown away and recut on every run, so
# without this every dev build is a cold release build of the whole package,
# which is minutes; through the symlink Swift Package Manager sees the same paths
# it saw last time and rebuilds what changed. And the scratch is still this
# script's alone, so a concurrent agent build cannot swap objects underneath it,
# which is the reason Tools/master.sh takes a scratch path of its own.
mkdir -p /tmp/bloom-dev-build
ln -sfn /tmp/bloom-dev-build "$WORK/.build"

( cd "$WORK" && ./Tools/build.sh -r >/dev/null )

BUILT="$WORK/.build/release/Bloom.app"
[ -d "$BUILT" ] || BUILT="$(cd "$WORK" && swift build -c release --show-bin-path)/Bloom.app"

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# What this is, so a stale install can be identified without guessing. The same
# key Tools/master.sh writes, plus one that says which of the two this is.
/usr/bin/defaults write "$DEST/Contents/Info.plist" BloomMasterCommit -string "$RESOLVED" 2>/dev/null || true
/usr/bin/defaults write "$DEST/Contents/Info.plist" BloomDevBuild -bool true 2>/dev/null || true

# Re-signed, because the two writes above invalidated the signature Tools/build.sh
# applied. Same identity resolution as that script, so a machine with a real one
# configured keeps it and everything else stays ad-hoc.
codesign --force --deep --sign "${BLOOM_CODESIGN_IDENTITY:-${BATON_CODESIGN_IDENTITY:--}}" "$DEST" >/dev/null 2>&1 || true

# LaunchServices caches Info.plist per bundle, LSEnvironment included, so a
# rebuild that changed it is not seen until the bundle is registered again.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

git worktree remove --force "$WORK" 2>/dev/null || true

echo "==> installed $DEST"
echo "==> database $BLOOM_DEV_DB"

if [ "$LAUNCH" -eq 1 ]; then
  # By pid, and only pids of the dev bundle. The real copy is a different
  # executable path, so it is never a candidate. No pattern kill anywhere near
  # this: `pkill -f Bloom` would take the owner's app with it.
  for pid in $(bloom_app_pids "$DEST"); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  open "$DEST"
  sleep 3

  # Nothing above proves the dev copy is on its own database. `ps -E` prints the
  # environment of a process this user owns, which is the only honest answer:
  # LaunchServices could have served a cached Info.plist, or somebody could have
  # started the executable directly. A dev copy silently running against the real
  # database is the failure this whole file exists to prevent, so it is checked.
  running="$(bloom_app_pids "$DEST" | head -1)"
  if [[ -z "$running" ]]; then
    echo "==> launched, but no process is running from $DEST" >&2
    exit 1
  fi
  if ps -E -p "$running" 2>/dev/null | grep -q "BLOOM_DB_PATH=$BLOOM_DEV_DB"; then
    echo "==> launched pid $running, on its own database"
  else
    echo "==> pid $running has no BLOOM_DB_PATH and is on the REAL database. Quit it now." >&2
    exit 1
  fi
fi
