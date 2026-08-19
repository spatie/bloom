#!/bin/zsh
# Downloads Sparkle's command line tools and prints the directory holding them.
#
#   BIN="$(Tools/release/sparkle-tools.sh)"
#   "$BIN/sign_update" ...
#
# sign_update is not built by `swift build`: the Swift package product is the
# framework the app links against, and the tools ship only in the binary
# release. So they are fetched, into a cache directory that a CI cache can keep
# between runs.
#
# The version is pinned here rather than read from Package.resolved, because
# the signing format is what has to match, not the framework, and it has not
# changed across 2.x. Bump it deliberately.

set -euo pipefail

VERSION=${SPARKLE_VERSION:-2.9.6}
CACHE=${SPARKLE_TOOLS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sparkle-tools}
DEST="$CACHE/$VERSION"

if [ ! -x "$DEST/bin/sign_update" ]; then
  mkdir -p "$DEST"
  TARBALL="$CACHE/Sparkle-$VERSION.tar.xz"
  echo "==> downloading Sparkle $VERSION tools" >&2
  curl -fsSL -o "$TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  tar -xJf "$TARBALL" -C "$DEST"
  rm -f "$TARBALL"
fi

[ -x "$DEST/bin/sign_update" ] || { echo "sparkle-tools.sh: sign_update did not arrive" >&2; exit 1; }

echo "$DEST/bin"
