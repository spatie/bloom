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
#   BLOOM_LOCAL_SKILLS  =1 reads the commands, skills and plugins installed on this machine
#   BLOOM_LOCAL_PROJECT names the checkout BLOOM_LOCAL_SKILLS reads project commands out of. The
#                       suite runs from the mirror, so its own working directory is the wrong
#                       answer and there is nothing to default to
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

# **Both go when this exits, unless the caller named the run.** A build directory is ~750MB and
# this script made a fresh one per invocation and never removed it; on the machine this was written
# on that had reached **463 of them, 300GB**, and the disk filled during an ordinary afternoon of
# agents running the suite. Naming a run through BLOOM_TEST_ID is the one case that wants the
# directory kept, because that is what makes a repeated run incremental, and a caller that named it
# is a caller that knows it is there.
#
# `EXIT` alone covers the ordinary end and a `set -e` failure; the signals are the ones a person or
# an editor sends, and without them a cancelled run keeps its 750MB for ever.
if [[ -z "${BLOOM_TEST_ID:-}" ]]; then
  trap 'rm -rf "$WORK" "$SCRATCH"' EXIT INT TERM HUP
fi

# What a previous run left when it was killed outright, which no trap can cover. A day, so a run
# still going on somebody else's terminal is never swept out from under them, and quiet because
# this is tidying rather than news. The test process sweeps its own scratch the same way: see
# `TestProcessScratch` in Tests/BloomCoreTests/TestSupport.swift.
find "$TMP" -maxdepth 1 \( -name 'bloom-core-build-*' -o -name 'bloom-core-tests-*' \
  -o -name 'bloom-test-run-*' \) -mtime +1 -print0 2>/dev/null \
  | xargs -0 -n 20 rm -rf 2>/dev/null || true

rm -rf "$WORK"
mkdir -p "$WORK/Sources" "$WORK/Tests"
ln -sfn "$ROOT/Sources/BloomCore" "$WORK/Sources/BloomCore"
# The MCP shim, mirrored alongside. It depends on BloomCore and nothing else, so building it here
# cannot be stopped by a broken view, which is the whole reason this mirror exists. It is built
# rather than merely compiled because BridgeShimTests drives the real binary: a shim that is only
# ever spoken to by another test proves nothing about the process an agent CLI actually launches.
ln -sfn "$ROOT/Sources/bloom-bridge" "$WORK/Sources/bloom-bridge"
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
        .executableTarget(
            name: "bloom-bridge",
            dependencies: ["BloomCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
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

# The shim, built once and named in the environment, because `BridgeRegistration.shimPath` looks
# beside the running executable and the running executable here is the test bundle's. Failing to
# build it is not fatal: `BridgeShimTests` is skipped when the variable names nothing, exactly as
# the live suites are, and the rest of the bridge is still covered against the socket directly.
if swift build --scratch-path "$SCRATCH" --product bloom-bridge >/dev/null 2>&1; then
  export BLOOM_BRIDGE_SHIM="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/bloom-bridge"
else
  print -r -- "===> could not build bloom-bridge, so the shim tests will be skipped"
fi

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
