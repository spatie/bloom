#!/bin/zsh
# Builds Bloom and assembles a launchable .app bundle.
#
#   ./Tools/build.sh            debug build
#   ./Tools/build.sh -r         release build
#   ./Tools/build.sh -r --run   release build, then launch it
#
#   make app / make run         the same two through the Makefile

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
RUN=0
for arg in "$@"; do
  case "$arg" in
    -r|--release) CONFIG=release ;;
    --run) RUN=1 ;;
  esac
done

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Bloom

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$BIN_DIR/Bloom.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Bloom" "$APP/Contents/MacOS/Bloom"
cp Resources/Info.plist "$APP/Contents/Info.plist"

plist_set() {
  local key="$1" type="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$APP/Contents/Info.plist" >/dev/null
}

# What version this build claims to be, and whether it is allowed to update itself.
#
# The updater compares the appcast against CFBundleVersion, so that number has to mean something.
# Resources/Info.plist carries a fixed one, which is fine as a placeholder and useless as a claim:
# every build made from the source tree would carry it, so a released build would look newer than
# a working copy that is months ahead of it, and a working copy that had been hand-stamped would
# look newer than everything and never update again.
#
# So a build only claims a version when it is given one, and only a build that claims a version is
# allowed to update itself. `BloomBuildChannel` is what says which of the two this is;
# `SoftwareUpdate.availability` reads it and refuses to start the updater on a local build. That is
# also what keeps the copy Tools/master.sh installs out of it, and that script's own
# BloomMasterCommit is checked as a second, independent guard on the same case.
#
#   BLOOM_VERSION=0.2.0 BLOOM_BUILD=7 ./Tools/build.sh -r
#
# BLOOM_BUILD has to increase with every release and never repeat. The release pipeline should
# derive both from the tag it is building, and the appcast's sparkle:version MUST equal the
# BLOOM_BUILD of the zip it points at, or an installed app updates to a build that still reports
# the old number and offers itself the same update forever.
if [[ -n "${BLOOM_VERSION:-}" && -n "${BLOOM_BUILD:-}" ]]; then
  plist_set CFBundleShortVersionString string "$BLOOM_VERSION"
  plist_set CFBundleVersion string "$BLOOM_BUILD"
  plist_set BloomBuildChannel string release
  echo "==> version $BLOOM_VERSION ($BLOOM_BUILD)"
else
  plist_set BloomBuildChannel string local
fi

# The appcast and the key its signatures are checked against. Resources/Info.plist ships
# placeholders for both, and a build that leaves either of them in place never starts the updater,
# so an unconfigured build cannot reach for a host nobody owns.
#
#   BLOOM_UPDATE_FEED_URL     the appcast, e.g. https://<bucket-host>/appcast.xml
#   BLOOM_UPDATE_PUBLIC_KEY   the base64 EdDSA public key from Sparkle's generate_keys
#
# The private half of that pair never appears in this repository. It lives in the release runner's
# secret store, and in the keychain of the Mac that generated it.
if [[ -n "${BLOOM_UPDATE_FEED_URL:-}" ]]; then
  plist_set SUFeedURL string "$BLOOM_UPDATE_FEED_URL"
fi
if [[ -n "${BLOOM_UPDATE_PUBLIC_KEY:-}" ]]; then
  plist_set SUPublicEDKey string "$BLOOM_UPDATE_PUBLIC_KEY"
fi

