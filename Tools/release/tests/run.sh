#!/bin/zsh
# Everything in the release path that can be checked without a certificate, a
# notarisation credential or a bucket.
#
#   Tools/release/tests/run.sh
#
# What it does not cover, and cannot: signing, notarising, stapling, and the
# upload. Those need secrets that exist only on the release runner.

set -euo pipefail
cd "$(dirname "$0")/../../.."

TOOLS=Tools/release
FIXTURES=$TOOLS/tests/fixtures
WORK="$(mktemp -d -t bloom-release-tests)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

ok() { PASSED=$((PASSED + 1)); echo "  ok  $1"; }
no() { FAILED=$((FAILED + 1)); echo "  NO  $1" >&2; }

expect_equal() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1: expected '$3', got '$2'"; fi
}

expect_fails() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then no "$label: it succeeded and should not have"; else ok "$label"; fi
}

xpath_text() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {
    "sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
    "bloom": "https://runbloom.app/xml-namespaces/bloom",
}
node = ET.parse(sys.argv[1]).getroot().find(sys.argv[2], ns)
if node is None:
    print("")
elif node.text is None:
    print("")
else:
    print(node.text.strip())
PY
}

xpath_attr() {
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {
    "sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
    "bloom": "https://runbloom.app/xml-namespaces/bloom",
}
node = ET.parse(sys.argv[1]).getroot().find(sys.argv[2], ns)
name = sys.argv[3]
for prefix, uri in ns.items():
    name = name.replace(f"{prefix}:", "{" + uri + "}")
print("" if node is None else node.get(name, ""))
PY
}

count_items() {
  /usr/bin/python3 -c 'import sys,xml.etree.ElementTree as ET; print(len(ET.parse(sys.argv[1]).getroot().findall("channel/item")))' "$1"
}


echo "version.sh"

eval "$("$TOOLS/version.sh" v1.4.0)"
expect_equal "a plain tag is a stable release" "$version $channel $prerelease" "1.4.0 stable 0"
[ "$build" -gt 0 ] && ok "the build number is the commit count" || no "the build number is $build"

eval "$("$TOOLS/version.sh" v1.4.0-beta.1)"
expect_equal "a semver prerelease tag goes to the beta channel" "$version $channel $prerelease" "1.4.0-beta.1 beta 1"

eval "$("$TOOLS/version.sh" 2.0)"
expect_equal "the leading v is optional" "$version" "2.0"

eval "$("$TOOLS/version.sh" v1.4.0.9)"
expect_equal "four components are allowed" "$version" "1.4.0.9"

expect_fails "a tag that is not a version is refused" "$TOOLS/version.sh" banana
expect_fails "a tag with a shell metacharacter is refused" "$TOOLS/version.sh" 'v1.0; touch /tmp/bloom-owned'
expect_fails "an empty tag is refused" "$TOOLS/version.sh" ""
expect_fails "five components are refused" "$TOOLS/version.sh" v1.2.3.4.5

# Two refs, two counts, and the older one has to be smaller. This is the whole
# reason the build number is a commit count rather than a timestamp.
FIRST="$(git rev-list --max-parents=0 HEAD | head -1)"
eval "$("$TOOLS/version.sh" v1.0.0 "$FIRST")"
FIRST_BUILD=$build
eval "$("$TOOLS/version.sh" v1.0.0 HEAD)"
[ "$build" -gt "$FIRST_BUILD" ] && ok "the build number grows along history" || no "build $build is not above $FIRST_BUILD"


echo "appcast.py"

FEED="$WORK/appcast.xml"

# From nothing at all, which is what the first release will find.
"$TOOLS/appcast.py" --existing "$WORK/does-not-exist.xml" --output "$FEED" \
  --version 1.0.0 --build 100 --url https://example.invalid/Bloom-1.0.0.zip \
  --length 4096 --signature SIGONE --min-system 15.0 \
  --feed-link https://example.invalid/appcast.xml 2>/dev/null

expect_equal "a missing feed starts a new one" "$(count_items "$FEED")" "1"
expect_equal "the item carries the marketing version" "$(xpath_text "$FEED" 'channel/item/sparkle:shortVersionString')" "1.0.0"
expect_equal "the item carries the build number" "$(xpath_text "$FEED" 'channel/item/sparkle:version')" "100"
expect_equal "the enclosure carries the signature" "$(xpath_attr "$FEED" 'channel/item/enclosure' 'sparkle:edSignature')" "SIGONE"
expect_equal "the enclosure carries the length" "$(xpath_attr "$FEED" 'channel/item/enclosure' 'length')" "4096"
expect_equal "a stable release has no channel element" "$(xpath_text "$FEED" 'channel/item/sparkle:channel')" ""
expect_equal "the feed knows its own address" "$(xpath_text "$FEED" 'channel/link')" "https://example.invalid/appcast.xml"

