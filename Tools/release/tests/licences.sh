#!/bin/zsh
# Packaging contract without a compiler, credentials or an installed application.
set -euo pipefail
cd "$(dirname "$0")/../../.."
fixture="$(mktemp -d "${TMPDIR:-/tmp}/bloom-licence-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/checkouts/SwiftTerm" "$fixture/checkouts/Sparkle" "$fixture/checkouts/swift-argument-parser"
mkdir -p "$fixture/checkouts/flare-client-swift" "$fixture/checkouts/plcrashreporter"
cp LICENSE.md "$fixture/checkouts/SwiftTerm/LICENSE"
cp LICENSE.md "$fixture/checkouts/Sparkle/LICENSE"
cp LICENSE.md "$fixture/checkouts/swift-argument-parser/LICENSE.txt"
cp LICENSE.md "$fixture/checkouts/flare-client-swift/LICENSE.md"
cp LICENSE.md "$fixture/checkouts/plcrashreporter/LICENSE"
zsh Tools/package-licences.sh "$fixture/Bloom.app" "$fixture/checkouts"
for notice in Bloom SwiftTerm Sparkle SwiftArgumentParser Flare PLCrashReporter; do
  cmp LICENSE.md "$fixture/Bloom.app/Contents/Resources/Licences/$notice.txt"
done
if zsh Tools/package-licences.sh "$fixture/Incomplete.app" "$fixture/missing" >/dev/null 2>&1; then
  echo "Packaging accepted missing dependency notices" >&2
  exit 1
fi
echo "Licence packaging checks passed"
