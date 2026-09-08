#!/bin/zsh
# Copy notices from the exact dependency checkouts SwiftPM built, before signing the bundle.
# Missing notices fail packaging rather than silently shipping an incomplete distribution.
set -euo pipefail

bundle="${1:?app bundle required}"
checkouts="${2:?SwiftPM checkouts directory required}"
source_root="$(cd "$(dirname "$0")/.." && pwd)"
notices="$bundle/Contents/Resources/Licences"
mkdir -p "$notices"

copy_notice() {
  [[ -s "$1" ]] || { echo "Missing licence notice: $1" >&2; return 1; }
  cp "$1" "$notices/$2"
}

copy_notice "$source_root/LICENSE.md" Bloom.txt
copy_notice "$checkouts/SwiftTerm/LICENSE" SwiftTerm.txt
# Sparkle's notice includes its bundled third-party licences.
copy_notice "$checkouts/Sparkle/LICENSE" Sparkle.txt
copy_notice "$checkouts/swift-argument-parser/LICENSE.txt" SwiftArgumentParser.txt
copy_notice "$checkouts/flare-client-swift/LICENSE.md" Flare.txt
copy_notice "$checkouts/plcrashreporter/LICENSE" PLCrashReporter.txt