# Running the same release again, which is what a re-run after a failed upload
# does. It has to replace rather than append.
"$TOOLS/appcast.py" --existing "$FEED" --output "$FEED" \
  --version 1.0.0 --build 100 --url https://example.invalid/Bloom-1.0.0.zip \
  --length 4096 --signature SIGONE --min-system 15.0 2>/dev/null
expect_equal "re-running the same release does not duplicate it" "$(count_items "$FEED")" "1"

# A newer one, on top.
"$TOOLS/appcast.py" --existing "$FEED" --output "$FEED" \
  --version 1.1.0 --build 110 --url https://example.invalid/Bloom-1.1.0.zip \
  --length 5000 --signature SIGTWO --min-system 15.0 2>/dev/null
expect_equal "a newer release is added" "$(count_items "$FEED")" "2"
expect_equal "the newest release is first" "$(xpath_text "$FEED" 'channel/item/sparkle:version')" "110"

# An older one arriving late, which happens when a patch on an old branch is
# released after a newer minor.
"$TOOLS/appcast.py" --existing "$FEED" --output "$FEED" \
  --version 1.0.1 --build 105 --url https://example.invalid/Bloom-1.0.1.zip \
  --length 4500 --signature SIGTHREE --min-system 15.0 2>/dev/null
expect_equal "an older release lands in order, not at the top" "$(xpath_text "$FEED" 'channel/item/sparkle:version')" "110"
expect_equal "and it is still in the feed" "$(count_items "$FEED")" "3"

# A prerelease.
"$TOOLS/appcast.py" --existing "$FEED" --output "$FEED" \
  --version 1.2.0-beta.1 --build 120 --url https://example.invalid/Bloom-1.2.0-beta.1.zip \
  --length 6000 --signature SIGFOUR --min-system 15.0 --channel beta 2>/dev/null
expect_equal "a prerelease is put on the beta channel" "$(xpath_text "$FEED" 'channel/item/sparkle:channel')" "beta"

# Release notes.
echo '<h2>What changed</h2><p>Rather a lot.</p>' > "$WORK/notes.html"
"$TOOLS/appcast.py" --existing "$FEED" --output "$FEED" \
  --version 1.3.0 --build 130 --url https://example.invalid/Bloom-1.3.0.zip \
  --length 7000 --signature SIGFIVE --min-system 15.0 --notes-file "$WORK/notes.html" 2>/dev/null
expect_equal "the release notes end up in the description" \
  "$(xpath_text "$FEED" 'channel/item/description')" '<h2>What changed</h2><p>Rather a lot.</p>'

# Truncation, so the feed cannot grow without limit.
"$TOOLS/appcast.py" --existing "$FEED" --output "$FEED" \
  --version 1.4.0 --build 140 --url https://example.invalid/Bloom-1.4.0.zip \
  --length 8000 --signature SIGSIX --min-system 15.0 --max-items 2 2>/dev/null
expect_equal "the feed is trimmed to the newest few" "$(count_items "$FEED")" "2"

# An existing feed written by somebody else, with CDATA and elements this
# generator does not produce. Nothing of theirs may be lost.
cp "$FIXTURES/existing-appcast.xml" "$WORK/existing.xml"
"$TOOLS/appcast.py" --existing "$WORK/existing.xml" --output "$WORK/merged.xml" \
  --version 1.3.0 --build 300 --url https://example.invalid/Bloom-1.3.0.zip \
  --length 9000 --signature SIGSEVEN --min-system 15.0 2>/dev/null
expect_equal "existing items are kept" "$(count_items "$WORK/merged.xml")" "3"
expect_equal "an element the generator never writes survives" \
  "$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as ET; print(len(ET.parse(sys.argv[1]).getroot().findall(".//{http://www.andymatuschak.org/xml-namespaces/sparkle}criticalUpdate")))' "$WORK/merged.xml")" "1"
expect_equal "a CDATA description survives as text" \
  "$(/usr/bin/python3 -c '
import sys, xml.etree.ElementTree as ET
for item in ET.parse(sys.argv[1]).getroot().findall("channel/item"):
    short = item.find("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString")
    if short is not None and short.text == "1.1.0":
        print((item.find("description").text or "").strip())
' "$WORK/merged.xml")" '<p>The first one anybody outside kept.</p>'

