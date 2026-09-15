#!/usr/bin/env python3
"""Root integration rules exercised only against temporary, current-user fixtures."""
from contextlib import closing
import importlib.util
import json
import os
import pathlib
import sqlite3
import tempfile
import types
import unittest
from unittest import mock

from bloom_maintenance_install import MAINTENANCE_PROTOCOL_VERSION, MaintenanceInstallation, MaintenanceInstallFailure
from bloom_install_process import standalone_installer_source
from bloom_wire import wire_protocol

# What CI's package manifest says today, read from BloomWire in the Swift rather than written here.
WIRE = wire_protocol()


class MaintenanceInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.args = types.SimpleNamespace(service_name='bloom-server', service_home=self.root / 'home',
            data_dir=self.root / 'data', runtime_socket=self.root / 'runtime.sock', maintenance_key_sha256='a' * 64)
        self.account = types.SimpleNamespace(pw_uid=1234, pw_gid=1235)
        self.installation = MaintenanceInstallation(self.args, self.protect,
            base=self.root / 'state', launcher=self.root / 'libexec/bloom-maintenance.py',
            runtime=self.root / 'run', owner_uid=os.getuid())
        self.bundle = self.root / 'bundle'
        (self.bundle / 'bin').mkdir(parents=True)
        (self.bundle / 'lib').mkdir()
        (self.bundle / 'licences').mkdir()
        (self.bundle / 'bin/bloom-server').write_text('binary')
        (self.bundle / 'bin/bloom-server').chmod(0o755)
        (self.bundle / 'manifest.json').write_text(json.dumps(dict(architecture='x86_64', version='test-1', protocolVersion=WIRE, maintenanceProtocolVersion=1)))

    def protect(self, path):
        # Keep tests independent of /tmp ownership while enforcing every fixture-owned ancestor.
        path = pathlib.Path(path)
        self.assertTrue(path.is_relative_to(self.root))
        for item in [path, *path.parents]:
            if item == self.root:
                break
            if item.is_symlink():
                raise MaintenanceInstallFailure('untrusted_directory', 'Symlink rejected', 'Repair path')
            if item.exists() and (item.stat().st_uid != os.getuid() or item.stat().st_mode & 0o022):
                raise MaintenanceInstallFailure('untrusted_directory', 'Writable path rejected', 'Repair path')

    def publish(self):
        self.installation.publish(self.bundle, 'b' * 64, self.account, '# Trusted supervisor\n', '# Trusted Docker adapter\n', '# Trusted output redactor\n')

    def database(self, phase):
        self.installation.directory(self.installation.state)
        path = self.installation.state / 'maintenance.sqlite'
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('CREATE TABLE jobs (state TEXT)')
            db.execute('INSERT INTO jobs VALUES (?)', (phase,))
        path.chmod(0o600)

    def test_fresh_configuration_uses_protected_release_and_digest_only(self):
        self.publish()
        config = json.loads(self.installation.config_path.read_text())
        self.assertEqual(config['uid'], 1234)
        self.assertEqual(config['gid'], 1235)
        self.assertEqual(config['access_token_sha256'], 'a' * 64)
        self.assertEqual(config['release_repository'], 'spatie/bloom')
        # A recorded wire protocol goes stale at the first supervised update; the supervisor reads
        # the installed release's manifest instead.
        self.assertNotIn('protocol_version', config)
        self.assertTrue(pathlib.Path(config['executable']).is_relative_to(self.installation.releases))
        self.assertTrue(self.installation.key_accepted)
        self.assertEqual(self.installation.config_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.installation.current_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.installation.launcher.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.installation.docker_module.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.installation.docker_module.read_text(), '# Trusted Docker adapter\n')
        self.assertEqual(self.installation.process_module.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.installation.process_module.read_text(), '# Trusted output redactor\n')
        self.assertEqual(pathlib.Path(config['executable']).stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.installation.state.stat().st_mode & 0o777, 0o755)

    def test_package_for_the_current_wire_protocol_is_accepted(self):
        # The release blocker: a package built for protocol 15 was refused at Verify package as
        # maintenance_package_required, because this installer required exactly 14.
        self.assertEqual(self.installation.validate_bundle(self.bundle), 'test-1')

    def test_a_later_wire_protocol_does_not_block_supervised_installation(self):
        for wire in (WIRE + 1, WIRE + 20):
            with self.subTest(wire=wire):
                (self.bundle / 'manifest.json').write_text(json.dumps(dict(architecture='x86_64', version='test-1',
                    protocolVersion=wire, maintenanceProtocolVersion=MAINTENANCE_PROTOCOL_VERSION)))
                self.assertEqual(self.installation.validate_bundle(self.bundle), 'test-1')

    def test_package_needs_this_maintenance_protocol_and_a_real_wire_protocol(self):
        for changes in (dict(maintenanceProtocolVersion=MAINTENANCE_PROTOCOL_VERSION + 1), dict(maintenanceProtocolVersion=None),
                        dict(protocolVersion=None), dict(protocolVersion=str(WIRE)), dict(protocolVersion=0), dict(protocolVersion=True)):
            with self.subTest(changes=changes):
                manifest = dict(architecture='x86_64', version='test-1', protocolVersion=WIRE,
                                maintenanceProtocolVersion=MAINTENANCE_PROTOCOL_VERSION)
                manifest.update(changes)
                (self.bundle / 'manifest.json').write_text(json.dumps(manifest))
                with self.assertRaises(MaintenanceInstallFailure) as refused:
                    self.installation.validate_bundle(self.bundle)
                self.assertEqual(refused.exception.code, 'maintenance_package_required')

    def test_installer_supervisor_and_packager_agree_on_the_maintenance_protocol(self):
        spec = importlib.util.spec_from_file_location('bloom_maintenance_agreement', pathlib.Path(__file__).with_name('bloom-maintenance.py'))
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        self.assertEqual(supervisor.MAINTENANCE_PROTOCOL_VERSION, MAINTENANCE_PROTOCOL_VERSION)
        packager = pathlib.Path(__file__).with_name('package-linux-server.py').read_text()
        self.assertIn('"maintenanceProtocolVersion": MAINTENANCE_PROTOCOL_VERSION', packager)

    def test_a_package_the_installer_accepts_is_one_the_supervisor_installs(self):
        # The same manifest through both gates, at today's protocol and the next one, so the two
        # cannot drift apart again with the tests of each pinned to the same stale number.
        spec = importlib.util.spec_from_file_location('bloom_maintenance_gates', pathlib.Path(__file__).with_name('bloom-maintenance.py'))
        supervisor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(supervisor)
        for wire in (WIRE, WIRE + 1):
            with self.subTest(wire=wire):
                (self.bundle / 'manifest.json').write_text(json.dumps(dict(architecture='x86_64', version='test-1',
                    protocolVersion=wire, maintenanceProtocolVersion=MAINTENANCE_PROTOCOL_VERSION)))
                self.installation.validate_bundle(self.bundle)
                self.assertEqual(supervisor.validate_release_manifest(self.bundle, WIRE), self.bundle / 'bin/bloom-server')
                metadata = dict(name=supervisor.RELEASE_PACKAGE, tag='v2.0.0', sha256='c' * 64, protocolVersion=wire,
                                maintenanceProtocolVersion=MAINTENANCE_PROTOCOL_VERSION, architecture='x86_64')
                self.assertIsNone(supervisor.release_incompatibility(metadata, dict(version='v2.0.0', sha256='c' * 64), WIRE, host=''))

    def test_existing_digest_is_not_rotated(self):
        self.publish()
        original = self.installation.config_path.read_bytes()
        self.args.maintenance_key_sha256 = 'c' * 64
        with self.assertRaisesRegex(MaintenanceInstallFailure, 'another maintenance access key'):
            self.publish()
        self.assertEqual(self.installation.config_path.read_bytes(), original)

    def test_administrator_replacement_rewrites_only_the_digest(self):
        self.publish()
        before = json.loads(self.installation.config_path.read_text())
        self.args.maintenance_key_sha256 = 'd' * 64
        self.installation.key_accepted = False
        self.installation.replace_key()
        after = json.loads(self.installation.config_path.read_text())
        self.assertTrue(self.installation.key_accepted)
        self.assertEqual(after['access_token_sha256'], 'd' * 64)
        self.assertEqual({key: value for key, value in after.items() if key != 'access_token_sha256'},
                         {key: value for key, value in before.items() if key != 'access_token_sha256'})
        self.assertEqual(self.installation.config_path.stat().st_mode & 0o777, 0o600)
        self.installation.replace_key()
        self.assertTrue(self.installation.key_accepted)

    def test_replacement_needs_an_installed_supervisor_and_a_valid_digest(self):
        self.args.maintenance_key_sha256 = 'd' * 64
        with self.assertRaises(MaintenanceInstallFailure) as missing:
            self.installation.replace_key()
        self.assertEqual(missing.exception.code, 'maintenance_unavailable')
        self.assertFalse(self.installation.config_path.exists())
        self.publish()
        original = self.installation.config_path.read_bytes()
        for digest in (None, 'raw-private-key', 'D' * 64):
            self.args.maintenance_key_sha256 = digest
            with self.assertRaises(MaintenanceInstallFailure) as invalid:
                self.installation.replace_key()
            self.assertEqual(invalid.exception.code, 'invalid_maintenance_key')
        self.assertEqual(self.installation.config_path.read_bytes(), original)

    def test_existing_config_enables_maintenance_without_new_credential(self):
        self.publish()
        self.args.maintenance_key_sha256 = None
        self.assertTrue(self.installation.enabled)
        self.publish()
        self.assertFalse(self.installation.key_accepted)
        self.assertEqual(json.loads(self.installation.config_path.read_text())['access_token_sha256'], 'a' * 64)

    def test_same_digest_is_accepted_on_retry(self):
        self.publish()
        self.publish()
        self.assertTrue(self.installation.key_accepted)

    def test_unsupported_package_does_not_publish_any_root_files(self):
        (self.bundle / 'manifest.json').write_text(json.dumps(dict(version='old', protocolVersion=WIRE)))
        with self.assertRaises(MaintenanceInstallFailure):
            self.publish()
        self.assertFalse(self.installation.launcher.exists())
        self.assertFalse(self.installation.config_path.exists())

    def test_active_jobs_and_interrupted_jobs_block_manual_repair(self):
        for phase in ('queued', 'waiting', 'downloading', 'installing', 'restarting', 'verifying', 'interrupted'):
            with self.subTest(phase=phase):
                self.database(phase)
                with self.assertRaisesRegex(MaintenanceInstallFailure, 'still active'):
                    self.installation.ensure_idle()
                (self.installation.state / 'maintenance.sqlite').unlink()

    def test_terminal_jobs_allow_manual_repair(self):
        for phase in ('succeeded', 'failed', 'rolledBack', 'cancelled'):
            self.database(phase)
            self.installation.ensure_idle()
            (self.installation.state / 'maintenance.sqlite').unlink()

    def test_transaction_prevents_replacing_runtime_or_rollback_snapshot(self):
        self.installation.directory(self.installation.state)
        marker = self.installation.state / 'transaction.json'
        marker.write_text('{}'); marker.chmod(0o600)
        with self.assertRaisesRegex(MaintenanceInstallFailure, 'rollback still needs recovery'):
            self.publish()
        self.assertFalse(self.installation.launcher.exists())
        self.assertEqual(marker.read_text(), '{}')

    def test_invalid_durable_database_is_not_treated_as_idle(self):
        self.installation.directory(self.installation.state)
        path = self.installation.state / 'maintenance.sqlite'
        path.write_bytes(b'broken'); path.chmod(0o600)
        with self.assertRaisesRegex(MaintenanceInstallFailure, 'could not be checked'):
            self.installation.ensure_idle()

    def test_changed_installation_paths_are_refused(self):
        self.publish()
        config = json.loads(self.installation.config_path.read_text())
        config['data_dir'] = '/other-user/data'
        self.installation.config_path.write_text(json.dumps(config))
        with self.assertRaisesRegex(MaintenanceInstallFailure, 'does not match'):
            self.installation.ensure_idle()

    def test_config_permissions_and_symlink_parents_are_refused(self):
        self.publish()
        self.installation.config_path.chmod(0o644)
        with self.assertRaisesRegex(MaintenanceInstallFailure, 'private root-owned'):
            self.installation.existing_config()
        self.installation.config_path.chmod(0o600)
        self.installation.config_path.unlink()
        self.installation.config_path.symlink_to(self.bundle / 'manifest.json')
        with self.assertRaises(MaintenanceInstallFailure):
            self.installation.existing_config()

    def test_docker_module_symlink_is_rejected_without_changing_target(self):
        self.installation.directory(self.installation.launcher.parent)
        target = self.root / 'unrelated.py'; target.write_text('keep')
        self.installation.docker_module.symlink_to(target)
        with self.assertRaises(MaintenanceInstallFailure):
            self.publish()
        self.assertEqual(target.read_text(), 'keep')

    def test_output_module_symlink_is_rejected_without_changing_target(self):
        self.installation.directory(self.installation.launcher.parent)
        target = self.root / 'user-file'
        target.write_text('untouched')
        self.installation.process_module.symlink_to(target)
        with self.assertRaises(MaintenanceInstallFailure):
            self.publish()
        self.assertEqual(target.read_text(), 'untouched')

    def test_output_module_source_is_required_before_any_publication(self):
        with self.assertRaises(MaintenanceInstallFailure):
            self.installation.publish(self.bundle, 'b' * 64, self.account, '# supervisor', '# docker', '')
        self.assertFalse(self.installation.launcher.exists())

    def test_docker_module_source_is_required_before_any_publication(self):
        with self.assertRaises(MaintenanceInstallFailure):
            self.installation.publish(self.bundle, 'b' * 64, self.account, '# Trusted supervisor', '', '# Trusted output redactor')
        self.assertFalse(self.installation.config_path.exists())
        self.assertFalse(self.installation.launcher.exists())

    def test_bundle_symlink_is_not_followed_as_root(self):
        secret = self.root / 'secret'; secret.write_text('private')
        (self.bundle / 'lib/secret').symlink_to(secret)
        with self.assertRaisesRegex(MaintenanceInstallFailure, 'regular-file bundle'):
            self.publish()
        self.assertFalse((self.installation.releases / ('b' * 64)).exists())

    def test_rollback_restores_config_current_and_previous_supervisor(self):
        self.publish()
        before = {path: path.read_bytes() for path in (self.installation.config_path, self.installation.current_path, self.installation.launcher, self.installation.docker_module, self.installation.process_module)}
        (self.bundle / 'manifest.json').write_text(json.dumps(dict(version='test-2', protocolVersion=WIRE, maintenanceProtocolVersion=1)))
        self.installation.publish(self.bundle, 'd' * 64, self.account, '# Updated supervisor\n', '# Updated Docker adapter\n', '# Updated output redactor\n')
        self.installation.rollback()
        for path, value in before.items():
            self.assertEqual(path.read_bytes(), value)
        self.assertFalse(self.installation.key_accepted)

    def test_partial_publish_failure_can_restore_old_configuration(self):
        self.publish()
        before = self.installation.current_path.read_bytes()
        write = self.installation.atomic_write
        def fail_current(path, data, mode=0o600):
            if path == self.installation.current_path:
                raise OSError('simulated disk failure')
            return write(path, data, mode)
        with mock.patch.object(self.installation, 'atomic_write', side_effect=fail_current), self.assertRaises(OSError):
            self.installation.publish(self.bundle, 'd' * 64, self.account, '# New supervisor\n', '# Updated Docker adapter\n', '# Updated output redactor\n')
        self.installation.rollback()
        self.assertEqual(self.installation.current_path.read_bytes(), before)

    def test_new_failed_install_removes_only_its_published_metadata(self):
        self.publish()
        self.installation.rollback()
        self.assertFalse(self.installation.config_path.exists())
        self.assertFalse(self.installation.current_path.exists())
        self.assertFalse(self.installation.launcher.exists())
        self.assertFalse(self.installation.docker_module.exists())
        self.assertFalse(self.installation.process_module.exists())
        self.assertTrue((self.installation.releases / ('b' * 64)).is_dir())

    def test_publish_records_the_release_it_replaced_and_a_repair_keeps_it(self):
        self.publish()
        first = json.loads(self.installation.current_path.read_text())
        self.assertNotIn('previous', first)
        self.installation.publish(self.bundle, 'd' * 64, self.account, '# Trusted supervisor\n', '# Trusted Docker adapter\n', '# Trusted output redactor\n')
        self.assertEqual(json.loads(self.installation.current_path.read_text())['previous'], first['executable'])
        self.installation.publish(self.bundle, 'd' * 64, self.account, '# Trusted supervisor\n', '# Trusted Docker adapter\n', '# Trusted output redactor\n')
        self.assertEqual(json.loads(self.installation.current_path.read_text())['previous'], first['executable'])

    def test_retirement_keeps_running_and_replaced_releases_and_waits_for_idle(self):
        self.publish()
        stale = self.installation.releases / ('c' * 64)
        (stale / 'bin').mkdir(parents=True)
        self.installation.publish(self.bundle, 'd' * 64, self.account, '# Trusted supervisor\n', '# Trusted Docker adapter\n', '# Trusted output redactor\n')
        marker = self.installation.state / 'transaction.json'
        marker.write_text('{}'); marker.chmod(0o600)
        self.assertEqual(self.installation.retire_releases(), [])
        marker.unlink()
        self.database('installing')
        self.assertEqual(self.installation.retire_releases(), [])
        self.assertTrue(stale.is_dir())
        (self.installation.state / 'maintenance.sqlite').unlink()
        self.assertEqual(self.installation.retire_releases(), ['c' * 64])
        self.assertEqual(sorted(path.name for path in self.installation.releases.iterdir()), ['b' * 64, 'd' * 64])

    def test_supervised_unit_recreates_runtime_directory_after_reboot(self):
        unit = self.installation.unit_contents()
        self.assertIn('User=root\nGroup=root\n', unit)
        self.assertIn('NoNewPrivileges=true', unit)
        self.assertIn('RuntimeDirectory=bloom-maintenance\nRuntimeDirectoryMode=0755', unit)
        self.assertIn('/usr/bin/python3 ', unit)
        self.assertNotIn(self.args.maintenance_key_sha256, unit)

    def test_standalone_installer_contains_trusted_source_not_remote_download(self):
        path = pathlib.Path(__file__).with_name('install-bloom-server.py')
        source = standalone_installer_source(path)
        self.assertIn('class MaintenanceInstallation:', source)
        self.assertIn('MAINTENANCE_SUPERVISOR_SOURCE = ', source)
        self.assertIn('MAINTENANCE_DOCKER_SOURCE = ', source)
        namespace = {'__name__': 'test_embedded'}
        exec(compile(source, '<embedded-installer>', 'exec'), namespace)
        self.assertEqual(namespace['maintenance_source'](), path.with_name('bloom-maintenance.py').read_text())
        self.assertEqual(namespace['maintenance_docker_source'](), path.with_name('bloom_maintenance_docker.py').read_text())
        self.assertEqual(namespace['maintenance_process_source'](), path.with_name('bloom_install_process.py').read_text())
        self.assertTrue(callable(namespace['retire_releases']))
        self.assertEqual(source, standalone_installer_source(path, source))


if __name__ == '__main__':
    unittest.main()
