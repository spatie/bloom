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
#
# Which is why it refuses to run from inside the copy it would replace. Bloom is
# developed in Bloom now, so this script can be started by an agent whose own
# host is the app at the other end of the `rm -rf` below. `Tools/guard.sh` says
# how that is detected. An agent that wants a build it can install should run
# `make dev`, which installs a second identity and cannot reach this one.

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
WORK=/tmp/bloom-master-src
DEST="$BLOOM_REAL_APP"

# Before the build, not after it. The refusal does not become less true for
# having spent two minutes compiling first.
bloom_refuse_if_own_host "$DEST" "$BLOOM_REAL_DB"

echo "==> $RESOLVED  $SUBJECT"

# A detached worktree at the commit, so nothing uncommitted comes along.
git worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git worktree add --detach "$WORK" "$RESOLVED" >/dev/null

# Runs a command in the worktree, quiet when it works and printed in full when
# it does not.
#
# Both build lines below used to end in `>/dev/null`, and `swift build` writes
# compiler errors to STDOUT rather than to stderr, so that redirect threw away
# the only account of what had gone wrong. `set -e` still stopped the script, but
# it stopped after a minute of work with nothing to read, which the next person
# takes for a broken script rather than broken code. Silencing a build that works
# is worth it, since it is a page of module names nobody reads. Silencing one
# that fails costs the only thing anybody wanted from it.
#
# Printed whole rather than tailed: Swift reports the first error at the top and
# carries on compiling, so the line that explains the failure is not reliably at
# the end.
BUILD_LOG=/tmp/bloom-master-build.log
build_in_worktree() {
  if ! ( cd "$WORK" && "$@" ) >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG" >&2
    print -ru2 -- ""
    print -ru2 -- "==> the build failed. The whole log is above, and in $BUILD_LOG."
    print -ru2 -- "    Nothing was installed, so $DEST is whatever it was before."
    exit 1
  fi
}

# Its own scratch path, so a concurrent agent build cannot swap objects underneath.
build_in_worktree swift build -c release --product Bloom --scratch-path /tmp/bloom-master-build

# The worktree holds whatever that ref held, and the build script has only lived
# in Tools since today. Pinning to a commit from before the move is the whole
# point of taking a ref, so both places are looked in rather than one.
BUILD_SCRIPT=Tools/build.sh
[ -x "$WORK/$BUILD_SCRIPT" ] || BUILD_SCRIPT=build.sh
build_in_worktree "./$BUILD_SCRIPT" -r

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
