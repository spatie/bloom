#!/bin/zsh
# Runs the diff comment regression in an invisible, isolated bundle after swift build.
# Pass --review-compare-eager to also measure the previous 5,000-line renderer.
set -euo pipefail
cd "$(dirname "$0")/.."

bin_dir="$(swift build --show-bin-path)"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/bloom-review-probe.XXXXXX")"
probe_app="$probe_root/Bloom Review Probe.app"
framework="$(find .build/artifacts -path '*Sparkle.xcframework/macos*/Sparkle.framework' -type d | head -1)"
[[ -n "$framework" ]]
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Frameworks"
cp "$bin_dir/Bloom" "$probe_app/Contents/MacOS/Bloom"
cp Resources/Info.plist "$probe_app/Contents/Info.plist"
ditto Resources "$probe_app/Contents/Resources"
ditto "$framework" "$probe_app/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier be.spatie.bloom.review-probe' "$probe_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Bloom Review Probe' "$probe_app/Contents/Info.plist"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$probe_app/Contents/MacOS/Bloom"
codesign --force --deep --sign - "$probe_app" >/dev/null 2>&1

# Refuse a release or stale binary, which would ignore the flag and start the application.
python3 - "$probe_app/Contents/MacOS/Bloom" "$probe_root" "$@" <<'PY'
import json
import os
import shutil
import pathlib
import subprocess
import sys

binary, root, *arguments = sys.argv[1:]
if b'--review-run-probe' not in pathlib.Path(binary).read_bytes():
    raise SystemExit('Build the debug app with swift build before running this probe.')
# A real, disposable worktree for full-screen review snapshots and navigation checks.
fixture = pathlib.Path(root, 'fixture')
fixture.mkdir()
for name, body in {
    'Config/features.json': '{"free_shipping": false}\n',
    'Docs/legacy-shipping.md': 'Shipping costs 4.95 for every order.\n',
    'README.md': '# Checkout\n\nShipping costs 4.95 for every order.\n',
    'Sources/Checkout.swift': 'struct Checkout {\n    var shipping: Decimal { 4.95 }\n}\n',
}.items():
    target = fixture / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body)
def git(*args):
    subprocess.run(['git', '-C', str(fixture), *args], check=True, capture_output=True)
git('init', '-b', 'main')
git('add', '.')
git('-c', 'commit.gpgsign=false', '-c', 'user.name=Review Probe',
    '-c', 'user.email=probe@example.test', 'commit', '-m', 'Fixture')
(fixture / 'Config/features.json').write_text('{"free_shipping": true, "threshold": 50}\n')
(fixture / 'Docs/legacy-shipping.md').unlink()
(fixture / 'Docs/review-checklist.md').write_text('# Review checklist\n\n- Check empty carts.\n- Check quantities.\n')
(fixture / 'README.md').write_text(
    '# Checkout\n\nOrders of 50 or more qualify for free shipping.\n'
    'Smaller orders cost 4.95 to ship.\nEmpty carts have no shipping charge.\n'
    '\n## Review\n\nRead the changes and add comments beside the relevant lines.\n'
)
(fixture / 'Sources/Checkout.swift').write_text(
    '    struct Checkout {\n    var freeShippingThreshold: Decimal = 50\n'
    '    var shippingFee: Decimal = 4.95\n\n'
    '    var qualifiesForFreeShipping: Bool {\n        subtotal >= freeShippingThreshold\n    }\n'
    '}\n'
)
(fixture / 'Sources/LongReview.swift').write_text(
    ''.join(f'let reviewLine{line} = {line}\n' for line in range(1800 if '--review-scroll-profile' in arguments else 120))
)
# Several screens each, so a jump crosses files that load and grow around its destination.
# After Sources in review order, so the offsets measured around LongReview.swift stay put.
(fixture / 'Tests').mkdir()
for part in range(1, 6):
    (fixture / f'Tests/Part{part}.swift').write_text(
        ''.join(f'let part{part}Line{line} = {line}\n' for line in range(160))
    )
try:
    subprocess.run(
        ['open', '-g', '-n', '-W', '-a', str(pathlib.Path(binary).parents[2]),
         '--stdout', f'{root}/result.json', '--stderr', f'{root}/probe.log',
         '--args', '--review-run-probe', root, *arguments],
        timeout=120, check=True,
    )
except subprocess.TimeoutExpired:
    print(pathlib.Path(root, 'probe.log').read_text(), file=sys.stderr)
    raise
report = pathlib.Path(root, 'result.json').read_text()
print(report)
if not json.loads(report)['passed']:
    if os.environ.get('RUNNER_TEMP'):
        evidence = pathlib.Path(os.environ['RUNNER_TEMP'], 'bloom-review-probe')
        evidence.mkdir(exist_ok=True)
        for item in pathlib.Path(root).iterdir():
            if item.suffix in {'.png', '.json', '.log'}:
                shutil.copy2(item, evidence / item.name)
    print(pathlib.Path(root, 'probe.log').read_text(), file=sys.stderr)
    raise SystemExit(f'Probe failed; evidence: {root}')
print(f'Probe evidence: {root}')
PY
