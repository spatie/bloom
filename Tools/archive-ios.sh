#!/bin/bash
# Produce an archive without launching, installing or uploading. Signing is explicit.
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir="${BLOOM_IOS_PROJECT_DIR:-/tmp/bloom-ios-project}"
build_dir="${BLOOM_IOS_BUILD_DIR:-/tmp/bloom-ios-build}"
archive_path="${BLOOM_IOS_ARCHIVE_PATH:-/tmp/Bloom-iOS.xcarchive}"
Tools/prepare-ios.sh
signing=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${BLOOM_IOS_TEAM_ID:-}" ]]; then
    signing=("DEVELOPMENT_TEAM=$BLOOM_IOS_TEAM_ID" CODE_SIGN_STYLE=Automatic)
fi
xcodebuild -project "$project_dir/Bloom.xcodeproj" -scheme Bloom \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$build_dir" -archivePath "$archive_path" -jobs 2 \
    "${signing[@]}" SKIP_INSTALL=NO archive
printf 'Archive: %s\n' "$archive_path"
if [[ -z "${BLOOM_IOS_TEAM_ID:-}" ]]; then
    printf 'Unsigned verification archive. Set BLOOM_IOS_TEAM_ID to archive with your configured development team.\n'
fi
