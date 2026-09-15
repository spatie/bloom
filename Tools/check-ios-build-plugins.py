#!/usr/bin/env python3
"""Only the reviewed, pinned SwiftTerm metadata generator may bypass Xcode's interactive trust UI."""
import hashlib
import pathlib
import re
import subprocess
import sys

checkouts = pathlib.Path(sys.argv[1])
allowed = checkouts / 'SwiftTerm'
revision = '464df5207fc2432e16c9a23abe538187196daf5f'
files = {
    'Plugins/SwiftTermBuildInfoPlugin/plugin.swift': '5c964b172be92b05a13d4343555713c76dfa3489dcc137b77750cd4ca6a1ec3b',
    'Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift': '58462ea930f250f0b4d95bef52857e71599bec48e14120bf27c36ae84f53511b',
}
for manifest in checkouts.glob('*/Package*.swift'):
    if re.search(r'capability\s*:\s*\.buildTool\s*\(', manifest.read_text()) and manifest.parent != allowed:
        raise SystemExit(f'Review the build plugin in {manifest.parent.name} before enabling it for iOS builds.')
actual = subprocess.check_output(['git', '-C', str(allowed), 'rev-parse', 'HEAD'], text=True).strip()
if actual != revision:
    raise SystemExit('SwiftTerm changed. Review its build plugin before updating the trusted revision.')
if subprocess.check_output(['git', '-C', str(allowed), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
    raise SystemExit('The SwiftTerm checkout has tracked changes. Restore the reviewed dependency before building.')
for name, digest in files.items():
    source = allowed / name
    if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'The reviewed build plugin changed: {name}')
    if set(source.parent.rglob('*.swift')) != {source}:
        raise SystemExit(f'Unexpected Swift sources in reviewed build tool: {source.parent}')
print('Verified SwiftTerm 1.19.0 build metadata plugin. No global Xcode trust setting is changed.')
