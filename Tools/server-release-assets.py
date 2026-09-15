#!/usr/bin/env python3
"""Describe and check the Linux server assets a tagged release publishes for the supervisor.

The maintenance supervisor installed on a server is the reader this exists for, so nothing
here restates its rules. It imports `bloom-maintenance.py` and runs the archive through the
same `extract_release` and `release_asset` an update runs through. A package the release
workflow accepts is therefore one every current supervisor would accept, and a change to the
supervisor's rules changes this check on the same commit rather than on the next failed update.

    server-release-assets.py describe <archive> --tag v1.4.0 --output-dir <dir>
    server-release-assets.py verify <archive> --release <github-release.json>

`describe` writes the two sidecars published beside the tarball. The supervisor reads neither:
it trusts the digest GitHub computes for the uploaded asset. They exist for people and for the
manual installer, which takes `--sha256`, so a server can be checked without the GitHub API.

`verify` reads the release JSON after upload (`gh api repos/spatie/bloom/releases/tags/<tag>`)
and confirms GitHub's digest and size are those of the file that was built, which is the one
bundled into the Mac app.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import sys
import tempfile

sys.dont_write_bytecode = True
TOOLS = pathlib.Path(__file__).resolve().parent
ROOT = TOOLS.parent
ASSET = 'bloom-server-linux-x86_64.tar.gz'
CHECKSUM = ASSET + '.sha256'
METADATA = 'bloom-server-linux-x86_64.json'

sys.path.insert(0, str(TOOLS))
_spec = importlib.util.spec_from_file_location('bloom_maintenance', TOOLS / 'bloom-maintenance.py')
maintenance = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(maintenance)


class AssetError(Exception):
    pass


def wire_protocol():
    source = (ROOT / 'Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift').read_text()
    return int(re.search(r'version = (\d+)', source)[1])


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def describe(archive, tag, output_dir):
    if archive.name != ASSET:
        raise AssetError(f'The supervisor only looks for an asset named {ASSET}, not {archive.name}.')
    if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', tag) is None:
        raise AssetError(f'{tag} is not a release tag like v1.4.0.')
    protocol = wire_protocol()
    with tempfile.TemporaryDirectory(prefix='bloom-server-release-') as directory:
        try:
            executable = maintenance.extract_release(archive, directory, protocol, tag)
        except maintenance.MaintenanceError as error:
            raise AssetError(f'The supervisor would refuse this package ({error.code}): {error}') from None
        manifest = json.loads((executable.parent.parent / 'manifest.json').read_bytes())
    sha256 = digest(archive)
    metadata = {
        'name': ASSET,
        'tag': tag,
        'version': manifest['version'],
        'protocolVersion': manifest['protocolVersion'],
        'maintenanceProtocolVersion': manifest['maintenanceProtocolVersion'],
        'architecture': manifest['architecture'],
        'glibc': manifest.get('glibc'),
        'sha256': sha256,
        'size': archive.stat().st_size,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    # The format `sha256sum -c` and `shasum -a 256 -c` read, run beside the tarball.
    (output_dir / CHECKSUM).write_text(f'{sha256}  {ASSET}\n')
    (output_dir / METADATA).write_text(json.dumps(metadata, indent=2) + '\n')
    return metadata


def verify(archive, release):
    sha256 = digest(archive)
    offered = dict(release, draft=False, prerelease=False)
    original = maintenance.fetch_json
    # The single replaced operation is the HTTPS fetch, so the asset selection, the digest format
    # and the tag rules below are the supervisor's own.
    maintenance.fetch_json = lambda url, maximum=None: offered
    try:
        asset = maintenance.release_asset({'release_repository': 'spatie/bloom'})
    except maintenance.MaintenanceError as error:
        raise AssetError(f'The supervisor would not offer this release ({error.code}): {error}') from None
    finally:
        maintenance.fetch_json = original
    if asset['sha256'] != sha256:
        raise AssetError(f'GitHub publishes sha256:{asset["sha256"]} but the built package is sha256:{sha256}.')
    uploaded = next(item for item in release['assets'] if item.get('name') == ASSET)
    if uploaded.get('size') != archive.stat().st_size:
        raise AssetError('GitHub reports a different size for the server package than the built file.')
    names = {item.get('name') for item in release['assets']}
    missing = sorted({CHECKSUM, METADATA} - names)
    if missing:
        raise AssetError('The release is missing ' + ', '.join(missing) + '.')
    notes = []
    if release.get('draft') or release.get('prerelease'):
        notes.append('This release is a draft or prerelease, so supervisors are not offered it.')
    return asset, notes


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    described = commands.add_parser('describe')
    described.add_argument('archive', type=pathlib.Path)
    described.add_argument('--tag', required=True)
    described.add_argument('--output-dir', type=pathlib.Path, required=True)
    verified = commands.add_parser('verify')
    verified.add_argument('archive', type=pathlib.Path)
    verified.add_argument('--release', type=pathlib.Path, required=True)
    options = parser.parse_args(arguments)
    try:
        if options.command == 'describe':
            print(json.dumps(describe(options.archive, options.tag, options.output_dir), indent=2))
        else:
            asset, notes = verify(options.archive, json.loads(options.release.read_text()))
            print(f'{ASSET} for {asset["version"]} is asset {asset["assetID"]}, sha256:{asset["sha256"]}')
            for note in notes:
                print(note)
    except AssetError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
