#!/bin/zsh
# Runs the BloomCore test suite without building the SwiftUI app target.
#
# `swift test` on the real package always builds the Bloom executable too, so a single broken
# view stops every core test from running. This mirrors the core sources into a throwaway
# package that has no app target, which keeps the core suite runnable at all times.
#
#   ./Tools/test-core.sh                   run everything, which is also `make test`
#   ./Tools/test-core.sh DiffParser        run one suite by filter
#   ./Tools/test-core.sh DiffParser Git    run several (each argument is its own --filter)
#   BLOOM_TEST_RUNS=5 ./Tools/test-core.sh run the whole thing five times, to shake out flakes
#
# Environment:
#   BLOOM_TEST_ID       stable name for the work and build directories, so repeated runs by the
#                       same caller stay incremental
#   BLOOM_TEST_RUNS     how many times to run the suite (default 1)
#   BLOOM_LOCAL_AGENTS  =1 asserts which agent CLIs exist on this machine
#   BLOOM_LOCAL_SETTINGS=1 parses the .conductor/settings.toml files on this machine
#   BLOOM_LIVE          =1 drives the real `claude` binary. Costs money.
#   BLOOM_TEST_SWIFT_ARGS  extra flags for `swift test`, split on spaces. For the runs that are
#                       not the ordinary one: the nightly workflow passes --sanitize=thread and
#                       --enable-code-coverage through here rather than reimplementing the
#                       mirrored package it needs to avoid building the app target.
#

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="${TMPDIR:-/tmp}"
ID="${BLOOM_TEST_ID:-$$}"

# Read by the test suites themselves rather than by this script, so the legacy spelling has to be
# promoted into the environment the tests actually see.
# Per-invocation, because two of these running at once would otherwise share one build database
# and corrupt each other. The scratch path has to carry the same id: it *is* the build database,
# so leaving it shared would have re-introduced exactly the corruption the work directory avoids.
WORK="$TMP/bloom-core-tests-$ID"
SCRATCH="$TMP/bloom-core-build-$ID"

rm -rf "$WORK"
mkdir -p "$WORK/Sources" "$WORK/Tests"
ln -sfn "$ROOT/Sources/BloomCore" "$WORK/Sources/BloomCore"
ln -sfn "$ROOT/Tests/BloomCoreTests" "$WORK/Tests/BloomCoreTests"
# The tests find a fixture by walking up from their own file, so it has to be reachable
# from the mirrored Tests directory as well as from the real one.
ln -sfn "$ROOT/Tests/fixtures" "$WORK/Tests/fixtures"

cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BloomCoreOnly",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "BloomCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "BloomCoreTests",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
EOF

filters=()
for name in "$@"; do
  filters+=(--filter "$name")
done

# Split on spaces, which is what ${=...} is for. An unset variable leaves an empty array, and an
# empty array in quotes expands to no words at all, so the ordinary run is unchanged.
extra=(${=BLOOM_TEST_SWIFT_ARGS:-})

cd "$WORK"
runs="${BLOOM_TEST_RUNS:-1}"
failed=0
for run in $(seq 1 "$runs"); do
  if [[ "$runs" -gt 1 ]]; then
    print -r -- "===> run $run of $runs"
  fi
  if ! swift test --scratch-path "$SCRATCH" "${extra[@]}" "${filters[@]}"; then
    failed=$((failed + 1))
  fi
done

if [[ "$failed" -gt 0 ]]; then
  print -r -- "===> $failed of $runs runs failed"
  exit 1
fi
