#!/bin/zsh
# Runs the welcome transition regression in an invisible, isolated bundle after swift build.
set -euo pipefail
cd "$(dirname "$0")/.."

bin_dir="$(swift build --show-bin-path)"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-welcome-probe.XXXXXX")"
probe_app="$probe_root/Bloom Welcome Probe.app"
framework="$(find .build/artifacts -path '*Sparkle.xcframework/macos*/Sparkle.framework' -type d | head -1)"
[[ -n "$framework" ]]
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Frameworks"
cp "$bin_dir/Bloom" "$probe_app/Contents/MacOS/Bloom"
cp Resources/Info.plist "$probe_app/Contents/Info.plist"
ditto Resources "$probe_app/Contents/Resources"
ditto "$framework" "$probe_app/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier be.spatie.bloom.welcome-probe' "$probe_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Bloom Welcome Probe' "$probe_app/Contents/Info.plist"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$probe_app/Contents/MacOS/Bloom"
codesign --force --deep --sign - "$probe_app" >/dev/null 2>&1

# Refuse a release or stale binary, which would ignore the flag and start the application.
python3 - "$probe_app/Contents/MacOS/Bloom" "$probe_root" <<'PY'
import json
import pathlib
import subprocess
import sys

binary, root = sys.argv[1:]
if b'--welcome-layout-probe' not in pathlib.Path(binary).read_bytes():
    raise SystemExit('Build the debug app with swift build before running this probe.')
for scenario in ('all-clear', 'no-agent', 'signed-out-github'):
    subprocess.run(
        ['open', '-g', '-n', '-W', '-a', str(pathlib.Path(binary).parents[2]),
         '--stdout', f'{root}/{scenario}.json', '--stderr', f'{root}/{scenario}.log',
         '--args', '--welcome-layout-probe', '--setup-rehearsal', scenario],
        timeout=45, check=True,
    )
    report = pathlib.Path(root, f'{scenario}.json').read_text()
    print(f'{scenario}: {report}')
    if not json.loads(report)['passed']:
        raise SystemExit(f'{scenario} failed; evidence: {root}')
print(f'Probe evidence: {root}')
PY
