#!/bin/zsh
# Runs the BatonCore test suite without building the SwiftUI app target.
#
# `swift test` on the real package always builds the Baton executable too, so a single broken
# view stops every core test from running. This mirrors the core sources into a throwaway
# package that has no app target, which keeps the core suite runnable at all times.
#
#   ./test-core.sh                        run everything
#   ./test-core.sh DiffParser             run one suite by filter
#   ./test-core.sh DiffParser Git          run several (each argument is its own --filter)
#   BATON_TEST_RUNS=5 ./test-core.sh      run the whole thing five times, to shake out flakes
#
# Environment:
#   BATON_TEST_ID       stable name for the work and build directories, so repeated runs by the
#                       same caller stay incremental
#   BATON_TEST_RUNS     how many times to run the suite (default 1)
#   BATON_LOCAL_AGENTS  =1 asserts which agent CLIs exist on this machine
#   BATON_LOCAL_SETTINGS=1 parses the .conductor/settings.toml files on this machine
#   BATON_LIVE          =1 drives the real `claude` binary. Costs money.

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
ID="${BATON_TEST_ID:-$$}"

# Per-invocation, because two of these running at once would otherwise share one build database
# and corrupt each other. The scratch path has to carry the same id: it *is* the build database,
# so leaving it shared would have re-introduced exactly the corruption the work directory avoids.
WORK="$TMP/baton-core-tests-$ID"
SCRATCH="$TMP/baton-core-build-$ID"

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

filters=()
for name in "$@"; do
  filters+=(--filter "$name")
done

cd "$WORK"
runs="${BATON_TEST_RUNS:-1}"
failed=0
for run in $(seq 1 "$runs"); do
  if [[ "$runs" -gt 1 ]]; then
    print -r -- "===> run $run of $runs"
  fi
  if ! swift test --scratch-path "$SCRATCH" "${filters[@]}"; then
    failed=$((failed + 1))
  fi
done

if [[ "$failed" -gt 0 ]]; then
  print -r -- "===> $failed of $runs runs failed"
  exit 1
fi
