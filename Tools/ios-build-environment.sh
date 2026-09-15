#!/bin/bash
# Generated projects contain absolute checkout paths. Each checkout therefore owns its project
# and derived data; explicit shared overrides are locked until the complete build has finished.
#
# The paths are answered by `bloom_ios_path` rather than left behind as globals by
# `bloom_ios_begin`. shellcheck reads each script on its own, so a variable assigned inside a
# sourced file is one it reports as never assigned in every script that reads it.
bloom_ios_path() {
    local checkout_hash cache_root
    checkout_hash="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P | shasum | cut -c1-12)"
    cache_root="$HOME/Library/Caches/BloomBuild/ios/$checkout_hash"
    case "$1" in
        project) printf '%s\n' "${BLOOM_IOS_PROJECT_DIR:-$cache_root/project}" ;;
        build) printf '%s\n' "${BLOOM_IOS_BUILD_DIR:-$cache_root/build}" ;;
        archive) printf '%s\n' "${BLOOM_IOS_ARCHIVE_PATH:-$cache_root/Bloom-iOS.xcarchive}" ;;
        *) echo "bloom_ios_path: unknown path $1" >&2; return 1 ;;
    esac
}

bloom_ios_begin() {
    local mode="${1:-build}" lock existing project_dir build_dir archive_path
    cd "$(dirname "${BASH_SOURCE[0]}")/.." || return 1
    project_dir="$(bloom_ios_path project)"
    build_dir="$(bloom_ios_path build)"
    archive_path="$(bloom_ios_path archive)"
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
