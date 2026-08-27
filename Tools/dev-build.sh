#!/bin/zsh
# Builds a Bloom that is not the owner's and installs it beside his, under its
# own name, its own icon and its own database.
#
#   ./Tools/dev-build.sh                  build HEAD as Bloom Dev, install, relaunch it
#   ./Tools/dev-build.sh --identity ssh   build it as Bloom SSH instead
#   ./Tools/dev-build.sh <ref>            build that commit or branch instead
#   ./Tools/dev-build.sh --no-launch      install without restarting the copy
#
# `make dev` and `make ssh` are the first two of those.
#
# ONE SCRIPT, EVERY IDENTITY BUT THE OWNER'S, AND WHY NOT ONE SCRIPT EACH. Bloom
# SSH wanted every line of this: the same plist edits, the same anchored source
# patches, the same detached worktree, the same refusal to install over anything
# running, and the same read-the-environment-back check at the foot. A copy with
# the strings changed would have been a second script agreeing with this one by
# coincidence, and the coincidence would have ended at the first anchor that
# moved, leaving one build failing loudly and the other installing a copy wearing
# the real name. So the strings are a table in Tools/guard.sh, this takes a key,
# and the next identity is four entries in that table and a Makefile line.
#
# The file is still called dev-build.sh, which now names only the first thing it
# builds. It is kept because everything points here: `make dev`, `make ssh`,
# CLAUDE.md, and the refusal message in Tools/guard.sh that tells somebody which
# target to run instead. A rename would be worth exactly one word of accuracy.
#
# WHY A SEPARATE IDENTITY AND NOT A SEPARATE BUILD. Two copies of the same bundle
# id are the same app twice: same Application Support container, same preferences
# domain, same saved window state, same tmux sockets, same database. An agent
# clicking around in one of them archives the other one's workspaces. So this
# does not build a different Bloom, it builds Bloom AS SOMEBODY ELSE, and every
# separation macOS gives us follows from the bundle id:
#
#   the bundle id   its own `defaults` domain and its own saved window state
#   BLOOM_DB_PATH   its own database, through LSEnvironment in Info.plist, which
#                   `Store.defaultPath` already honours, and, if that never
#                   arrives because the executable was run rather than opened,
#                   through the bundle id again: the fallback directory is
#                   derived from it. The tmux socket is derived from the database
#                   path, so that separates too, and so does the notification
#                   identifier
#   the URL scheme  its own, so this copy cannot steal a `bloom://` deep link
#                   meant for the copy in daily use
#
# WHAT THE SSH IDENTITY IS FOR, since it is the one that needs saying. The work on
# driving agents over SSH points a build at real servers, and the copy the owner
# works in must never be that build: a run that reaches somebody's host is a run
# whose blast radius is not this Mac. It holds its own database for the same
# reason and one more, which is that the rows are not the same rows. That database
# will hold servers, not just workspaces, so it is not a copy of his that has
# drifted, it is a different set of facts that has no business in the copy he
# works in and would be carried back into it by any sharing at all.
#
# HOW A COPY IS TOLD APART, which matters more than any of the above because the
# failure is the owner typing into the wrong window:
#
#   the icon      rotated round the colour wheel, so the same drawing arrives in
#                 rust and orange, or in violet, instead of teal and navy. The
#                 turn is per identity: Tools/icon/tint.py argues the three
#   the name      "Bloom Dev" or "Bloom SSH" in the Dock, in the Cmd-Tab switcher
#                 and as the first item of the menu bar
#   the title     every window title is prefixed "[DEV] " or "[SSH] "
#
# HOW THE THREE MARKS ARE APPLIED. Not by committing a second Info.plist, a
# second icon and a branch in a view. They are applied to the detached worktree
# this builds from, so the repository has one identity and this script owns every
# other one entirely. Each edit checks its own anchor and stops the build if it
# has moved, because a side build wearing the real icon and the real name is the
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
IDENTITY=dev
while (( $# > 0 )); do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    # A key rather than a name, and validated by `bloom_use_identity` against the
    # list of identities a build may install. "real" is not on that list, which is
    # what stops `--identity real` from being the shortest route to replacing the
    # owner's copy.
    --identity)
      shift
      (( $# > 0 )) || { echo "--identity needs one of: ${BLOOM_INSTALLABLE_IDENTITIES[*]}" >&2; exit 1 }
      IDENTITY="$1"
      ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) REF="$1" ;;
  esac
  shift
done

bloom_use_identity "$IDENTITY"

RESOLVED="$(git rev-parse --short "$REF")"
SUBJECT="$(git log -1 --format=%s "$REF")"
# Per identity, both of them. The worktree because two identities are two
# different sets of source patches and one directory cannot hold both, and the
# build scratch because sharing it would mean each build invalidating the other's
# incremental state on every run, which is the whole benefit of keeping it.
WORK="/tmp/bloom-$BLOOM_ID-src"
DEST="$BLOOM_APP"

# This script has the same shape as Tools/master.sh and therefore the same
# hazard: an agent running inside the copy being replaced would have this kill
# its own host. The two lines under it are belt and braces against a typo or a
# stale environment ever pointing DEST somewhere it was never meant to go: the
# first names the one destination that is never acceptable, and the second says
# what the destination must instead BE, which is one of two paths.
bloom_refuse_if_own_host "$DEST" "$BLOOM_DB"
bloom_refuse_real_app "$DEST"
bloom_require_installable_app "$DEST"

echo "==> $BLOOM_NAME  $RESOLVED  $SUBJECT"

git worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git worktree add --detach "$WORK" "$RESOLVED" >/dev/null

# ---------------------------------------------------------------- the identity

PLIST="$WORK/Resources/Info.plist"
# The redirect hides the value PlistBuddy echoes back and nothing else: it
# reports a missing key or a malformed command on stderr and exits 1, so a
# mistyped key path still stops the build under `set -e`. Measured, because a
# silent identity edit is how a dev build ends up wearing the real name.
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null; }

plist "Set :CFBundleName $BLOOM_NAME"
plist "Set :CFBundleDisplayName $BLOOM_NAME"
plist "Set :CFBundleIdentifier $BLOOM_BUNDLE_ID"
plist "Set :CFBundleURLTypes:0:CFBundleURLName $BLOOM_BUNDLE_ID.deeplink"
plist "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $BLOOM_SCHEME"
plist "Set :NSServices:0:NSPortName $BLOOM_NAME"
plist "Set :NSServices:0:NSMenuItem:default New $BLOOM_NAME Workspace"

# The database, and the only reason the dev copy is safe to click around in.
#
# LSEnvironment is a real dictionary of environment variables that LaunchServices
# puts into the process it starts, so `Store.defaultPath` finds BLOOM_DB_PATH in
# `ProcessInfo.processInfo.environment` exactly as it would from a shell. It has
# to be an absolute path: LSEnvironment expands nothing, so `$HOME` is resolved
# here and baked in.
#
# It is applied by LaunchServices, which means it applies when the app is opened
# and not when its executable is run directly. Open the copy with `open` or from
# the Dock. A build launched as ~/Applications/Bloom Dev.app/Contents/MacOS/Bloom
# has no BLOOM_DB_PATH at all. That used to be the one way to defeat all of this,
# and it is not any more: `Store.databaseDirectoryName` derives the fallback
# directory from the bundle id, and every identity's id resolves to the same
# directory this key names rather than to the real one. So this key is belt now,
# not the only strap, and the two have to agree on the path, which is why both
# come from the one table in Tools/guard.sh and why
# Tests/BloomCoreTests/DatabaseDirectoryTests.swift holds the Swift half of the
# agreement. The check at the foot of this script reads the value back out of the
# launched process rather than assuming it arrived.
#
# The delete is the one call here allowed to fail, because Resources/Info.plist
# does not carry an LSEnvironment and PlistBuddy treats deleting an absent key as
# an error. The two Adds under it are not allowed to fail, and do not.
plist "Delete :LSEnvironment" 2>/dev/null || true
plist "Add :LSEnvironment dict"
plist "Add :LSEnvironment:BLOOM_DB_PATH string $BLOOM_DB"

# The icon, recoloured in place in the worktree. Same document, same layer names,
# same CFBundleIconName, so Tools/build.sh compiles it with actool unchanged. The
# turn comes from the identity table; the script refuses a turn of nothing, so an
# identity that lost its entry fails here rather than installing a copy wearing
# the real icon.
python3 Tools/icon/tint.py "$BLOOM_ICON_TURN" "$WORK/Resources/Bloom.icon/icon.json"

# The window title, in all three of the places that set one.
#
# Three, and finding the third took two dev builds that came out titled "Bloom"
# with the marks provably compiled into them:
#
#   RootView's `.navigationTitle`  the one that actually wins. SwiftUI reapplies
#                                  it on every update of the view, so it is the
#                                  last writer whatever the other two did
#   the `Window` scene's title     what the window is called before the first
#                                  update, and what the Window menu shows if the
#                                  view above it never renders
#   WindowTitle                    sets `window.title` imperatively, on AppKit,
#                                  when the selection changes. It was
#                                  `WindowProxyIcon` and the anchor went stale
#                                  when the proxy icon was dropped, which is the
#                                  failure this guard is for and the reason it
#                                  names the file: `make dev` refused to build
#                                  until the anchor was pointed here
#
# All three are marked rather than only the winner, because which of them wrote
# the title last is a matter of timing, and a title that loses its mark for a
# frame whenever SwiftUI happens to run in a different order is exactly as
# dangerous as one that never had it: the owner glances at the window and reads
# the wrong one.
#
# How the third was found, so nobody repeats it: `strings` on the built binary
# does NOT prove a mark arrived. Swift stores a literal of fifteen UTF-8 bytes or
# fewer inline in the code rather than in a string table, and "[DEV] Bloom" is
# eleven, so it never appears in the output. Patching in a marker long enough to
# land in the table showed both marks present in a binary whose window still read
# "Bloom", which is what pointed at a third writer rather than at a broken patch.
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

patch_source "$WORK/Sources/Bloom/Views/Chrome/Window/WindowTitle.swift" \
  '        window.title = value' \
  "        window.title = \"$BLOOM_TITLE_MARK\" + value"

patch_source "$WORK/Sources/Bloom/BloomApp.swift" \
  '        Window("Bloom", id: Self.mainWindowID) {' \
  "        Window(\"${BLOOM_TITLE_MARK}Bloom\", id: Self.mainWindowID) {"

patch_source "$WORK/Sources/Bloom/Views/RootView.swift" \
  '            .navigationTitle(app.menuWorkspace?.name ?? "Bloom")' \
  "            .navigationTitle(\"$BLOOM_TITLE_MARK\" + (app.menuWorkspace?.name ?? \"Bloom\"))"

# ------------------------------------------------------------------- the build

# The worktree's `.build` is a symlink into a scratch directory that outlives it.
#
# Two things at once. The worktree is thrown away and recut on every run, so
# without this every dev build is a cold release build of the whole package,
# which is minutes; through the symlink Swift Package Manager sees the same paths
# it saw last time and rebuilds what changed. And the scratch is still this
# script's alone, so a concurrent agent build cannot swap objects underneath it,
# which is the reason Tools/master.sh takes a scratch path of its own.
mkdir -p "/tmp/bloom-$BLOOM_ID-build"
ln -sfn "/tmp/bloom-$BLOOM_ID-build" "$WORK/.build"

# The bundle the last run left in that scratch, removed before this one starts.
#
# The scratch outliving the worktree is what makes a rebuild take seconds, and it
# is also the one way this script could install something it never built.
# Tools/build.sh assembles the bundle at .build/release/Bloom.app, and a build
# that fails before it reaches that step leaves the previous run's bundle sitting
# at exactly the path the copy below reads. Nothing downstream can tell a bundle
# from twenty minutes ago apart from a fresh one: same path, same name, same
# shape. So the old one goes first, and the only bundle that can be installed is
# one this run produced.
rm -rf "$WORK/.build/release/Bloom.app"

# The build, kept quiet when it works and printed in full when it does not.
#
# This line used to end in `>/dev/null`, and `swift build` writes compiler errors
# to STDOUT rather than to stderr, so that redirect threw away the only account
# of what had gone wrong. The script still stopped, `set -e` sees a failing
# subshell perfectly well, but it stopped after forty seconds with four lines of
# output and no mention of the error, which is worse than a noisy failure: the
# next person reads it as the script being broken rather than the code.
#
# Kept in a file rather than left on the terminal, because a build that works is
# a page of module names nobody reads. Printed WHOLE rather than tailed, because
# a tail is the same mistake in smaller print: Swift reports the first error at
# the top and then keeps compiling, so the line that explains the failure is not
# reliably in the last forty.
BUILD_LOG="/tmp/bloom-$BLOOM_ID-build.log"
if ! ( cd "$WORK" && ./Tools/build.sh -r ) >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  print -ru2 -- ""
  print -ru2 -- "==> the $BLOOM_NAME build failed. The whole log is above, and in $BUILD_LOG."
  print -ru2 -- "    Nothing was installed, so $DEST is whatever it was before."
  exit 1
fi

BUILT="$WORK/.build/release/Bloom.app"
[ -d "$BUILT" ] || BUILT="$(cd "$WORK" && swift build -c release --show-bin-path)/Bloom.app"

# Belt and braces on the removal above. A build that reports success without
# leaving a bundle behind must not reach the copy below, because the only thing
# there would be to copy is whatever somebody else put there.
if [[ ! -d "$BUILT" ]]; then
  print -ru2 -- "==> the build reported success but left no bundle at $BUILT"
  exit 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# What this is, so a stale install can be identified without guessing. The same
# key Tools/master.sh writes, plus one that says this is not the owner's copy and
# one that says which of the side identities it is.
#
# Three keys rather than two because `BloomDevBuild` answers "is this a side
# build" and stopped answering "which one" the moment there were two of them, and
# it is read by nothing in the app, so narrowing it would have been a silent
# change to the only fact a confused reader has. The identity key is the key,
# which is also the `make` target that rebuilds it.
#
# These used to end in `|| true`, which is the wrong trade for the one set of
# keys anybody reads when they are already confused about which build they are
# looking at. If the stamp cannot be written the bundle is unidentifiable, and
# that is worth stopping for.
/usr/bin/defaults write "$DEST/Contents/Info.plist" BloomMasterCommit -string "$RESOLVED"
/usr/bin/defaults write "$DEST/Contents/Info.plist" BloomDevBuild -bool true
/usr/bin/defaults write "$DEST/Contents/Info.plist" BloomBuildIdentity -string "$BLOOM_ID"

# Re-signed, because the two writes above invalidated the signature Tools/build.sh
# applied. Same identity resolution as that script, so a machine with a real one
# configured keeps it and everything else stays ad-hoc.
#
# Not `|| true`, unlike the equivalent line in Tools/build.sh. There the bundle
# has never been signed and an unsigned one still launches, so a failure costs
# only App Intents. Here the signature was valid until the two writes above broke
# it, and macOS kills a bundle whose signature no longer matches its contents. A
# swallowed failure would surface three steps down as "launched, but no process
# is running from ...", which is true and says nothing about the cause.
if ! signing="$(codesign --force --deep --sign "${BLOOM_CODESIGN_IDENTITY:-${BATON_CODESIGN_IDENTITY:--}}" "$DEST" 2>&1)"; then
  print -ru2 -- "$signing"
  print -ru2 -- "==> re-signing $DEST failed, so it would not launch. The bundle is"
  print -ru2 -- "    on disk and broken; fix the signing identity and run this again."
  exit 1
fi

# LaunchServices caches Info.plist per bundle, LSEnvironment included, so a
# rebuild that changed it is not seen until the bundle is registered again.
#
# Best effort on purpose, and the only redirect here that hides a failure. A
# refused registration leaves a stale LSEnvironment, which is caught by the check
# at the foot of this script rather than being trusted, and lsregister has no
# useful exit status to act on anyway.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

git worktree remove --force "$WORK" 2>/dev/null || true

echo "==> installed $DEST"
echo "==> database $BLOOM_DB"

if [ "$LAUNCH" -eq 1 ]; then
  # By pid, and only pids of the bundle this run installed. Every other copy is a
  # different executable path, so none of them is ever a candidate. No pattern
  # kill anywhere near this: `pkill -f Bloom` would take the owner's app with it.
  for pid in $(bloom_app_pids "$DEST"); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  open "$DEST"
  sleep 3

  # Nothing above proves this copy is on its own database. `ps -E` prints the
  # environment of a process this user owns, which is the only honest answer:
  # LaunchServices could have served a cached Info.plist, or somebody could have
  # started the executable directly. A side copy silently running against the real
  # database is the failure this whole file exists to prevent, so it is checked.
  running="$(bloom_app_pids "$DEST" | head -1)"
  if [[ -z "$running" ]]; then
    echo "==> launched, but no process is running from $DEST" >&2
    exit 1
  fi
  if ps -E -p "$running" 2>/dev/null | grep -q "BLOOM_DB_PATH=$BLOOM_DB"; then
    echo "==> launched pid $running, on its own database"
  else
    # Not "on the REAL database" any more: with no BLOOM_DB_PATH, Store derives the directory
    # from this bundle id and lands on this identity's own anyway. But a missing key means
    # LaunchServices served a stale plist or the executable was run by hand, and this build is
    # down to one mechanism where two agreeing ones are the point, so it still stops.
    echo "==> pid $running has no BLOOM_DB_PATH. The bundle id fallback is holding the" >&2
    echo "    separation alone. Quit it, then start it again with: open \"$DEST\"" >&2
    exit 1
  fi
fi
