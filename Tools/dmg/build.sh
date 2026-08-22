#!/bin/zsh
# Wraps a built Bloom.app in the beach disk image, dist/Bloom-<version>.dmg.
#
#   ./Tools/dmg/build.sh                use the newest app under .build
#   ./Tools/dmg/build.sh --app <path>   wrap that app instead
#   ./Tools/dmg/build.sh --out <path>   write the image somewhere else
#
# `make dmg` is the first of those. The window is a drawn scene, not a plain
# background: a mint ribbon leaves the app icon's own artwork, crosses the
# window and slips under a beach, and the two ends of that ribbon meet the
# icon's tile to half a point. The scene lives in background.html next to this
# script, and every calibrated number in it carries the measurement it came
# from, so read the comments there before nudging anything.
#
# The pipeline: render the HTML twice with headless Chrome, at 1x and at 2x,
# and fold both into one TIFF with tiffutil -cathidpicheck so retina Finder
# picks the sharp one. Then dmgbuild lays out the volume from settings.py, the
# image is reopened writable so postprocess.py can hide the background file
# inside .Trashes (the why of that lives at the head of postprocess.py, and it
# cost most of a day to learn), and the result is compressed back to a read
# only UDZO.
#
# Chrome specifically, not any browser: the artwork was matched against the
# icon as Chrome rasterises it, to half a point at the ribbon joins, and a
# different renderer shifts the antialiasing enough to show at the seam.
# dmgbuild arrives through a private venv under .build on first run, so the
# only thing this script assumes about the machine is Chrome and python3.

set -euo pipefail
cd "$(dirname "$0")/../.."

APP=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$APP" ]; then
  for candidate in .build/release/Bloom.app \
                   .build/arm64-apple-macosx/release/Bloom.app \
                   .build/arm64-apple-macosx/debug/Bloom.app; do
    if [ -d "$candidate" ]; then APP=$candidate; break; fi
  done
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "no Bloom.app under .build; run make app first, or pass --app <path>" >&2
  exit 1
fi
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
  echo "Google Chrome is needed to render the background; see the head of this script" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"
[ -n "$OUT" ] || OUT="$PWD/dist/Bloom-$version.dmg"

WORK=$PWD/.build/dmg
VENV=$PWD/.build/dmg-venv
TOOLS=$PWD/Tools/dmg
mkdir -p "$WORK" "$(dirname "$OUT")"

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "==> installing dmgbuild into $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild
fi

echo "==> rendering the background"
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --screenshot="$WORK/bg-660.png" --window-size=660,400 \
  "file://$TOOLS/background.html" 2>/dev/null
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --screenshot="$WORK/bg-1320.png" --window-size=660,400 --force-device-scale-factor=2 \
  "file://$TOOLS/background.html" 2>/dev/null
tiffutil -cathidpicheck "$WORK/bg-660.png" "$WORK/bg-1320.png" \
  -out "$WORK/background.tiff" >/dev/null 2>&1

echo "==> laying out the volume"
# A leftover mount with the same volume name would make hdiutil mount the new
# one somewhere unexpected, and the postprocess step needs the real path.
hdiutil detach /Volumes/Bloom >/dev/null 2>&1 || true
rm -f "$WORK/Bloom.dmg" "$WORK/rw.dmg" "$OUT"
"$VENV/bin/dmgbuild" \
  -s "$TOOLS/settings.py" \
  -D app="$APP" -D background="$WORK/background.tiff" \
  Bloom "$WORK/Bloom.dmg" >/dev/null 2>&1

echo "==> hiding the background file"
hdiutil convert "$WORK/Bloom.dmg" -format UDRW -o "$WORK/rw.dmg" >/dev/null 2>&1
MOUNT="$(hdiutil attach "$WORK/rw.dmg" -nobrowse 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}' | sed 's/^ *//')"
"$VENV/bin/python" "$TOOLS/postprocess.py" "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null 2>&1
hdiutil convert "$WORK/rw.dmg" -format UDZO -o "$OUT" >/dev/null 2>&1
rm -f "$WORK/Bloom.dmg" "$WORK/rw.dmg"

echo "==> $OUT"
