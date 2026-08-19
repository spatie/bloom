#!/bin/zsh
# Builds a Bloom anyone can open, and leaves it in a zip you can send.
#
#   ./release.sh              build HEAD
#   ./release.sh <ref>        build that commit or branch
#
# What this does that ./master.sh does not: it signs with a real Developer ID,
# turns on the hardened runtime, sends the result to Apple to be notarised, and
# staples the ticket onto the app. Without all four steps macOS refuses to open
# a downloaded app without the user going into System Settings, which on recent
# versions is several clicks buried in Privacy and Security.
#
# It needs two things set up once. Neither can be scripted, because both are
# bound to an Apple ID.
#
#   1. A Developer ID Application certificate.
#      Xcode, Settings, Accounts, pick the team, Manage Certificates, plus,
#      Developer ID Application. It needs a paid membership and the Account
#      Holder role. The "Apple Development" certificate is NOT this: that one
#      only signs for your own machine.
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
cd "$(dirname "$0")"

REF=${1:-HEAD}
PROFILE=${BLOOM_NOTARY_PROFILE:-bloom}
IDENTITY=${BLOOM_CODESIGN_IDENTITY:-}

if [ -z "$IDENTITY" ] || [[ "$IDENTITY" == Apple\ Development* ]]; then
  echo "release.sh needs a Developer ID Application identity." >&2
  echo "Available now:" >&2
  security find-identity -v -p codesigning | sed 's/^/  /' >&2
  echo >&2
  echo 'export BLOOM_CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"' >&2
  exit 1
fi

RESOLVED="$(git rev-parse --short "$REF")"
WORK=/tmp/bloom-release-src
OUT="$PWD/dist"

echo "==> $RESOLVED  $(git log -1 --format=%s "$REF")"

# Same reasoning as master.sh: a detached worktree at a commit, and a scratch
# path of its own, so nothing uncommitted and nothing from a concurrent build
# can end up in something being sent to another person.
git worktree remove --force "$WORK" 2>/dev/null || true
rm -rf "$WORK"
git worktree add --detach "$WORK" "$RESOLVED" >/dev/null
( cd "$WORK" && BLOOM_CODESIGN_IDENTITY="$IDENTITY" ./build.sh -r >/dev/null )

APP="$WORK/.build/release/Bloom.app"
[ -d "$APP" ] || APP="$(cd "$WORK" && swift build -c release --show-bin-path)/Bloom.app"

# build.sh signs, but without the hardened runtime, which notarisation requires.
# Signed again here rather than teaching build.sh about it, because a debug
# build wants to stay easy to attach a debugger to.
echo "==> signing with the hardened runtime"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

mkdir -p "$OUT"
ZIP="$OUT/Bloom-$RESOLVED.zip"
rm -f "$ZIP"
# ditto rather than zip, because zip drops the symlinks and the extended
# attributes a bundle's signature is partly held in.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarising, which takes a few minutes"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# The ticket is stapled to the app, not to the zip, so the app is re-zipped
# afterwards. Without this the receiver has to be online the first time they
# open it.
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP" || true
git worktree remove --force "$WORK" 2>/dev/null || true

echo "==> $ZIP"
