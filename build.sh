#!/bin/zsh
# Builds Baton and assembles a launchable .app bundle.
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
swift build -c "$CONFIG" --product Baton

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$BIN_DIR/Baton.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Baton" "$APP/Contents/MacOS/Baton"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftTerm and friends ship as dylibs in a debug build; carry them along.
for lib in "$BIN_DIR"/*.dylib(N); do
  cp "$lib" "$APP/Contents/MacOS/"
done

if [[ -d "$BIN_DIR/Baton_Baton.bundle" ]]; then
  cp -R "$BIN_DIR/Baton_Baton.bundle" "$APP/Contents/Resources/"
fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> $APP"
[[ $RUN -eq 1 ]] && open "$APP"
exit 0