expect_fails "a build number that is not a number is refused" \
  "$TOOLS/appcast.py" --existing "$FEED" --output "$WORK/bad.xml" --version 1.0.0 \
  --build not-a-number --url https://example.invalid/x.zip --length 1 --signature S
expect_fails "a zero length enclosure is refused" \
  "$TOOLS/appcast.py" --existing "$FEED" --output "$WORK/bad.xml" --version 1.0.0 \
  --build 1 --url https://example.invalid/x.zip --length 0 --signature S

# The disk image. It rides beside the enclosure and never replaces it: the
# enclosure is what Sparkle downloads and every installed copy of Bloom already
# knows how to unpack one, so the checks below are as much about what did not
# change as about what did.
IMAGE_FEED="$WORK/appcast-dmg.xml"
"$TOOLS/appcast.py" --existing "$WORK/does-not-exist.xml" --output "$IMAGE_FEED" \
  --version 2.0.0 --build 200 --url https://example.invalid/Bloom-2.0.0.zip \
  --length 4096 --signature SIGDMG --min-system 15.0 \
  --dmg-url https://example.invalid/Bloom-2.0.0.dmg --dmg-length 123456 2>/dev/null

expect_equal "the disk image is named on the item" \
  "$(xpath_attr "$IMAGE_FEED" 'channel/item/bloom:diskImage' 'url')" \
  "https://example.invalid/Bloom-2.0.0.dmg"
expect_equal "the disk image carries its length" \
  "$(xpath_attr "$IMAGE_FEED" 'channel/item/bloom:diskImage' 'length')" "123456"
expect_equal "the disk image says what it is" \
  "$(xpath_attr "$IMAGE_FEED" 'channel/item/bloom:diskImage' 'type')" "application/x-apple-diskimage"
expect_equal "the enclosure is still the zip" \
  "$(xpath_attr "$IMAGE_FEED" 'channel/item/enclosure' 'url')" \
  "https://example.invalid/Bloom-2.0.0.zip"
expect_equal "the enclosure still carries the signature" \
  "$(xpath_attr "$IMAGE_FEED" 'channel/item/enclosure' 'sparkle:edSignature')" "SIGDMG"
expect_equal "the enclosure length is the zip's, not the image's" \
  "$(xpath_attr "$IMAGE_FEED" 'channel/item/enclosure' 'length')" "4096"

# Every release up to 0.6.0. Whatever reads this feed has to cope with the
# element not being there at all, so it has to be genuinely absent rather than
# present and empty.
expect_equal "a release without an image has no diskImage element" \
  "$(xpath_attr "$FEED" 'channel/item/bloom:diskImage' 'url')" ""

expect_fails "an image URL with no length is refused" \
  "$TOOLS/appcast.py" --existing "$FEED" --output "$WORK/bad.xml" --version 1.0.0 \
  --build 1 --url https://example.invalid/x.zip --length 1 --signature S \
  --min-system 15.0 --dmg-url https://example.invalid/x.dmg --dmg-length 0


echo "nested-code.sh"

# A bundle shaped like one Sparkle has been embedded into, built out of real
# Mach-O files so the detection is exercised rather than mocked. This is the
# part of signing that is easiest to get quietly wrong and hardest to notice:
# a missed binary passes codesign --verify and is rejected by Apple an hour
# later.
FAKE="$WORK/Bloom.app"
FRAMEWORK="$FAKE/Contents/Frameworks/Sparkle.framework"
mkdir -p "$FAKE/Contents/MacOS" "$FAKE/Contents/Resources/Bloom_Bloom.bundle"
mkdir -p "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS"
mkdir -p "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS"
cp /bin/echo "$FAKE/Contents/MacOS/Bloom"
cp /bin/echo "$FRAMEWORK/Versions/B/Sparkle"
cp /bin/echo "$FRAMEWORK/Versions/B/Autoupdate"
cp /bin/echo "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
cp /bin/echo "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
cp /usr/lib/libSystem.B.dylib "$FAKE/Contents/MacOS/libSwiftTerm.dylib" 2>/dev/null ||   cp /bin/echo "$FAKE/Contents/MacOS/libSwiftTerm.dylib"
echo 'a resource, not code' > "$FAKE/Contents/Resources/Bloom_Bloom.bundle/thing.txt"
printf '#!/bin/sh\necho hello\n' > "$FAKE/Contents/Resources/helper.sh"
chmod +x "$FAKE/Contents/Resources/helper.sh"
( cd "$FRAMEWORK/Versions" && ln -s B Current )
( cd "$FRAMEWORK" && ln -s Versions/Current/Updater.app Updater.app )
( cd "$FRAMEWORK" && ln -s Versions/Current/Sparkle Sparkle )

