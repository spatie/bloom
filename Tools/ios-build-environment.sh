#!/bin/bash
# Generated projects contain absolute checkout paths. Each checkout therefore owns its project
# and derived data; explicit shared overrides are locked until the complete build has finished.
bloom_ios_begin() {
    local mode="${1:-build}" checkout_hash cache_root lock existing
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    checkout_hash="$(pwd -P | shasum | cut -c1-12)"
    cache_root="$HOME/Library/Caches/BloomBuild/ios/$checkout_hash"
    project_dir="${BLOOM_IOS_PROJECT_DIR:-$cache_root/project}"
    build_dir="${BLOOM_IOS_BUILD_DIR:-$cache_root/build}"
    archive_path="${BLOOM_IOS_ARCHIVE_PATH:-$cache_root/Bloom-iOS.xcarchive}"
    bloom_ios_locks=()
    trap bloom_ios_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    local candidates=("$project_dir.bloom-build.lock" "$build_dir.bloom-build.lock")
    if [[ "$mode" == archive ]]; then candidates+=("$archive_path.bloom-build.lock"); fi
    for lock in "${candidates[@]}"; do
        for existing in "${bloom_ios_locks[@]+"${bloom_ios_locks[@]}"}"; do
            if [[ "$existing" == "$lock" ]]; then continue 2; fi
        done
        mkdir -p "$(dirname "$lock")"
        if ! mkdir "$lock" 2>/dev/null; then
            echo "Another iOS build owns $lock. Remove it only after its build has stopped." >&2
            return 1
        fi
        bloom_ios_locks+=("$lock")
    done
}

bloom_ios_cleanup() {
    local lock
    for lock in "${bloom_ios_locks[@]+"${bloom_ios_locks[@]}"}"; do rmdir "$lock"; done
}
