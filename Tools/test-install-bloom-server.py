#!/usr/bin/env python3
"""Exercise installer validation and rollback with temporary files and fake system services."""

import base64
from contextlib import closing
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import pwd
import sqlite3
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("installer", pathlib.Path(__file__).with_name("install-bloom-server.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()

    def assert_error(self, code, action):
        with self.assertRaises(installer.InstallError) as error:
            action()
        self.assertEqual(error.exception.code, code)

    def package(self, additions=None):
        path = self.root / "package.tar.gz"
        prefix = "bloom-server-linux-x86_64/"
        entries = [(prefix + "bin/bloom-server", b"#!/bin/sh\nexit 0\n", 0o755),
                   (prefix + "manifest.json", b'{"architecture":"x86_64"}', 0o644)]
        with tarfile.open(path, "w:gz") as archive:
            for directory in ("lib", "licences"):
                item = tarfile.TarInfo(prefix + directory)
                item.type = tarfile.DIRTYPE
                archive.addfile(item)
            for name, content, mode in entries:
                item = tarfile.TarInfo(name)
                item.size, item.mode = len(content), mode
                archive.addfile(item, io.BytesIO(content))
            for item in additions or []:
                archive.addfile(item)
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def extract(self, additions=None):
        package, checksum = self.package(additions)
        destination = self.root / "extract"
        destination.mkdir()
        return installer.extract_package(package, destination, checksum)

    def database(self, state="idle", setup="succeeded", queued=False):
        with closing(sqlite3.connect(self.root / "server.sqlite")) as database, database:
            database.executescript("CREATE TABLE sessions (state TEXT); CREATE TABLE workspaces (setup_state TEXT); CREATE TABLE deliveries (delivered_at REAL);")
            database.execute("INSERT INTO sessions VALUES (?)", (state,))
            database.execute("INSERT INTO workspaces VALUES (?)", (setup,))
            if queued:
                database.execute("INSERT INTO deliveries VALUES (NULL)")

    def key(self):
        raw = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + b"a" * 32
        return "ssh-ed25519 " + base64.b64encode(raw).decode()

    def test_regular_package_extracts_without_special_permissions(self):
        bundle = self.extract()
        self.assertEqual((bundle / "bin/bloom-server").stat().st_mode & 0o7777, 0o755)
        self.assertTrue((bundle / "lib").is_dir())

    def test_package_is_readable_under_private_installer_umask(self):
        previous = os.umask(0o077)
        try:
            bundle = self.extract()
        finally:
            os.umask(previous)
        self.assertEqual(bundle.stat().st_mode & 0o777, 0o755)
        self.assertEqual((bundle / "bin").stat().st_mode & 0o777, 0o755)
        self.assertEqual((bundle / "lib").stat().st_mode & 0o777, 0o755)

    def test_wrong_checksum_rejects_before_extracting(self):
        package, _ = self.package()
        destination = self.root / "extract"
        destination.mkdir()
        self.assert_error("checksum_mismatch", lambda: installer.extract_package(package, destination, "0" * 64))
        self.assertFalse((destination / "bloom-server-linux-x86_64").exists())

    def test_missing_checksum_is_actionable(self):
        self.assert_error("invalid_checksum", lambda: installer.extract_package(self.root, self.root, None))

    def test_traversal_is_rejected(self):
        item = tarfile.TarInfo("bloom-server-linux-x86_64/../../outside")
        self.assert_error("unsafe_package", lambda: self.extract([item]))
        self.assertFalse((self.root / "outside").exists())

    def test_absolute_path_is_rejected(self):
        self.assert_error("unsafe_package", lambda: self.extract([tarfile.TarInfo("/tmp/bloom-escape")]))

    def test_symbolic_link_is_rejected(self):
        item = tarfile.TarInfo("bloom-server-linux-x86_64/lib/link")
        item.type, item.linkname = tarfile.SYMTYPE, "/etc/passwd"
        self.assert_error("unsafe_package", lambda: self.extract([item]))

    def test_hard_link_is_rejected(self):
        item = tarfile.TarInfo("bloom-server-linux-x86_64/lib/link")
        item.type, item.linkname = tarfile.LNKTYPE, "bloom-server-linux-x86_64/bin/bloom-server"
        self.assert_error("unsafe_package", lambda: self.extract([item]))

    def test_device_is_rejected(self):
        item = tarfile.TarInfo("bloom-server-linux-x86_64/lib/device")
        item.type = tarfile.CHRTYPE
        self.assert_error("unsafe_package", lambda: self.extract([item]))

    def test_duplicate_entry_is_rejected(self):
        self.assert_error("unsafe_package", lambda: self.extract([tarfile.TarInfo("bloom-server-linux-x86_64/manifest.json")]))

    def test_wrong_bundle_root_is_rejected(self):
        self.assert_error("unsafe_package", lambda: self.extract([tarfile.TarInfo("different/root")]))

    def test_no_database_means_no_active_work(self):
        self.assertFalse(installer.active_work(self.root))

    def test_idle_database_does_not_block(self):
        self.database()
        self.assertFalse(installer.active_work(self.root))

    def test_running_agent_blocks(self):
        self.database(state="running")
        self.assertTrue(installer.active_work(self.root))

    def test_waiting_approval_blocks(self):
        self.database(state="waiting")
        self.assertTrue(installer.active_work(self.root))

    def test_unknown_agent_state_blocks(self):
        self.database(state="future-state")
        self.assertTrue(installer.active_work(self.root))

    def test_pending_delivery_blocks(self):
        self.database(queued=True)
        self.assertTrue(installer.active_work(self.root))

    def test_running_setup_blocks(self):
        self.database(setup="running")
        self.assertTrue(installer.active_work(self.root))

    def test_corrupt_database_is_not_considered_idle(self):
        (self.root / "server.sqlite").write_text("secret-corrupt-data")
        self.assert_error("database_unavailable", lambda: installer.active_work(self.root))

    def test_unknown_schema_is_not_considered_idle(self):
        with closing(sqlite3.connect(self.root / "server.sqlite")) as database, database:
            database.execute("CREATE TABLE unrelated (id TEXT)")
        self.assert_error("database_unavailable", lambda: installer.active_work(self.root))

    def test_key_rejects_options_and_multiple_lines(self):
        path = self.root / "key"
        path.write_text('command="secret" ' + self.key())
        self.assert_error("invalid_public_key", lambda: installer.public_key(path))
        path.write_text(self.key() + "\n" + self.key())
        self.assert_error("invalid_public_key", lambda: installer.public_key(path))

    def test_key_accepts_the_comment_generated_by_the_wizard(self):
        path = self.root / "client.pub"
        path.write_text(self.key() + " Bloom server client\n")
        self.assertEqual(installer.public_key(path), self.key())

    def test_key_validates_wire_format(self):
        path = self.root / "key"
        path.write_text("ssh-ed25519 " + base64.b64encode(b"wrong").decode())
        self.assert_error("invalid_public_key", lambda: installer.public_key(path))
        path.write_text(self.key() + " bloom")
        self.assertEqual(installer.public_key(path), self.key())

    def test_key_update_preserves_existing_and_is_idempotent(self):
        home = self.root / "home"
        (home / ".ssh").mkdir(parents=True)
        path = home / ".ssh/authorized_keys"
        path.write_text("ssh-ed25519 another-key owner\n")
        account = mock.Mock(pw_uid=os.getuid(), pw_gid=os.getgid())
        args = mock.Mock(service_home=home)
        installer.install_key(args, self.key(), account)
        once = path.read_text()
        installer.install_key(args, self.key(), account)
        self.assertEqual(path.read_text(), once)
        self.assertIn("another-key", once)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_key_update_never_follows_symlink(self):
        home = self.root / "home"
        (home / ".ssh").mkdir(parents=True)
        target = self.root / "untouched"
        target.write_text("keep")
        (home / ".ssh/authorized_keys").symlink_to(target)
        with self.assertRaises(OSError):
            installer.install_key(mock.Mock(service_home=home), self.key(), mock.Mock(pw_uid=os.getuid(), pw_gid=os.getgid()))
        self.assertEqual(target.read_text(), "keep")

    def test_unit_has_no_network_listener_or_root_process(self):
        args = installer.parser().parse_args([])
        with mock.patch.object(installer, "valid_path"):
            installer.configuration(args)
        unit = installer.unit_contents(args)
        self.assertIn("User=bloom\n", unit)
        self.assertIn("UMask=0077", unit)
        self.assertIn("NoNewPrivileges=true", unit)
        self.assertIn("Environment=PATH=/opt/bloom-browser/bin:", unit)
        self.assertNotIn("Listen", unit)
        self.assertNotIn("User=root", unit)

    def test_configuration_rejects_systemd_injection(self):
        args = installer.parser().parse_args(["--service-name", "bloom\nUser=root"])
        self.assert_error("invalid_configuration", lambda: installer.configuration(args))

    def test_configuration_rejects_overlapping_directories(self):
        args = installer.parser().parse_args(["--data-dir", "/opt/bloom-server/data"])
        with mock.patch.object(installer, "valid_path"):
            self.assert_error("invalid_configuration", lambda: installer.configuration(args))

    def test_command_errors_do_not_echo_output(self):
        fake = mock.Mock(returncode=1, stdout=b"secret-token")
        with mock.patch.object(installer.subprocess, "run", return_value=fake):
            with self.assertRaises(installer.InstallError) as error:
                installer.command(["unavailable"])
        self.assertNotIn("secret-token", str(error.exception))

    def installation_fixture(self):
        package, checksum = self.package()
        key = self.root / "client.pub"
        key.write_text(self.key())
        args = installer.parser().parse_args([
            "--install-root", str(self.root / "install"), "--data-dir", str(self.root / "data"),
            "--service-home", str(self.root / "home"), "--systemd-dir", str(self.root / "systemd"),
            "--package", str(package), "--sha256", checksum, "--client-public-key-file", str(key),
        ])
        args.systemd_dir.mkdir()
        account = mock.Mock(pw_uid=os.getuid(), pw_gid=os.getgid())
        for name, value in [("probe", {"ok": True}), ("marker", None), ("command", mock.Mock(returncode=0)),
                            ("wait_ready", None), ("emit", None)]:
            patch = mock.patch.object(installer, name, return_value=value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(installer.os, "geteuid", return_value=0)
        patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.object(installer.pwd, "getpwnam", return_value=account)
        patch.start()
        self.addCleanup(patch.stop)
        def fake_command(arguments, **_):
            if arguments[0] == sys.executable:
                return subprocess.run(arguments, check=True, capture_output=True)
            return mock.Mock(returncode=0)
        installer.command.side_effect = fake_command
        return args

    def test_fresh_install_starts_private_service(self):
        args = self.installation_fixture()
        installer.install(args)
        self.assertTrue((args.install_root / "current/bin/bloom-server").is_file())
        self.assertEqual(args.data_dir.stat().st_mode & 0o777, 0o700)
        saved = json.loads((args.install_root / ".bloom-installation.json").read_text())
        self.assertEqual(saved["phase"], "installed")
        installer.command.assert_any_call(["systemctl", "start", "bloom-server.service"])
        installer.command.assert_any_call(["apt-get", "install", "-y", "-qq", "git", "tmux", "gh", "ca-certificates", "nodejs", "npm"], timeout=300)

    def test_running_server_update_does_not_restart_it(self):
        args = self.installation_fixture()
        installer.marker.return_value = {"sha256": "different"}
        with mock.patch.object(installer, "service_running", return_value=True):
            self.assert_error("server_running", lambda: installer.install(args))
        installer.command.assert_not_called()

    def test_unchanged_running_install_adds_key_without_restart(self):
        args = self.installation_fixture()
        args.service_home.mkdir()
        installer.marker.return_value = {"sha256": args.sha256}
        with mock.patch.object(installer, "service_running", return_value=True):
            installer.install(args)
        installer.command.assert_not_called()
        self.assertIn(self.key(), (args.service_home / ".ssh/authorized_keys").read_text())

    def test_failed_upgrade_restores_database_and_release(self):
        args = self.installation_fixture()
        args.install_root.mkdir()
        previous = args.install_root / "old-release"
        previous.mkdir()
        (args.install_root / "current").symlink_to(previous)
        args.data_dir.mkdir()
        database = args.data_dir / "server.sqlite"
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.execute("CREATE TABLE original (value TEXT)")
            connection.execute("INSERT INTO original VALUES ('preserved')")
        saved = {**installer.configuration(args), "sha256": "old", "phase": "installed"}
        installer.marker.return_value = saved
        unit = args.systemd_dir / "bloom-server.service"
        unit.write_text("original unit")

        def bad_start(*_):
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("DROP TABLE original")
            raise installer.InstallError("startup_failed", "Failed", "Retry")

        installer.wait_ready.side_effect = bad_start
        with mock.patch.object(installer, "service_running", return_value=False), mock.patch.object(installer, "active_work", return_value=False):
            self.assert_error("startup_failed", lambda: installer.install(args))
        self.assertEqual((args.install_root / "current").resolve(), previous)
        self.assertEqual(unit.read_text(), "original unit")
        with closing(sqlite3.connect(database)) as connection, connection:
            self.assertEqual(connection.execute("SELECT value FROM original").fetchone(), ("preserved",))
        self.assertEqual(json.loads((args.install_root / ".bloom-installation.json").read_text()), saved)

    def test_atomic_text_ignores_stale_temporary_symlink(self):
        target = self.root / "file"
        other = self.root / "other"
        other.write_text("keep")
        target.with_name("file.new").symlink_to(other)
        installer.atomic_text(target, "replace")
        self.assertEqual(target.read_text(), "replace")
        self.assertEqual(other.read_text(), "keep")

    @unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "Requires a Linux root installer dropping to its service account")
    def test_upgrade_backup_runs_as_service_user_with_a_writable_private_parent(self):
        account = pwd.getpwnam("nobody")
        self.root.chmod(0o711)
        source_directory = self.root / "source"
        source_directory.mkdir(mode=0o700)
        os.chown(source_directory, account.pw_uid, account.pw_gid)
        source = source_directory / "server.sqlite"
        with closing(sqlite3.connect(source)) as database, database:
            database.execute("CREATE TABLE preserved(value TEXT)")
            database.execute("INSERT INTO preserved VALUES ('kept')")
        os.chown(source, account.pw_uid, account.pw_gid)
        staging = self.root / "staging"
        staging.mkdir(mode=0o700)
        backup = installer.backup_database(source, staging, account)
        self.assertEqual(backup.stat().st_uid, account.pw_uid)
        self.assertEqual(backup.parent.stat().st_mode & 0o777, 0o700)
        with closing(sqlite3.connect(backup)) as database:
            self.assertEqual(database.execute("SELECT value FROM preserved").fetchone(), ("kept",))


if __name__ == "__main__":
    unittest.main()
