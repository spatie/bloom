#!/bin/zsh
# Runs the BatonCore test suite without building the SwiftUI app target.
#
# `swift test` on the real package always builds the Baton executable too, so a single broken
# view stops every core test from running. This mirrors the core sources into a throwaway
# package that has no app target, which keeps the core suite runnable at all times.
#
#   ./test-core.sh                 run everything
#   ./test-core.sh DiffParser      run one suite by filter

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
# Per-invocation, because two of these running at once would otherwise share one build database
# and corrupt each other. Reuses a stable path when BATON_TEST_ID is set, so repeated runs by the
# same caller stay incremental.
WORK="${TMPDIR:-/tmp}/baton-core-tests-${BATON_TEST_ID:-$$}"

rm -rf "$WORK"
mkdir -p "$WORK/Sources" "$WORK/Tests"
ln -sfn "$ROOT/Sources/BatonCore" "$WORK/Sources/BatonCore"
ln -sfn "$ROOT/Tests/BatonCoreTests" "$WORK/Tests/BatonCoreTests"
# Tests resolve fixtures relative to the package root, so it has to exist here too.
ln -sfn "$ROOT/fixtures" "$WORK/fixtures"

cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatonCoreOnly",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "BatonCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BatonCoreTests",
            dependencies: ["BatonCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
EOF

cd "$WORK"
if [[ $# -gt 0 ]]; then
  swift test --scratch-path "${TMPDIR:-/tmp}/baton-core-build" --filter "$1"
else
  swift test --scratch-path "${TMPDIR:-/tmp}/baton-core-build"
fi
