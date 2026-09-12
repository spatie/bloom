#!/bin/bash
# Build without launching Simulator or touching an installed Bloom application.
set -euo pipefail
source "$(dirname "$0")/prepare-ios.sh"
bloom_ios_begin
bloom_ios_prepare
# prepare-ios.sh verifies the sole reviewed build plugin before this invocation-only bypass.
xcodebuild -skipPackagePluginValidation -project "$project_dir/Bloom.xcodeproj" -scheme Bloom \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_dir" -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
