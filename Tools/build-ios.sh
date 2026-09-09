#!/bin/bash
# Build without launching Simulator or touching an installed Bloom application.
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir="${BLOOM_IOS_PROJECT_DIR:-/tmp/bloom-ios-project}"
build_dir="${BLOOM_IOS_BUILD_DIR:-/tmp/bloom-ios-build}"
Tools/prepare-ios.sh
xcodebuild -project "$project_dir/Bloom.xcodeproj" -scheme Bloom \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_dir" -jobs 2 CODE_SIGNING_ALLOWED=NO build