# Sparkle, embedded by hand.
#
# It ships as a binary XCFramework, and a Swift package build links against it but copies nothing:
# an Xcode project would have an "Embed Frameworks" phase and there is no Xcode project here. So
# the framework is copied into Contents/Frameworks, which is where a signed and notarised bundle
# has to keep one, and the executable is given the rpath that finds it there. Without this the app
# builds perfectly and then fails to launch, because dyld cannot resolve
# @rpath/Sparkle.framework/Versions/B/Sparkle.
#
# This runs on every build, not only on ones that can update themselves: the binary is linked
# against the framework either way, so a build without it would not start at all.
#
# ditto rather than cp, because the framework is a versioned bundle held together by symlinks and
# carries a code signature of its own. install_name_tool invalidates the signature the build
# system just applied, which is why both happen before the codesign pass at the foot of this file.
embed_sparkle() {
  local scratch framework
  # BIN_DIR is <scratch>/<triple>/<config>, and the binary artifacts sit beside the triple.
  scratch="$(dirname "$(dirname "$BIN_DIR")")"
  framework="$(/usr/bin/find "$scratch/artifacts" -maxdepth 6 -type d \
    -name 'Sparkle.framework' -path '*Sparkle.xcframework/macos*' 2>/dev/null | head -1)"

  if [[ -z "$framework" ]]; then
    echo "==> Sparkle.framework not found under $scratch/artifacts" >&2
    return 1
  fi

  # The App Intents typecheck pass below compiles the app's sources a second time and needs the
  # same framework search path the real build had, or `import Sparkle` fails there and takes the
  # whole build with it.
  SPARKLE_SEARCH_PATH="$(dirname "$framework")"

  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  /usr/bin/ditto "$framework" "$APP/Contents/Frameworks/Sparkle.framework"
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Bloom" 2>/dev/null

  # Nothing above proves dyld will find it, so the answer is read back out of the binary rather
  # than assumed. An app that launches on this machine only because the framework happens to still
  # be in .build is exactly the failure this step exists to prevent.
  if ! otool -l "$APP/Contents/MacOS/Bloom" | grep -q '@executable_path/../Frameworks'; then
    echo "==> Sparkle: the executable has no rpath into Contents/Frameworks" >&2
    return 1
  fi
}

embed_sparkle

# macOS 26 draws an app icon from a layered Icon Composer document rather than from a flat bitmap:
# the glass, the shadow and the specular pass belong to the system and are applied live to the
# layers. Resources/Bloom.icon is that document. actool compiles it into an Assets.car, which the
# system finds through CFBundleIconName in Info.plist. It is now the only icon in the bundle: the
# floor is macOS 26 and there is no system left that would draw a flat one. Tools/icon/make.py's
# docstring carries the measurement that settled that.
#
# Command line tools on their own carry no actool, so a machine with only those produces a bundle
# with no icon at all. That is loud enough to notice and cheaper than failing the build.
compile_layered_icon() {
  local iconName=Bloom deployment
  [[ -d "Resources/$iconName.icon" ]] || return 0

  if ! xcrun --find actool >/dev/null 2>&1; then
    echo "==> skipping layered icon: actool not found"
    return 0
  fi

  deployment="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"

  # Absolute, because actool hands a relative input path to ibtoold, which resolves it against a
  # working directory of its own and crashes rather than reporting a missing file.
  xcrun actool "$PWD/Resources/$iconName.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon "$iconName" \
    --output-partial-info-plist "$BIN_DIR/$iconName.icon.plist" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target "$deployment" \
    --errors --warnings >/dev/null

  # actool writes a flattened $iconName.icns beside the catalogue as well, as a fallback for a
  # system that cannot read the catalogue. There is no such system at this floor, and the flattened
  # file is the layers without the passes that make them read, so it is dropped rather than shipped
  # as a worse copy of the icon nothing will ask for.
  rm -f "$APP/Contents/Resources/$iconName.icns"

  # Nothing above proves the catalogue arrived: actool reports a failure in the plist it prints and
  # is not reliably non-zero about it. The bundle either has the file or the build is wrong.
  if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "==> layered icon: actool produced no Assets.car" >&2
    return 1
  fi
}

compile_layered_icon

# What the app looks up in its own bundle by name: the Spatie logos the About pane draws, and the
# menu bar mark. PDFs rather than bitmaps, because AppKit redraws a PDF as vector art at whatever
# scale the display asks for, so one file is right on a Retina display and on a 1x monitor. The
# .svg beside each logo is the source it was generated from and is not needed at runtime; the menu
# bar mark's source is Tools/icon/menubar.py.
for art in Resources/Spatie*.pdf(N) Resources/BloomMenuBar.pdf(N); do
  cp "$art" "$APP/Contents/Resources/"
done

