#!/bin/zsh
# Fetch the pinned Mailpit release for this build machine and verify its archive before bundling.
# The release is a build input, never a runtime download on a user's Mac.

set -euo pipefail
cd "$(dirname "$0")/.."

version=v1.31.6
case "$(uname -m)" in
  arm64)
    architecture=arm64
    expected=1411270aa8fd7f4fb0cc358318754d7bb7c2c30bfd70572dd12d05a53e956373
    ;;
  x86_64)
    architecture=amd64
    expected=2f89ed77d2e6623bf700de42236858d10dde1ba96a222c9dbdefd33fa094a6f3
    ;;
  *) print -ru2 -- "Unsupported Mailpit build architecture: $(uname -m)"; exit 1 ;;
esac

cache="$PWD/.build/mailpit/$version/$architecture"
archive="$cache/mailpit-darwin-$architecture.tar.gz"
mkdir -p "$cache"
if [[ ! -f "$archive" ]]; then
  download="$archive.download"
  rm -f "$download"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
    "https://github.com/axllent/mailpit/releases/download/$version/mailpit-darwin-$architecture.tar.gz" \
    --output "$download"
  mv "$download" "$archive"
fi

actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  print -ru2 -- "Mailpit $version archive checksum mismatch for $architecture."
  rm -f "$archive"
  exit 1
fi

tar -xOzf "$archive" mailpit > "$cache/mailpit.new"
chmod 755 "$cache/mailpit.new"
mv "$cache/mailpit.new" "$cache/mailpit"
tar -xOzf "$archive" LICENSE > "$cache/LICENSE"
print -r -- "$cache/mailpit"
