#!/bin/zsh
# Builds a Bloom anyone can open, and leaves both a zip and the beach disk
# image in dist/.
#
#   ./Tools/release.sh              build HEAD, which is also `make release`
#   ./Tools/release.sh <ref>        build that commit or branch
#   ./Tools/release.sh --tag v1.4.0 stamp that version rather than the plist's
#   ./Tools/release.sh --no-dmg     skip the image, when you only want the zip
#
# The image is the artefact the website hands a person, so it is built here as
# well as in CI. Building it only in CI would mean the one thing a stranger
# downloads is the one thing nobody had ever produced on a machine they could
# look at, and this is where you check it before a tag exists.
#
# What this does that ./Tools/master.sh does not: it signs with a real Developer ID,
# turns on the hardened runtime, sends the result to Apple to be notarised, and
# staples the ticket onto the app. Without all four steps macOS refuses to open
# a downloaded app without the user going into System Settings, which on recent
# versions is several clicks buried in Privacy and Security.
#
# The signing, notarising and stapling live in Tools/release/package-app.sh,
# which the release workflow calls as well. There is one copy of that sequence
# on purpose: a local release and a CI release differing in how they sign is
# the kind of difference nobody notices until a user cannot open the app.
#
# It needs two things set up once. Neither can be scripted, because both are
# bound to an Apple ID. RELEASING.md has the long version of both.
#
#   1. A Developer ID Application certificate.
#      Xcode, Settings, Accounts, pick the team, Manage Certificates, plus,
#      Developer ID Application. It needs a paid membership. The "Apple
#      Development" certificate is NOT this: that one only signs for your own
#      machine.
#
#   2. A stored notarytool credential named `bloom`.
#      Make an app-specific password at appleid.apple.com, then once:
#
#        xcrun notarytool store-credentials bloom \
#          --apple-id you@example.com --team-id <TEAMID> --password <app-specific>
#
# Then set the identity, once, in your shell profile:
#
#   export BLOOM_CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"

set -euo pipefail
cd "$(dirname "$0")/.."

REF=HEAD
TAG=${BLOOM_RELEASE_TAG:-}
WANT_DMG=1

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=$2; shift 2 ;;
    --no-dmg) WANT_DMG=0; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) REF=$1; shift ;;
  esac
done

RESOLVED="$(git rev-parse --short "$REF")"
WORK=/tmp/bloom-release-src
OUT="$PWD/dist"
TOOLS="$PWD/Tools/release"

echo "==> $RESOLVED  $(git log -1 --format=%s "$REF")"

# Before the build rather than after it. Everything this checks is a thing that
# was either set up months ago or never, and finding out which one after a full
# release compile is a waste of five minutes every time.
"$TOOLS/package-app.sh" --preflight

# The version comes from the tag when there is one, so what the bundle says and
# what the release is called cannot disagree. Without a tag this is a build for
# one person to try, and the plist's own version is the honest answer.
if [ -n "$TAG" ]; then
  eval "$("$TOOLS/version.sh" "$TAG" "$REF")"
else
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  build="$(git rev-list --count "$REF")"
fi

# Same reasoning as Tools/master.sh: a detached worktree at a commit, and a scratch
# path of its own, so nothing uncommitted and nothing from a concurrent build
# can end up in something being sent to another person.
git worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git worktree add --detach "$WORK" "$RESOLVED" >/dev/null
# Same as Tools/master.sh: a ref from before the build script moved into Tools still
# keeps it at the root, and a release cut from an older tag has to keep working.
BUILD_SCRIPT=Tools/build.sh
[ -x "$WORK/$BUILD_SCRIPT" ] || BUILD_SCRIPT=build.sh
# Captured rather than sent to /dev/null, for the reason written at length in Tools/master.sh:
# `swift build` reports compiler errors on stdout, so the old bare redirect threw away the only
# account of a failed release build and left `set -e` stopping with nothing to read.
BUILD_LOG=/tmp/bloom-release-build.log
if ! ( cd "$WORK" && BLOOM_CODESIGN_IDENTITY="${BLOOM_CODESIGN_IDENTITY:-}" \
    "./$BUILD_SCRIPT" -r ) >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  print -ru2 -- ""
  print -ru2 -- "==> the release build failed. The whole log is above, and in $BUILD_LOG."
  print -ru2 -- "    Nothing was signed or sent to Apple."
  exit 1
fi

APP="$WORK/.build/release/Bloom.app"
[ -d "$APP" ] || APP="$(cd "$WORK" && swift build -c release --show-bin-path)/Bloom.app"

mkdir -p "$OUT"
ZIP="$OUT/Bloom-$version.zip"
DMG="$OUT/Bloom-$version.dmg"

DMG_ARGS=()
[ "$WANT_DMG" -eq 1 ] && DMG_ARGS=(--dmg "$DMG")

# Tools/build.sh signs, but without the hardened runtime, which notarisation
# requires. Signed again in there rather than teaching Tools/build.sh about it,
# because a debug build wants to stay easy to attach a debugger to.
( cd "$WORK" && "$TOOLS/package-app.sh" \
    --app "$APP" --zip "$ZIP" "${DMG_ARGS[@]}" --version "$version" --build "$build" )

git worktree remove --force "$WORK" 2>/dev/null || true

echo "==> $ZIP"
# An if rather than a trailing `&&`: this is the last line of the script, and
# under `set -e` a false test on the last line is the script's exit status.
if [ "$WANT_DMG" -eq 1 ]; then
  echo "==> $DMG"
fi
