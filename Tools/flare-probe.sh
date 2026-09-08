#!/bin/zsh
# Sends two synthetic errors and recovers one intentional crash from the Bloom binary.
# The isolated bundle never enters SwiftUI, opens a database or touches the running app.
# Build the debug bundle with Tools/build.sh first. This script does not launch the UI.

set -euo pipefail
cd "$(dirname "$0")/.."

bin_dir="$(swift build --show-bin-path)"
source_app="$bin_dir/Bloom.app"
if [[ ! -d "$source_app" ]]; then
  echo "Build the debug app with ./Tools/build.sh first." >&2
  exit 1
fi

# An older binary would ignore the flag and open its UI. Refuse it before launching anything.
python3 - "$source_app/Contents/MacOS/Bloom" <<'PY'
import pathlib
import sys

marker = b'The Flare probe requires its own bundle and temporary directory.'
if marker not in pathlib.Path(sys.argv[1]).read_bytes():
    raise SystemExit('The app has no debug Flare probe. Rebuild with ./Tools/build.sh.')
PY

probe_root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-flare-probe.XXXXXX")"
touch "$probe_root/.bloom-flare-probe"
print -r -- "Probe evidence: $probe_root"
probe_app="$probe_root/Bloom Flare Probe.app"
ditto "$source_app" "$probe_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier be.spatie.bloom.flare-probe' "$probe_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Bloom Flare Probe' "$probe_app/Contents/Info.plist"
codesign --force --deep --sign - "$probe_app" >/dev/null 2>&1

python3 - "$probe_app/Contents/MacOS/Bloom" "$probe_root" <<'PY'
import json
import pathlib
import signal
import subprocess
import sys

binary, root = sys.argv[1:]
for mode in ('reports', 'crash', 'retry', 'upload', 'empty'):
    command = [binary, '--flare-probe', mode, '--flare-probe-root', root]
    if mode == 'crash':
        command.append('--confirm-crash')
    result = subprocess.run(command, capture_output=True, text=True, timeout=45)
    if mode == 'crash':
        if result.returncode not in (-signal.SIGTRAP, -signal.SIGILL):
            print(result.stdout)
            print(result.stderr[-2000:])
            raise SystemExit(f'Expected a deliberate Swift trap, got {result.returncode}')
        print('crash: captured the intentional Swift trap')
        continue
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr[-2000:])
        raise SystemExit(f'{mode} failed with {result.returncode}')
    output = json.loads(pathlib.Path(root, f'{mode}.json').read_text())
    print(json.dumps(output, indent=2))
print(f'Probe evidence: {root}')
PY
