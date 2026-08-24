#!/bin/zsh
# Takes a built Bloom.app and leaves a zip anyone can open: version stamped,
# signed with a Developer ID and the hardened runtime, notarised by Apple, and
# with the ticket stapled on. With --dmg it also leaves the beach disk image,
# built from that same stapled bundle and notarised and stapled in its own right.
#
#   Tools/release/package-app.sh --app <path> --zip <path> --version 1.4.0 --build 431
#   Tools/release/package-app.sh --app <path> --zip <path> --dmg <path> --version 1.4.0 --build 431
#   Tools/release/package-app.sh --preflight
#
# The two artefacts are for two different readers. The zip is what Sparkle
# downloads, because that is the enclosure every installed copy of Bloom already
# knows how to unpack. The disk image is what a person downloads from the site,
# because that is the one with the artwork and the drag-to-Applications window.
# Both hold the same signed and stapled bundle.
#
# --preflight checks the identity and the notarisation credential and stops.
# Tools/release.sh runs it before the build, so a missing credential costs a second
# rather than the five minutes it takes to compile the app first.
#
# This is the one copy of that sequence. Tools/release.sh calls it and so does the
# release workflow, because the two paths drifting apart is exactly how you end
# up with a CI build that is signed differently from the one that was tested.
#
# What has to be true before it runs, and is checked rather than assumed:
#
#   BLOOM_CODESIGN_IDENTITY   a Developer ID Application identity, in a
#                             keychain that is unlocked and on the search list.
#                             An Apple Development identity is refused: that
#                             one only signs for the machine it was made on,
#                             and Apple will not notarise anything signed with
#                             it.
#
#   a notarisation credential, one of three, tried in this order:
#
#     BLOOM_NOTARY_KEY        path to an App Store Connect .p8, with
#     BLOOM_NOTARY_KEY_ID     the key id and
#     BLOOM_NOTARY_ISSUER     the issuer id. This is the CI shape: nothing is
#                             stored on the machine and the key can be revoked
#                             on its own.
#
#     BLOOM_NOTARY_APPLE_ID   an Apple ID, with
#     BLOOM_NOTARY_TEAM_ID    the team and
#     BLOOM_NOTARY_PASSWORD   an app specific password.
#
#     BLOOM_NOTARY_PROFILE    the name of a credential already stored by
#                             `xcrun notarytool store-credentials`. Defaults to
#                             `bloom`. This is the local shape.
#
# Optional:
#
#   BLOOM_ENTITLEMENTS        path to an entitlements plist. Defaults to
#                             Resources/Bloom.entitlements when that file
#                             exists, so entitlements can be added later
#                             without editing this script.

set -euo pipefail

APP=
ZIP=
DMG=
VERSION=
BUILD=
PREFLIGHT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --zip) ZIP=$2; shift 2 ;;
    --dmg) DMG=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --preflight) PREFLIGHT=1; shift ;;
    *) echo "package-app.sh: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$PREFLIGHT" -eq 0 ]; then
  for required in APP ZIP VERSION BUILD; do
    if eval "[ -z \"\$$required\" ]"; then
      echo "package-app.sh: --${required:l} is required" >&2
      exit 1
    fi
  done

  [ -d "$APP" ] || { echo "package-app.sh: no app at $APP" >&2; exit 1; }
fi

IDENTITY=${BLOOM_CODESIGN_IDENTITY:-}

if [ -z "$IDENTITY" ] || [[ "$IDENTITY" == Apple\ Development* ]]; then
  echo "package-app.sh needs a Developer ID Application identity." >&2
  echo "Available now:" >&2
  security find-identity -v -p codesigning | sed 's/^/  /' >&2
  echo >&2
  echo 'export BLOOM_CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"' >&2
  exit 1
fi

# The credential is picked here rather than at the call site, so the local run
# and the CI run go through the same code with the same failure messages. None
# of these values are ever printed.
NOTARY_ARGS=()
if [ -n "${BLOOM_NOTARY_KEY:-}" ]; then
  [ -f "$BLOOM_NOTARY_KEY" ] || { echo "package-app.sh: no key file at BLOOM_NOTARY_KEY" >&2; exit 1; }
  [ -n "${BLOOM_NOTARY_KEY_ID:-}" ] || { echo "package-app.sh: BLOOM_NOTARY_KEY needs BLOOM_NOTARY_KEY_ID" >&2; exit 1; }
  [ -n "${BLOOM_NOTARY_ISSUER:-}" ] || { echo "package-app.sh: BLOOM_NOTARY_KEY needs BLOOM_NOTARY_ISSUER" >&2; exit 1; }
  NOTARY_ARGS=(--key "$BLOOM_NOTARY_KEY" --key-id "$BLOOM_NOTARY_KEY_ID" --issuer "$BLOOM_NOTARY_ISSUER")
  echo "==> notarising with an App Store Connect API key"
elif [ -n "${BLOOM_NOTARY_PASSWORD:-}" ]; then
  [ -n "${BLOOM_NOTARY_APPLE_ID:-}" ] || { echo "package-app.sh: BLOOM_NOTARY_PASSWORD needs BLOOM_NOTARY_APPLE_ID" >&2; exit 1; }
  [ -n "${BLOOM_NOTARY_TEAM_ID:-}" ] || { echo "package-app.sh: BLOOM_NOTARY_PASSWORD needs BLOOM_NOTARY_TEAM_ID" >&2; exit 1; }
  NOTARY_ARGS=(--apple-id "$BLOOM_NOTARY_APPLE_ID" --team-id "$BLOOM_NOTARY_TEAM_ID" --password "$BLOOM_NOTARY_PASSWORD")
  echo "==> notarising with an app specific password"
