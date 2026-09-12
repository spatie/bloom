#!/usr/bin/env python3
"""Compile the native fixture from an existing debug build, without installing an app."""
import os
import pathlib
import platform
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[3]
fixture = pathlib.Path(os.environ['BLOOM_HTTPS_FIXTURE']).resolve()
build = (root / '.build/debug').resolve()
arguments = [
    'swiftc', '-parse-as-library', '-swift-version', '6',
    '-target', platform.machine() + '-apple-macosx26.0', '-I', str(build / 'Modules'),
]
for module in ['AppAuth', 'AppAuthCore']:
    arguments += [
        '-Xcc', '-fmodule-map-file=' + str(build / (module + '.build/module.modulemap')),
        '-I', str(root / '.build/checkouts/AppAuth-iOS/Sources' / module),
    ]
arguments += [
    str(root / 'Tests/fixtures/https/AuthHarness.swift'),
    str(root / 'Sources/Bloom/System/ServerAuthentication.swift'),
]
for module in ['BloomCore', 'AppAuth', 'AppAuthCore']:
    arguments += [str(path) for path in (build / (module + '.build')).rglob('*.o')]
arguments += ['-o', str(fixture / 'auth-harness')]
result = subprocess.run(arguments, capture_output=True, text=True, cwd=root)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
