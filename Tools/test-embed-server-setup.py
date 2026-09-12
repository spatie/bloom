#!/usr/bin/env python3
import importlib.util
import io
import json
import pathlib
import re
import tarfile
import tempfile
import subprocess
import sys
import unittest

root = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('embed_server_setup', root / 'Tools/embed-server-setup.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
protocol = int(re.search(r'version = (\d+)', (root / 'Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift').read_text())[1])


class PackageTests(unittest.TestCase):
    def archive(self, path, version):
        with tarfile.open(path, 'w:gz') as archive:
            for name, data in [('bin/bloom-server', b'fixture'), ('manifest.json', json.dumps({'protocolVersion': version}).encode())]:
                entry = tarfile.TarInfo('bloom-server-linux-x86_64/' + name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))

    def test_matching_package_and_installer_are_embedded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            archive = path / 'server.tar.gz'
            self.archive(archive, protocol)
            module.embed(path / 'Bloom.app', archive)
            output = path / 'Bloom.app/Contents/Resources/ServerSetup'
            self.assertTrue((output / 'install-bloom-server.py').is_file())
            for name in ('install-bloom-server.py', 'install-bloom-browser.py', 'install-bloom-docker.py', 'install-bloom-swap.py'):
                bundled = (output / name).read_text()
                self.assertTrue(bundled.startswith('#!/usr/bin/env python3\n'))
                self.assertIn('class InstallProcessFailure(', bundled)
                self.assertTrue(bundled.endswith((root / 'Tools' / name).read_text()))
                result = subprocess.run([sys.executable, '-I', str(output / name), '--help'], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / 'server.tar.gz').read_bytes(), archive.read_bytes())
            self.assertEqual(json.loads((output / 'package.json').read_text())['protocolVersion'], protocol)

    def test_wrong_protocol_cannot_be_bundled(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            archive = path / 'server.tar.gz'
            self.archive(archive, protocol - 1)
            with self.assertRaises(ValueError):
                module.embed(path / 'Bloom.app', archive)
            self.assertFalse((path / 'Bloom.app/Contents/Resources/ServerSetup/server.tar.gz').exists())

    def test_development_build_without_package_keeps_advanced_connection_available(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            module.embed(path)
            self.assertTrue((path / 'Contents/Resources/ServerSetup/install-bloom-server.py').exists())
            self.assertFalse((path / 'Contents/Resources/ServerSetup/server.tar.gz').exists())


if __name__ == '__main__':
    unittest.main()