else
  NOTARY_ARGS=(--keychain-profile "${BLOOM_NOTARY_PROFILE:-bloom}")
  echo "==> notarising with the stored profile ${BLOOM_NOTARY_PROFILE:-bloom}"
fi

if [ "$PREFLIGHT" -eq 1 ]; then
  echo "==> signing as $IDENTITY"
  exit 0
fi

# Before signing, because Info.plist is one of the files the signature seals.
# Stamping it afterwards would leave a bundle whose signature does not match
# its own contents, which macOS rejects outright.
echo "==> stamping $VERSION ($BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Stamped here rather than anywhere else because this is the moment the version
# stops being the placeholder in Resources/Info.plist and starts meaning
# something. The updater refuses to run on a bundle that was never stamped, since
# comparing an appcast against a working copy's fixed version is meaningless in
# both directions. See SoftwareUpdate.availability. Without this line the app
# ships, installs and never offers an update.
/usr/libexec/PlistBuddy -c "Set :BloomBuildChannel release" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :BloomBuildChannel string release" "$APP/Contents/Info.plist"

ENTITLEMENTS=${BLOOM_ENTITLEMENTS:-}
if [ -z "$ENTITLEMENTS" ] && [ -f "Resources/Bloom.entitlements" ]; then
  ENTITLEMENTS="Resources/Bloom.entitlements"
fi

SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
if [ -n "$ENTITLEMENTS" ]; then
  echo "==> entitlements: $ENTITLEMENTS"
  SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

# Inside out, deepest first, rather than --deep. Tools/build.sh signs with --deep and
# without the hardened runtime, which is right for a debug build; here every
# nested piece has to be re-signed with the runtime on, or the app launches and
# then dies the moment it loads a library that was signed the old way. Doing it
# by hand rather than with --deep is also what Sparkle needs, since it ships a
# framework with an XPC service and a helper app inside it.
echo "==> signing with the hardened runtime"

# What has to be signed before the app itself, and in what order, is worked out
# by Tools/release/nested-code.sh, which has tests. Tools/build.sh signs with --deep
# and without the hardened runtime, which is right for a debug build; here
# every nested piece has to be signed again with the runtime on, or the app
# launches and then dies the moment it loads something that was signed the old
# way.
NESTED=()
while IFS= read -r nested; do
  NESTED+=("$nested")
done < <("$(dirname "$0")/nested-code.sh" "$APP")

for nested in "${NESTED[@]}"; do
  echo "    ${nested#"$APP/"}"
  codesign "${SIGN_ARGS[@]}" "$nested"
done

codesign "${SIGN_ARGS[@]}" "$APP"

# --deep here on purpose even though the signing above avoided it: on verify it
# means "check everything nested too", which is how an unsigned piece that the
# loop above did not know to look for gets caught before Apple sees it.
codesign --verify --strict --deep --verbose=2 "$APP"

mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
# ditto rather than zip, because zip drops the symlinks and the extended
# attributes a bundle's signature is partly held in.
ditto -c -k --keepParent "$APP" "$ZIP"

# One copy of submit-and-check, because the app and the disk image each need a
# ticket of their own and a second hand written copy is a second place for the
# status test below to be left out. That test is the whole point: notarytool
# exits 0 for a submission it accepted, waited on, and was told was Invalid, so
# the status in the JSON is what decides and the exit code is not.
notarise() {
  local subject=$1
  echo "==> notarising ${subject:t}, which takes a few minutes"

  local json
  json="$(mktemp -t bloom-notary)"

  if ! xcrun notarytool submit "$subject" "${NOTARY_ARGS[@]}" --wait --output-format json > "$json"; then
    echo "==> notarytool failed" >&2
    cat "$json" >&2
    rm -f "$json"
    exit 1
  fi

  # `verdict` rather than the obvious `status`: in zsh `status` is a read-only
  # synonym for `?`, and `local status` inside a function is an error that stops
  # the release right here, after Apple has already been paid the wait.
  local verdict submission
  verdict="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$json")"
  submission="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$json")"
  rm -f "$json"

  if [ "$verdict" != "Accepted" ]; then
    echo "==> notarisation of ${subject:t} was $verdict, not Accepted" >&2
    # The submission log is the only thing that says which file Apple objected to.
    # Without it the failure is a single word and the next hour is guesswork.
    [ -n "$submission" ] && xcrun notarytool log "$submission" "${NOTARY_ARGS[@]}" >&2 || true
    exit 1
  fi
}

notarise "$ZIP"

# The ticket is stapled to the app, not to the zip, so the app is re-zipped
# afterwards. Without this the receiver has to be online the first time they
# open it.
echo "==> stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Both of these are hard failures. A zip that reaches the bucket unnotarised is
# worse than a release that did not happen, because the second one is obvious.
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> $ZIP"

if [ -n "$DMG" ]; then
  # Built here, from the bundle a few lines above, rather than from a second
  # build of the same commit: what a person drags into Applications is then
  # byte for byte the app Apple notarised, ticket included.
  echo "==> building the disk image"
  mkdir -p "$(dirname "$DMG")"
  "$(dirname "$0")/../dmg/build.sh" --app "$APP" --out "$DMG"

  # A disk image carries a notarisation ticket of its own, and stapling the app
  # inside it does not put one there. Gatekeeper assesses the file that was
  # downloaded, so an unstapled image asks Apple about itself the first time it
  # is opened: a wait on a slow connection, and a refusal on no connection at
  # all. That is the whole reason for the second round trip below.
  echo "==> signing the disk image"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"

  notarise "$DMG"

  echo "==> stapling the disk image"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  # --type open, and against the image rather than the app. A disk image is a
  # document being opened, not something being executed, and assessing the app
  # instead would pass happily on an image that had never been notarised at
  # all, which is exactly the mistake this line exists to catch.
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

  echo "==> $DMG"
fi
