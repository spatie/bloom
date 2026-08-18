#!/bin/zsh
# Builds Bloom and assembles a launchable .app bundle.
#
#   ./build.sh            debug build
#   ./build.sh -r         release build
#   ./build.sh -r --run   release build, then launch it

set -euo pipefail
cd "$(dirname "$0")"

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
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS 26 draws an app icon from a layered Icon Composer document rather than from a flat bitmap:
# the glass, the shadow and the specular pass belong to the system and are applied live to the
# layers. Resources/Bloom.icon is that document. actool compiles it into an Assets.car, which the
# system finds through CFBundleIconName in Info.plist. AppIcon.icns and CFBundleIconFile stay
# exactly as they are and remain what every release before 26 draws, so nothing about the macOS 15
# deployment target changes; this needs no Xcode project and no raised floor.
#
# Command line tools on their own carry no actool, and a build that failed over the icon would be a
# worse trade than one that ships the flat icon alone.
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

  # actool writes a flattened $iconName.icns beside the catalogue as well. AppIcon.icns is the one
  # built to the measured template, so the spare is dropped rather than shipped next to it.
  rm -f "$APP/Contents/Resources/$iconName.icns"

  # Nothing above proves the catalogue arrived: actool reports a failure in the plist it prints and
  # is not reliably non-zero about it. The bundle either has the file or the build is wrong.
  if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "==> layered icon: actool produced no Assets.car" >&2
    return 1
  fi
}

compile_layered_icon

# The About pane reads these out of the bundle by name. PDFs rather than bitmaps, because AppKit
# redraws a PDF as vector art at whatever scale the display asks for. The .svg beside each one is
# the source it was generated from and is not needed at runtime.
for logo in Resources/Spatie*.pdf(N); do
  cp "$logo" "$APP/Contents/Resources/"
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
#   BLOOM_CODESIGN_IDENTITY="Apple Development: You (TEAMID)" ./build.sh
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
