#!/bin/bash
# Produce an archive without launching, installing or uploading. Signing is explicit.
set -euo pipefail
# Checked as its own input, as every script is, so the source is not followed.
# shellcheck source=/dev/null
source "$(dirname "$0")/prepare-ios.sh"
bloom_ios_begin archive
bloom_ios_prepare
project_dir="$(bloom_ios_path project)"
build_dir="$(bloom_ios_path build)"
archive_path="$(bloom_ios_path archive)"
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${BLOOM_IOS_TEAM_ID:-}" ]]; then
    signing=("DEVELOPMENT_TEAM=$BLOOM_IOS_TEAM_ID" CODE_SIGN_STYLE=Automatic)
fi
# prepare-ios.sh verifies the sole reviewed build plugin before this invocation-only bypass.
xcodebuild -skipPackagePluginValidation -project "$project_dir/Bloom.xcodeproj" -scheme Bloom \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$build_dir" -archivePath "$archive_path" -jobs 2 \
    "${signing[@]}" archive
printf 'Archive: %s\n' "$archive_path"
if [[ -z "${BLOOM_IOS_TEAM_ID:-}" ]]; then
    printf 'Unsigned verification archive. Set BLOOM_IOS_TEAM_ID to archive with your configured development team.\n'
fi
