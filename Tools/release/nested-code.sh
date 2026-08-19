#!/bin/zsh
# Lists everything inside an app bundle that has to be signed before the bundle
# itself, deepest first.
#
#   Tools/release/nested-code.sh /path/to/Bloom.app
#
# Its own script because it is the part of signing most likely to be quietly
# wrong, and this way it can be tested against a bundle shaped like a real one
# without a certificate anywhere near it. See Tools/release/tests/run.sh.
#
# Two lists, joined:
#
#   Nested bundles. Frameworks, XPC services and helper apps. Symlinks are left
#   out, so a framework's Versions/Current alias is not signed a second time
#   under its other name.
#
#   Loose Mach-O files. This is the one that matters. Sparkle puts an
#   `Autoupdate` binary straight into its framework rather than inside a
#   bundle, and it is not named like a library, so a search for frameworks and
#   dylibs walks straight past it. Missed, it keeps whatever signature the
#   debug build gave it, `codesign --verify` is happy, and Apple's notary
#   service rejects the whole submission an hour later.
#
# Deepest first, so an executable is signed before the bundle around it.
# Signing the bundle re-signs that executable in place, which makes the earlier
# pass redundant rather than wrong, and means the order can never be wrong.

set -euo pipefail

APP=${1:-}
[ -d "$APP" ] || { echo "nested-code.sh: no bundle at '$APP'" >&2; exit 1; }

{
  find "$APP/Contents" -mindepth 1 -not -type l \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -print

  find "$APP/Contents" -mindepth 1 -type f -perm +111 -not -type l -print \
  | while IFS= read -r candidate; do
      # head, because file prints a line per architecture for a fat binary.
      case "$(file --mime-type -b "$candidate" | head -1)" in
        application/x-mach-binary) printf '%s\n' "$candidate" ;;
      esac
    done
} \
| sort -u \
| awk '{ n = gsub(/\//, "/"); print n "\t" $0 }' \
| sort -rn \
| cut -f2-