# SwiftTerm and friends ship as dylibs in a debug build; carry them along.
for lib in "$BIN_DIR"/*.dylib(N); do
  cp "$lib" "$APP/Contents/MacOS/"
done

if [[ -d "$BIN_DIR/Bloom_Bloom.bundle" ]]; then
  cp -R "$BIN_DIR/Bloom_Bloom.bundle" "$APP/Contents/Resources/"
fi

# App Intents. Shortcuts and Spotlight do not read the binary: they read a Metadata.appintents
# bundle that Xcode normally produces from constant values the compiler emits while building. A
# Swift package build emits none of that, so intents that compile perfectly are invisible to the
# system. Both halves are reproduced here.
#
# The extraction is its own typecheck pass rather than a flag on `swift build`, because
# -emit-const-values-path names ONE file and is only honoured by a whole-module frontend job: on a
# debug build it is silently dropped, and passing it to `swift build` would hand the same path to
# SwiftTerm and BloomCore as well. A separate pass over the app target alone costs a few seconds
# and answers about exactly the module that owns the intents.
emit_app_intents_metadata() {
  local toolchain processor sdk deployment triple sources constvalues protocols
  toolchain="$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain"
  processor="$toolchain/usr/bin/appintentsmetadataprocessor"
  protocols="$toolchain/usr/share/swift/SwiftConstantValues/AppIntents.json"

  # Full Xcode only. With just the command line tools there is no processor and no protocol list,
  # and a build that failed over it would be a worse trade than an app whose intents are missing.
  if [[ ! -x "$processor" || ! -f "$protocols" ]]; then
    echo "==> skipping App Intents metadata: $processor not found"
    return 0
  fi

  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  deployment="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
  triple="$(uname -m)-apple-macos$deployment"
  sources="$BIN_DIR/Bloom.appintents.sources"
  constvalues="$BIN_DIR/Bloom.swiftconstvalues"

  find Sources/Bloom -name '*.swift' > "$sources"

  # The frontend wants a bare array of protocol names. The file Xcode ships wraps the same list in
  # an object, which it rejects as malformed.
  local protocolList="$BIN_DIR/Bloom.appintents.protocols.json"
  /usr/bin/python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1]))['constValueProtocols'], open(sys.argv[2],'w'))" \
    "$protocols" "$protocolList"

  swiftc -typecheck -wmo \
    -module-name Bloom \
    -swift-version 6 \
    -target "$triple" \
    -sdk "$sdk" \
    -I "$BIN_DIR/Modules" \
    -F "${SPARKLE_SEARCH_PATH:-$BIN_DIR}" \
    -emit-const-values-path "$constvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$protocolList" \
    "@$sources"

  echo "$constvalues" > "$BIN_DIR/Bloom.appintents.constvalues"

  "$processor" \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$toolchain" \
    --module-name Bloom \
    --sdk-root "$sdk" \
    --xcode-version "$(xcodebuild -version 2>/dev/null | tail -1 | awk '{print $3}')" \
    --platform-family macOS \
    --deployment-target "$deployment" \
    --target-triple "$triple" \
    --source-file-list "$sources" \
    --swift-const-vals-list "$BIN_DIR/Bloom.appintents.constvalues" \
    --force >/dev/null
}

emit_app_intents_metadata

# After the metadata, because the bundle has to be signed with everything already inside it.
#
# Shortcuts refuses to talk to an ad-hoc signed app: it reaches an intent through an Apple Event
# and the connection is rejected with "Unable to get teamId", so intents that are visible in the
# library fail to run with "Shortcuts couldn't communicate with the app". A real signing identity
# is the only thing that fixes it, and there is no honest default for one, so it is named by the
# environment.
#
#   BLOOM_CODESIGN_IDENTITY="Apple Development: You (TEAMID)" ./Tools/build.sh
#
# The pre-rename spelling is still read, so a shell profile or CI job that exports
# BATON_CODESIGN_IDENTITY keeps producing a signed build rather than silently dropping to ad-hoc.
SIGN_IDENTITY="${BLOOM_CODESIGN_IDENTITY:-${BATON_CODESIGN_IDENTITY:--}}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> ad-hoc signed: App Intents will be listed in Shortcuts but will not run."
  echo "    Set BLOOM_CODESIGN_IDENTITY to a real identity to make them runnable."
fi

echo "==> $APP"
[[ $RUN -eq 1 ]] && open "$APP"
exit 0
