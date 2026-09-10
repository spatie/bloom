#!/bin/bash
# Resolve before copying notices, so the app ships the licences of its actual dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir="${BLOOM_IOS_PROJECT_DIR:-/tmp/bloom-ios-project}"
build_dir="${BLOOM_IOS_BUILD_DIR:-/tmp/bloom-ios-build}"
python3 Tools/ios-project.py "$project_dir"
xcodebuild -resolvePackageDependencies -project "$project_dir/Bloom.xcodeproj" -scheme Bloom -derivedDataPath "$build_dir"
python3 Tools/check-ios-build-plugins.py "$build_dir/SourcePackages/checkouts"
python3 - "$build_dir/SourcePackages/checkouts" "$project_dir/Licences" <<'PY'
import pathlib, shutil, sys
checkouts, output = map(pathlib.Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
shutil.copyfile('LICENSE.md', output / 'Bloom.txt')
for dependency in ['SwiftTerm', 'AppAuth-iOS', 'swift-nio-ssh', 'swift-nio', 'swift-crypto', 'swift-atomics', 'swift-collections', 'swift-system', 'swift-asn1']:
    source = checkouts / dependency
    licences = [file for file in source.glob('LICENSE*') if file.is_file()]
    if not licences:
        raise SystemExit(f'Missing licence for {dependency}')
    notices = [file for file in source.glob('NOTICE*') if file.is_file()]
    (output / f'{dependency}.txt').write_text('\n\n'.join(file.read_text() for file in sorted(licences + notices)))
PY