LISTING="$WORK/nested.txt"
"$TOOLS/nested-code.sh" "$FAKE" | sed "s|$FAKE/||" > "$LISTING"

has() { grep -qxF "$1" "$LISTING"; }
lineno() { grep -nxF "$1" "$LISTING" | cut -d: -f1; }

has "Contents/Frameworks/Sparkle.framework" && ok "the framework is listed" || no "the framework is missing"
has "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"   && ok "Sparkle's loose Autoupdate binary is listed"   || no "Sparkle's loose Autoupdate binary was missed"
has "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"   && ok "the XPC service is listed" || no "the XPC service is missing"
has "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"   && ok "the helper app is listed" || no "the helper app is missing"
has "Contents/MacOS/libSwiftTerm.dylib" && ok "a dylib is listed" || no "the dylib is missing"

if grep -q "Versions/Current" "$LISTING"; then
  no "a symlinked alias was listed, so something would be signed twice"
else
  ok "symlinked aliases are left out"
fi

if grep -qxF "Contents/Frameworks/Sparkle.framework/Updater.app" "$LISTING"; then
  no "the framework's top level Updater.app alias was listed"
else
  ok "the framework's top level alias is left out"
fi

if grep -q "helper.sh" "$LISTING"; then
  no "a shell script was listed as code to sign"
else
  ok "an executable that is not Mach-O is left out"
fi

# The whole point of the ordering.
XPC_AT="$(lineno "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc")"
UPDATER_AT="$(lineno "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app")"
AUTOUPDATE_AT="$(lineno "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate")"
FRAMEWORK_AT="$(lineno "Contents/Frameworks/Sparkle.framework")"
if [ "$XPC_AT" -lt "$FRAMEWORK_AT" ] && [ "$UPDATER_AT" -lt "$FRAMEWORK_AT" ] && [ "$AUTOUPDATE_AT" -lt "$FRAMEWORK_AT" ]; then
  ok "everything inside the framework comes before the framework"
else
  no "the framework would be signed before its own contents"
fi

INSTALLER_BIN_AT="$(lineno "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer")"
if [ "$INSTALLER_BIN_AT" -lt "$XPC_AT" ]; then
  ok "an executable comes before the bundle around it"
else
  no "a bundle would be signed before its own executable"
fi

expect_fails "a path that is not a bundle is refused" "$TOOLS/nested-code.sh" "$WORK/nope.app"


echo "sparkle-public-key.sh"

# A throwaway seed, never near anybody's keychain. Sparkle signs, openssl
# verifies with the key this script derived. If those two ever stop agreeing,
# the check in the workflow would be comparing the wrong thing.
SEED="$(/usr/bin/python3 -c 'import os,base64; print(base64.b64encode(os.urandom(32)).decode())')"
PUBLIC="$(printf '%s' "$SEED" | "$TOOLS/sparkle-public-key.sh")"
[ -n "$PUBLIC" ] && ok "a public key is derived from a private one" || no "nothing was derived"

expect_fails "a key of the wrong length is refused" \
  sh -c "printf '%s' 'aGVsbG8=' | $TOOLS/sparkle-public-key.sh"
expect_fails "an empty key is refused" \
  sh -c "printf '' | $TOOLS/sparkle-public-key.sh"

if BIN="$("$TOOLS/sparkle-tools.sh" 2>/dev/null)"; then
  echo "hello bloom" > "$WORK/payload.zip"
  printf '%s' "$SEED" > "$WORK/seed"
  SIGNATURE="$("$BIN/sign_update" --ed-key-file "$WORK/seed" -p "$WORK/payload.zip")"
  [ -n "$SIGNATURE" ] && ok "sign_update signs with a Sparkle key file" || no "sign_update produced nothing"

  printf '%s' "$SIGNATURE" | base64 --decode > "$WORK/signature.bin"
  /usr/bin/python3 - "$PUBLIC" "$WORK/public.der" <<'PY'
import base64, sys
with open(sys.argv[2], "wb") as handle:
    handle.write(bytes.fromhex("302a300506032b6570032100") + base64.b64decode(sys.argv[1]))
PY
  if openssl pkeyutl -verify -pubin -inkey "$WORK/public.der" -keyform DER \
      -rawin -in "$WORK/payload.zip" -sigfile "$WORK/signature.bin" >/dev/null 2>&1; then
    ok "the derived public key verifies what Sparkle signed"
  else
    no "the derived public key does not match the key Sparkle signed with"
  fi
  rm -f "$WORK/seed"
else
  echo "  -- skipped the signing round trip: Sparkle's tools could not be fetched"
fi


echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
