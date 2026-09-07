#!/bin/zsh
# Packaging contract without a compiler, credentials or an installed application.
set -euo pipefail
cd "$(dirname "$0")/../../.."
fixture="$(mktemp -d -t bloom-licence-test)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/checkouts/SwiftTerm" "$fixture/checkouts/Sparkle" "$fixture/checkouts/swift-argument-parser"
cp LICENSE.md "$fixture/checkouts/SwiftTerm/LICENSE"
cp LICENSE.md "$fixture/checkouts/Sparkle/LICENSE"
cp LICENSE.md "$fixture/checkouts/swift-argument-parser/LICENSE.txt"
zsh Tools/package-licences.sh "$fixture/Bloom.app" "$fixture/checkouts"
for notice in Bloom SwiftTerm Sparkle SwiftArgumentParser; do
  cmp LICENSE.md "$fixture/Bloom.app/Contents/Resources/Licences/$notice.txt"
done
if zsh Tools/package-licences.sh "$fixture/Incomplete.app" "$fixture/missing" >/dev/null 2>&1; then
  echo "Packaging accepted missing dependency notices" >&2
  exit 1
fi
echo "Licence packaging checks passed"
