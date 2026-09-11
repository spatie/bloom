#!/usr/bin/env python3
"""Embed the installer and an optional trusted Linux package before the app is signed."""
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tarfile
from bloom_install_process import standalone_installer_source


def embed(bundle, archive=None):
    root = pathlib.Path(__file__).resolve().parent.parent
    destination = bundle / 'Contents/Resources/ServerSetup'
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('install-bloom-server.py', 'install-bloom-browser.py', 'install-bloom-docker.py', 'install-bloom-swap.py'):
        (destination / name).write_text(standalone_installer_source(root / 'Tools' / name))
    if archive is None:
        return
    if not archive.is_file() or archive.stat().st_size > 256 * 1024 * 1024:
        raise ValueError('A Linux server archive up to 256 MiB is required')
    with tarfile.open(archive, 'r:gz') as package:
        names = set(package.getnames())
        if 'bloom-server-linux-x86_64/bin/bloom-server' not in names:
            raise ValueError('The archive is not a Bloom Linux x86_64 package')
        metadata = json.load(package.extractfile('bloom-server-linux-x86_64/manifest.json'))
    protocol = int(re.search(r'version = (\d+)', (root / 'Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift').read_text())[1])
    if metadata.get('protocolVersion') != protocol:
        raise ValueError('The packaged server protocol does not match this app')
    shutil.copy2(archive, destination / 'server.tar.gz')
    (destination / 'package.json').write_text(json.dumps({
        'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'protocolVersion': protocol,
    }) + '\n')


if __name__ == '__main__':
    value = os.environ.get('BLOOM_LINUX_SERVER_ARCHIVE')
    embed(pathlib.Path(sys.argv[1]), pathlib.Path(value) if value else None)
