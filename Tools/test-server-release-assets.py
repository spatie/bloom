#!/usr/bin/env python3
"""Check the published server asset description against the supervisor, with no network or Swift build."""
import hashlib
import importlib.util
import io
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.dont_write_bytecode = True
TOOLS = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('server_release_assets', TOOLS / 'server-release-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


def package(path, manifest, extra=None):
    """A package with the shape Tools/package-linux-server.py produces, and nothing inside worth running."""
    prefix = 'bloom-server-linux-x86_64'
    with tarfile.open(path, 'w:gz') as archive:
        def add(name, data=b'', mode=0o644, kind=tarfile.REGTYPE):
            info = tarfile.TarInfo(prefix + '/' + name if name else prefix)
            info.type, info.mode, info.size = kind, mode, len(data) if kind == tarfile.REGTYPE else 0
            archive.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
        add('', kind=tarfile.DIRTYPE, mode=0o755)
        add('bin', kind=tarfile.DIRTYPE, mode=0o755)
        add('lib', kind=tarfile.DIRTYPE, mode=0o755)
        add('bin/bloom-server', b'#!/bin/sh\n', mode=0o755)
        add('bin/bloom-bridge', b'#!/bin/sh\n', mode=0o755)
        add('manifest.json', json.dumps(manifest).encode())
        for item in extra or []:
            archive.addfile(item)
    return path


def manifest(**changes):
    value = dict(protocolVersion=assets.wire_protocol(), maintenanceProtocolVersion=1, version='1.4.0',
                 architecture='x86_64', glibc='glibc 2.39', swift='Swift version 6.3.3', libraries={})
    value.update(changes)
    return value


def release(archive, tag='v1.4.0', names=None, **changes):
    sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
    listed = [dict(id=41, name=assets.ASSET, size=archive.stat().st_size, digest='sha256:' + sha256),
              dict(id=42, name=assets.CHECKSUM, size=100, digest='sha256:' + 'b' * 64),
              dict(id=43, name=assets.METADATA, size=300, digest='sha256:' + 'c' * 64)]
    value = dict(tag_name=tag, draft=False, prerelease=False,
                 assets=[item for item in listed if names is None or item['name'] in names])
    value.update(changes)
    return value


class DescribeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='bloom-server-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.archive = self.root / assets.ASSET

    def test_sidecars_describe_the_archive_the_supervisor_accepts(self):
        package(self.archive, manifest())
        output = self.root / 'out'
        described = assets.describe(self.archive, 'v1.4.0', output)
        sha256 = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertEqual((output / assets.CHECKSUM).read_text(), f'{sha256}  {assets.ASSET}\n')
        written = json.loads((output / assets.METADATA).read_text())
        self.assertEqual(written, described)
        self.assertEqual(written['version'], '1.4.0')
        self.assertEqual(written['tag'], 'v1.4.0')
        self.assertEqual(written['protocolVersion'], assets.wire_protocol())
        self.assertEqual(written['architecture'], 'x86_64')
        self.assertEqual(written['sha256'], sha256)
        self.assertEqual(written['size'], self.archive.stat().st_size)

    def test_checksum_file_is_what_sha256sum_reads(self):
        tool = ['sha256sum', '-c'] if sys.platform == 'linux' else ['shasum', '-a', '256', '-c']
        package(self.archive, manifest())
        assets.describe(self.archive, 'v1.4.0', self.root)
        result = subprocess.run([*tool, assets.CHECKSUM], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_package_built_for_another_tag_is_refused(self):
        # A rerun that rebuilt from a different ref, or a version left at 0.0.0-dev, would have
        # every supervisor stop at release_version_mismatch after downloading it.
        package(self.archive, manifest(version='0.0.0-dev.abcdef'))
        with self.assertRaisesRegex(assets.AssetError, 'release_version_mismatch'):
            assets.describe(self.archive, 'v1.4.0', self.root)

    def test_incompatible_manifests_are_refused(self):
        for change in (dict(protocolVersion=assets.wire_protocol() - 1), dict(maintenanceProtocolVersion=2),
                       dict(architecture='aarch64')):
            with self.subTest(change=change):
                package(self.archive, manifest(**change))
                with self.assertRaisesRegex(assets.AssetError, 'incompatible_release'):
                    assets.describe(self.archive, 'v1.4.0', self.root / 'out')

    def test_links_inside_the_archive_are_refused(self):
        link = tarfile.TarInfo('bloom-server-linux-x86_64/lib/libFoundation.so')
        link.type, link.linkname = tarfile.SYMTYPE, '/usr/lib/libFoundation.so'
        package(self.archive, manifest(), [link])
        with self.assertRaisesRegex(assets.AssetError, 'unsafe_release'):
            assets.describe(self.archive, 'v1.4.0', self.root)

    def test_the_asset_name_and_tag_are_fixed(self):
        renamed = package(self.root / 'bloom-server.tar.gz', manifest())
        with self.assertRaisesRegex(assets.AssetError, 'only looks for'):
            assets.describe(renamed, 'v1.4.0', self.root)
        package(self.archive, manifest())
        with self.assertRaisesRegex(assets.AssetError, 'not a release tag'):
            assets.describe(self.archive, '1.4.0', self.root)


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='bloom-server-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.archive = package(self.root / assets.ASSET, manifest())
        assets.describe(self.archive, 'v1.4.0', self.root)
        self.description = self.root / assets.METADATA
        # Verification is handed everything it needs. A download attempt, real or through a
        # stub left behind, fails the test rather than reaching GitHub or being skipped.
        original = assets.maintenance.https_open

        def no_network(*arguments, **options):
            raise AssertionError('https_open was called during verification')

        assets.maintenance.https_open = no_network
        self.addCleanup(setattr, assets.maintenance, 'https_open', original)
        self.guard = no_network

    def release(self, **changes):
        value = release(self.archive, **changes)
        for item in value['assets']:
            if item['name'] == assets.METADATA:
                item.update(size=self.description.stat().st_size,
                            digest='sha256:' + hashlib.sha256(self.description.read_bytes()).hexdigest())
        return value

    def rewrite(self, **changes):
        described = json.loads(self.description.read_text())
        described.update(changes)
        self.description.write_text(json.dumps(described, indent=2) + '\n')

    def test_a_published_release_is_offered_with_the_built_digest(self):
        asset, notes = assets.verify(self.archive, self.release(), self.description)
        self.assertEqual(asset['version'], 'v1.4.0')
        self.assertEqual(asset['assetID'], 41)
        self.assertEqual(asset['sha256'], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        self.assertNotIn('incompatible', asset)
        self.assertEqual(notes, [])
        self.assertEqual(assets.maintenance.fetch_json.__name__, 'fetch_json')
        self.assertIs(assets.maintenance.https_open, self.guard)

    def test_the_description_reaches_the_supervisor_without_a_download(self):
        seen = []
        original = assets.maintenance.release_incompatibility

        def recording(metadata, asset, installed_protocol=None, host=None):
            seen.append((metadata, installed_protocol))
            return original(metadata, asset, installed_protocol, host)

        assets.maintenance.release_incompatibility = recording
        self.addCleanup(setattr, assets.maintenance, 'release_incompatibility', original)
        assets.verify(self.archive, self.release(), self.description)
        self.assertEqual(seen, [(json.loads(self.description.read_text()), assets.wire_protocol())])

    def test_an_incompatible_description_fails_with_the_supervisors_reason(self):
        self.rewrite(protocolVersion=assets.wire_protocol() - 1)
        with self.assertRaisesRegex(assets.AssetError, 'refuse this release.*older protocol'):
            assets.verify(self.archive, self.release(), self.description)

    def test_a_newer_wire_protocol_is_still_offered(self):
        # Protocol 15 was the first bump after supervisors shipped, and a rule refusing it would
        # have had this check fail every release that raised BloomWire.version.
        self.rewrite(protocolVersion=assets.wire_protocol() + 1)
        asset, _ = assets.verify(self.archive, self.release(), self.description)
        self.assertNotIn('incompatible', asset)

    def test_a_description_for_another_tag_or_package_is_release_unavailable(self):
        for change in (dict(tag='v1.4.1'), dict(sha256='e' * 64)):
            with self.subTest(change=change):
                assets.describe(self.archive, 'v1.4.0', self.root)
                self.rewrite(**change)
                with self.assertRaisesRegex(assets.AssetError, 'release_unavailable'):
                    assets.verify(self.archive, self.release(), self.description)

    def test_an_uploaded_description_that_is_not_the_built_one_is_refused(self):
        published = self.release()
        published['assets'][2]['digest'] = 'sha256:' + 'f' * 64
        with self.assertRaisesRegex(assets.AssetError, 'not the description that was built'):
            assets.verify(self.archive, published, self.description)

    def test_a_digest_from_another_build_is_refused(self):
        # A release and description that agree with each other, both from a build other than the
        # one bundled into the app: the supervisor would offer it, and only this check notices.
        self.rewrite(sha256='a' * 64)
        published = self.release()
        published['assets'][0]['digest'] = 'sha256:' + 'a' * 64
        with self.assertRaisesRegex(assets.AssetError, 'built package'):
            assets.verify(self.archive, published, self.description)

    def test_a_missing_digest_is_what_the_supervisor_refuses(self):
        published = self.release()
        del published['assets'][0]['digest']
        with self.assertRaisesRegex(assets.AssetError, 'release_unavailable'):
            assets.verify(self.archive, published, self.description)

    def test_missing_assets_are_named(self):
        with self.assertRaisesRegex(assets.AssetError, 'release_unavailable'):
            assets.verify(self.archive, self.release(names={assets.CHECKSUM, assets.METADATA}), self.description)
        with self.assertRaisesRegex(assets.AssetError, re.escape(assets.METADATA)):
            assets.verify(self.archive, self.release(names={assets.ASSET, assets.CHECKSUM}), self.description)

    def test_a_prerelease_verifies_and_says_it_is_not_offered(self):
        _, notes = assets.verify(self.archive, self.release(prerelease=True), self.description)
        self.assertTrue(notes)


class WorkflowTests(unittest.TestCase):
    """The workflows are YAML nothing else here reads, so the names they publish are pinned by hand."""

    def contains(self, workflow, *needles):
        text = (TOOLS.parent / '.github/workflows' / workflow).read_text()
        for needle in needles:
            self.assertTrue(needle in text, f'{workflow} no longer contains {needle!r}')
        return text

    def test_the_release_publishes_a_release_build_and_both_sidecars(self):
        text = self.contains('release.yml', 'swift build -c release --product bloom-server',
                             'swift build -c release --product bloom-bridge', assets.ASSET, assets.CHECKSUM,
                             assets.METADATA, 'server-release-assets.py describe', 'server-release-assets.py verify')
        self.assertFalse('.build/debug/bloom-server' in text, 'The release packages a debug server again')

    def test_pull_requests_describe_the_package_they_build(self):
        self.contains('server.yml', 'server-release-assets.py describe', assets.CHECKSUM)

    def test_a_release_build_can_be_checked_before_tagging(self):
        self.contains('server.yml', 'release_build', 'swift build -c release --product bloom-server',
                      'swift build -c release --product bloom-bridge')


if __name__ == '__main__':
    unittest.main()
