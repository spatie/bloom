#!/bin/zsh
# Builds a copy of Bloom for the owner to actually use, and installs it to
# ~/Applications/Bloom.app.
#
#   ./Tools/master.sh              build HEAD, install, relaunch
#   ./Tools/master.sh <ref>        build that commit or branch instead
#   ./Tools/master.sh --no-launch  install without restarting the running app
#
# `make master` is the first of those. The other two want an argument, so
# they are run directly.
#
# Why this exists, and why it is not just `./Tools/build.sh`:
#
# Agents work in this repository continuously, so at any moment the working
# tree can be mid edit and may not compile. It builds from a detached worktree
# at a commit, so what gets installed is a state that was committed on purpose
# rather than whatever the tree happens to hold.
#
# It also builds into its own scratch directory. Agents share `.build`, and a
# build that races another agent's edits produces a binary that is a mixture of
# two states. That has already cost two agents a set of measurements they had
# to throw away, and it would be far worse here, where the result is the app
# somebody is trying to use.
#
# The installed app keeps the real bundle id, so it uses the real database and
# the real preferences. Agents re-identify their own builds precisely so that
# they never collide with this one.

set -euo pipefail
cd "$(dirname "$0")/.."

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
WORK=/tmp/bloom-master-src
DEST="$HOME/Applications/Bloom.app"

echo "==> $RESOLVED  $SUBJECT"

# A detached worktree at the commit, so nothing uncommitted comes along.
git worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git worktree add --detach "$WORK" "$RESOLVED" >/dev/null

# Its own scratch path, so a concurrent agent build cannot swap objects underneath.
( cd "$WORK" && swift build -c release --product Bloom --scratch-path /tmp/bloom-master-build >/dev/null )

# The worktree holds whatever that ref held, and the build script has only lived
# in Tools since today. Pinning to a commit from before the move is the whole
# point of taking a ref, so both places are looked in rather than one.
BUILD_SCRIPT=Tools/build.sh
[ -x "$WORK/$BUILD_SCRIPT" ] || BUILD_SCRIPT=build.sh
( cd "$WORK" && "./$BUILD_SCRIPT" -r >/dev/null )

BUILT="$WORK/.build/release/Bloom.app"
[ -d "$BUILT" ] || BUILT="$(cd "$WORK" && swift build -c release --show-bin-path)/Bloom.app"

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# Record what this is, so a stale install can be identified without guessing.
/usr/bin/defaults write "$DEST/Contents/Info.plist" BloomMasterCommit -string "$RESOLVED" 2>/dev/null || true

git worktree remove --force "$WORK" 2>/dev/null || true

echo "==> installed $DEST"

if [ "$LAUNCH" -eq 1 ]; then
  # Only ever kills the installed copy. A debug build running from .build, and
  # any agent's re-identified build, are left alone.
  pkill -f "$DEST/Contents/MacOS/Bloom" 2>/dev/null || true
  sleep 1
  open "$DEST"
  echo "==> launched"
fi
