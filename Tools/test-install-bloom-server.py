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
import signal
import stat
import time
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
        args = installer.parser().parse_args(["--install-root", str(self.root / "install"), "--data-dir", str(self.root / "install/data")])
        with mock.patch.object(installer, "valid_path"):
            self.assert_error("invalid_configuration", lambda: installer.configuration(args))

    def test_command_errors_do_not_echo_output(self):
        fake = mock.Mock(returncode=1, stdout=b"secret-token")
        with mock.patch.object(installer.subprocess, "run", return_value=fake):
            with self.assertRaises(installer.InstallError) as error:
                installer.command(["unavailable"])
        self.assertNotIn("secret-token", str(error.exception))

    def test_working_system_node_and_npm_skip_conflicting_packages(self):
        args = mock.Mock(user="bloom")
        with mock.patch.object(installer.pwd, "getpwnam"), \
             mock.patch.object(installer, "node_tool_status", return_value={"node": True, "npm": True}), \
             mock.patch.object(installer, "package_installed", return_value=True), \
             mock.patch.object(installer, "emit"), mock.patch.object(installer, "command") as command:
            installer.install_dependencies(args)
            command.assert_not_called()

    def test_nodesource_pair_installs_only_missing_base_packages(self):
        with mock.patch.object(installer.pwd, "getpwnam"), \
             mock.patch.object(installer, "node_tool_status", return_value={"node": True, "npm": True}), \
             mock.patch.object(installer, "package_installed", side_effect=lambda name: name != "gh"), \
             mock.patch.object(installer, "emit"), mock.patch.object(installer, "command") as command:
            installer.install_dependencies(mock.Mock(user="bloom"))
        self.assertEqual([call.args[0] for call in command.call_args_list], [
            ["apt-get", "update"], ["apt-get", "install", "--simulate", "--no-remove", "gh"],
            ["apt-get", "install", "-y", "--no-remove", "gh"]])

    def test_existing_node_without_usable_npm_fails_without_provider_changes(self):
        with mock.patch.object(installer.pwd, "getpwnam"), \
             mock.patch.object(installer, "node_tool_status", return_value={"node": True, "npm": False}), \
             mock.patch.object(installer, "package_installed", return_value=True), \
             mock.patch.object(installer, "command") as command:
            with self.assertRaises(installer.InstallError) as caught:
                installer.install_dependencies(mock.Mock(user="bloom"))
        self.assertEqual(caught.exception.code, "npm_unavailable")
        self.assertIn("matching npm installation", caught.exception.recovery)
        self.assertIn("root-only nvm", caught.exception.recovery)
        command.assert_not_called()

    def test_fresh_server_installs_missing_node_pair_after_read_only_simulation(self):
        account = mock.Mock(pw_uid=65534)
        with mock.patch.object(installer.pwd, "getpwnam", side_effect=[KeyError("bloom"), account]), \
             mock.patch.object(installer, "node_tool_status", return_value={"node": False, "npm": False}) as status, \
             mock.patch.object(installer, "package_installed", return_value=False), \
             mock.patch.object(installer, "emit"), mock.patch.object(installer, "command") as command:
            installer.install_dependencies(mock.Mock(user="bloom"))
        status.assert_called_once_with(account)
        self.assertEqual(command.call_args_list[-2].args[0],
                         ["apt-get", "install", "--simulate", "--no-remove", "git", "tmux", "gh", "ca-certificates", "nodejs", "npm"])
        self.assertEqual(command.call_args_list[-1].args[0],
                         ["apt-get", "install", "-y", "--no-remove", "git", "tmux", "gh", "ca-certificates", "nodejs", "npm"])

    def test_node_probe_uses_service_accessible_path_and_unprivileged_account(self):
        account = mock.Mock(pw_uid=12345)
        result = subprocess.CompletedProcess([], 0, stdout=b"version")
        with mock.patch.dict(os.environ, {"PATH": "/root/.nvm/bin"}), \
             mock.patch.object(installer.shutil, "which", side_effect=lambda name, path: "/usr/bin/" + name) as lookup, \
             mock.patch.object(installer, "command", return_value=result) as command:
            self.assertEqual(installer.node_tool_status(account), {"node": True, "npm": True})
        self.assertEqual([call.kwargs["path"] for call in lookup.call_args_list], [installer.SYSTEM_PATH] * 2)
        self.assertNotIn(".nvm", installer.SYSTEM_PATH)
        self.assertIn("/usr/local/bin", installer.SYSTEM_PATH)
        self.assertTrue(all(call.kwargs["account"] is account for call in command.call_args_list))

    def test_live_package_failure_preserves_safe_command_status_and_redacted_tail(self):
        executable = self.root / "apt-get"
        executable.write_text("#!/bin/sh\nprintf 'package dependency conflict\npassword=hidden-value\n'\nexit 9\n")
        executable.chmod(0o755)
        with mock.patch.object(installer, "CURRENT_STEP", "dependencies"), mock.patch.object(installer, "emit") as emit:
            with self.assertRaises(installer.InstallError) as caught:
                installer.command([str(executable), "install", "nodejs", "npm"])
        metadata = caught.exception.metadata
        self.assertEqual(metadata["command"], "apt-get install nodejs npm")
        self.assertEqual(metadata["exitStatus"], 9)
        self.assertIn("package dependency conflict", metadata["details"])
        self.assertNotIn("hidden-value", str(metadata) + str(emit.call_args_list))
        self.assertTrue(all(call.kwargs["step"] == "dependencies" for call in emit.call_args_list))
        self.assertTrue(all(call.args[0] == "output" for call in emit.call_args_list))

    def unmanaged_account_fixture(self):
        args = installer.parser().parse_args([
            "--install-root", str(self.root / "install"), "--data-dir", str(self.root / "data"),
            "--service-home", str(self.root / "home"), "--systemd-dir", str(self.root / "systemd"),
            "--user", "existing-bloom",
        ])
        installer.configuration(args)
        # Only ancestor ownership is synthetic. Keep real existence, permissions and contents,
        # so the check must reach the account conflict rather than an unrelated directory error.
        parents = {parent for path in (args.install_root, args.data_dir, args.service_home) for parent in path.parents}
        original_stat = pathlib.Path.stat

        def root_owned_parent(path, *positional, **keywords):
            info = original_stat(path, *positional, **keywords)
            if path in parents:
                fields = list(info)
                fields[4] = 0
                fields[0] &= ~0o022
                return os.stat_result(fields)
            return info

        account = mock.Mock(pw_name=args.user, pw_uid=12345, pw_dir=str(self.root / "unmanaged-home"))
        for patch in [mock.patch.object(pathlib.Path, "stat", root_owned_parent),
                      mock.patch.object(installer.pwd, "getpwnam", return_value=account),
                      mock.patch.object(installer.os, "geteuid", return_value=0)]:
            patch.start()
            self.addCleanup(patch.stop)
        return args

    def test_unmanaged_service_account_has_specific_safe_recovery_without_mutation(self):
        args = self.unmanaged_account_fixture()
        sentinel = self.root / "unrelated-file"
        sentinel.write_text("preserve")
        with mock.patch.object(installer, "command") as command:
            with self.assertRaises(installer.InstallError) as caught:
                installer.check_ownership(args, None)
            command.assert_not_called()
        error = caught.exception
        self.assertEqual(error.code, "service_account_exists")
        self.assertIn("'existing-bloom'", error.message)
        self.assertIn("no matching managed Bloom installation metadata", error.message)
        self.assertIn("Advanced Settings", error.recovery)
        self.assertIn("inspect its files and processes", error.recovery)
        self.assertIn("back up", error.recovery)
        self.assertIn("only after confirming it is unused", error.recovery)
        self.assertIn("Check Again", error.recovery)
        self.assertIn("fresh server", error.recovery)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertEqual(list(self.root.iterdir()), [sentinel])

    def test_probe_preserves_unmanaged_account_recovery_without_mutation(self):
        args = self.unmanaged_account_fixture()
        with mock.patch.object(installer, "command") as command:
            check = installer.probe(args)
            command.assert_not_called()
        blockers = [item for item in check["blockers"] if item["code"] == "service_account_exists"]
        self.assertEqual(len(blockers), 1)
        self.assertFalse(check["ok"])
        self.assertIn("'existing-bloom'", blockers[0]["message"])
        self.assertIn("Advanced Settings", blockers[0]["recovery"])
        self.assertIn("Check Again", blockers[0]["recovery"])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_probe_keeps_recovery_for_other_install_errors(self):
        args = self.unmanaged_account_fixture()
        with mock.patch.object(installer, "marker", side_effect=installer.InstallError("untrusted_installation", "Protected metadata changed.", "Restore its root ownership.")):
            check = installer.probe(args)
        blocker = next(item for item in check["blockers"] if item["code"] == "untrusted_installation")
        self.assertEqual(blocker["recovery"], "Restore its root ownership.")

    def activity_probe_fixture(self):
        args = installer.parser().parse_args([
            "--install-root", str(self.root / "install"), "--data-dir", str(self.root / "data"),
            "--service-home", str(self.root / "home"), "--systemd-dir", str(self.root / "systemd"),
            "--service-name", "bloom-custom",
        ])
        for name, value in [("marker", {"phase": "installed"}), ("check_ownership", None),
                            ("existing_account", mock.Mock()), ("active_work", False),
                            ("service_running", False), ("daemon_locked", False), ("command", None)]:
            patch = mock.patch.object(installer, name, return_value=value)
            patch.start()
            self.addCleanup(patch.stop)
        for patch in [mock.patch.object(installer.os, "geteuid", return_value=0),
                      mock.patch.object(installer, "account_operation", side_effect=lambda account, operation: operation())]:
            patch.start()
            self.addCleanup(patch.stop)
        return args

    def test_probe_reports_active_and_configured_swap_without_mutation(self):
        args = self.activity_probe_fixture()
        for active, configured in ((0, False), (0, True), (2147483648, True)):
            with self.subTest(active=active, configured=configured):
                with mock.patch.object(installer, "read_swap_status", return_value={
                    "activeSwapBytes": active, "configuredSwap": configured,
                }):
                    check = installer.probe(args)
                self.assertEqual(check["activeSwapBytes"], active)
                self.assertEqual(check["configuredSwap"], configured)
                installer.command.assert_not_called()

    def test_probe_does_not_claim_unknown_swap_is_absent(self):
        args = self.activity_probe_fixture()
        for failure in (PermissionError("Cannot read configuration"), ValueError("Invalid active listing")):
            with self.subTest(failure=type(failure).__name__):
                with mock.patch.object(installer, "read_swap_status", side_effect=failure):
                    check = installer.probe(args)
                self.assertIsNone(check["activeSwapBytes"])
                self.assertIsNone(check["configuredSwap"])
                installer.command.assert_not_called()

    def test_probe_blocks_running_service_with_exact_stop_instructions(self):
        args = self.activity_probe_fixture()
        installer.service_running.return_value = True
        check = installer.probe(args)
        blocker = next(item for item in check["blockers"] if item["code"] == "server_running")
        self.assertFalse(check["ok"])
        self.assertIn("sudo systemctl stop bloom-custom.service", blocker["recovery"])
        self.assertIn("systemctl is-active bloom-custom.service", blocker["recovery"])
        self.assertIn("Check Again", blocker["recovery"])
        installer.command.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_probe_detects_manually_started_daemon(self):
        args = self.activity_probe_fixture()
        installer.daemon_locked.return_value = True
        check = installer.probe(args)
        blocker = next(item for item in check["blockers"] if item["code"] == "server_running")
        self.assertIn("terminal or process manager", blocker["recovery"])
        installer.command.assert_not_called()

    def test_probe_blocks_active_work_before_offering_to_stop_service(self):
        args = self.activity_probe_fixture()
        installer.active_work.return_value = True
        check = installer.probe(args)
        blocker = next(item for item in check["blockers"] if item["code"] == "server_busy")
        self.assertIn("Finish that work", blocker["recovery"])
        self.assertNotIn("systemctl stop", blocker["recovery"])
        installer.service_running.assert_not_called()

    def test_probe_allows_idle_stopped_installation(self):
        args = self.activity_probe_fixture()
        check = installer.probe(args)
        self.assertFalse(any(item["code"] in ("server_busy", "server_running") for item in check["blockers"]))
        installer.daemon_locked.assert_called_once_with(args)

    def test_install_preserves_preflight_recovery_before_any_mutation(self):
        args = self.installation_fixture()
        installer.probe.return_value = {"ok": False, "blockers": [{
            "code": "server_running", "message": "Server is running.",
            "recovery": "Run sudo systemctl stop bloom-custom.service once work is idle.",
        }]}
        with self.assertRaises(installer.InstallError) as caught:
            installer.install(args)
        self.assertEqual(caught.exception.code, "server_running")
        self.assertIn("bloom-custom.service", caught.exception.recovery)
        installer.command.assert_not_called()
        installer.install_dependencies.assert_not_called()

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
                            ("wait_ready", None), ("emit", None), ("install_dependencies", None), ("verify_node_tools", None), ("protected_system_path", None), ("account_operation", None)]:
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
        installer.account_operation.side_effect = lambda account, operation: operation()
        return args

    def test_fresh_install_starts_private_service(self):
        args = self.installation_fixture()
        installer.install(args)
        self.assertTrue((args.install_root / "current/bin/bloom-server").is_file())
        self.assertEqual(args.data_dir.stat().st_mode & 0o777, 0o700)
        saved = json.loads(installer.marker_path(args).read_text())
        self.assertEqual(saved["phase"], "installed")
        installer.command.assert_any_call(["systemctl", "start", "bloom-server.service"])
        installer.install_dependencies.assert_called_once_with(args)
        installer.verify_node_tools.assert_called_once()

    def test_running_server_update_does_not_restart_it(self):
        args = self.installation_fixture()
        installer.marker.return_value = {"sha256": "different"}
        with mock.patch.object(installer, "service_running", return_value=True):
            self.assert_error("server_running", lambda: installer.install(args))
        installer.command.assert_not_called()

    def test_matching_marker_does_not_claim_a_user_owned_running_runtime_is_verified(self):
        args = self.installation_fixture()
        args.service_home.mkdir()
        installer.marker.return_value = {"sha256": args.sha256}
        with mock.patch.object(installer, "service_running", return_value=True):
            self.assert_error("server_running", lambda: installer.install(args))
        installer.command.assert_not_called()
        self.assertFalse((args.service_home / ".ssh/authorized_keys").exists())

    def test_prepared_installation_with_a_missing_account_resumes_user_creation(self):
        args = self.installation_fixture()
        installer.marker.return_value = {**installer.configuration(args), "phase": "prepared", "sha256": args.sha256}
        account = mock.Mock(pw_uid=os.getuid(), pw_gid=os.getgid())
        installer.pwd.getpwnam.side_effect = [KeyError(args.user), KeyError(args.user), account]
        installer.install(args)
        installer.command.assert_any_call(["useradd", "--system", "--user-group", "--create-home", "--home-dir", str(args.service_home),
                                          "--shell", "/bin/bash", args.user])
        self.assertTrue((args.install_root / "current/bin/bloom-server").is_file())
        self.assertEqual(json.loads(installer.marker_path(args).read_text())["phase"], "installed")

    def test_installer_rejects_a_precreated_user_owned_lock_inode(self):
        directory = self.root / "locks"
        info = mock.Mock(st_uid=12345, st_mode=stat.S_IFREG | 0o600)
        with mock.patch.object(installer, "protected_system_path"), mock.patch.object(installer.os, "fstat", return_value=info):
            self.assert_error("untrusted_lock", lambda: installer.open_installation_lock("bloom", directory))
        self.assertEqual((directory / "bloom.lock").stat().st_size, 0)

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
        self.assertEqual(json.loads(installer.marker_path(args).read_text()), saved)

    def test_startup_timeout_collects_redacted_journal_before_rollback(self):
        wait_ready = installer.wait_ready
        args = self.installation_fixture()
        original_command = installer.command.side_effect
        journal = subprocess.CompletedProcess([], 0, stdout=b"Fatal: database migration failed\npassword=hidden-journal-secret\n")
        def fake_command(arguments, **keywords):
            if arguments[0] == "journalctl":
                return journal
            return original_command(arguments, **keywords)
        installer.command.side_effect = fake_command
        installer.account_operation.side_effect = lambda account, operation: operation()
        installer.wait_ready.side_effect = wait_ready
        with mock.patch.object(installer.time, "monotonic", side_effect=[0, 21]):
            with self.assertRaises(installer.InstallError) as caught:
                installer.install(args)
        failure = caught.exception
        self.assertEqual(failure.code, "startup_failed")
        self.assertIn("Fatal: database migration failed", failure.metadata["details"])
        self.assertNotIn("hidden-journal-secret", str(failure.metadata) + str(installer.emit.call_args_list))
        self.assertIsNone(failure.metadata["exitStatus"])
        self.assertEqual(failure.metadata["command"], "systemctl start bloom-server.service")
        calls = [call.args[0] for call in installer.command.call_args_list]
        journal_command = ["journalctl", "-u", "bloom-server.service", "-n", "40", "--no-pager", "--output=cat"]
        self.assertLess(calls.index(journal_command), calls.index(["systemctl", "stop", "bloom-server.service"]))
        installer.emit.assert_any_call("output", message="Fatal: database migration failed", step="service")
        self.assertFalse((args.install_root / "current").exists())

    def test_startup_timeout_remains_primary_failure_when_journal_cannot_be_read(self):
        args = mock.Mock(service_name="bloom-server")
        with mock.patch.object(installer.time, "monotonic", side_effect=[0, 21]), \
             mock.patch.object(installer, "socket_path", return_value=self.root / "socket"), \
             mock.patch.object(installer, "command", side_effect=OSError("journal unavailable token=hidden-journal-token")):
            with self.assertRaises(installer.InstallError) as caught:
                installer.wait_ready(args, 12345)
        self.assertEqual(caught.exception.code, "startup_failed")
        self.assertIn("did not become ready", caught.exception.metadata["details"])
        self.assertIn("journal unavailable", caught.exception.metadata["details"])
        self.assertNotIn("hidden-journal-token", caught.exception.metadata["details"])

    def test_unexpected_os_error_keeps_redacted_exception_details(self):
        error = OSError(13, "Permission denied", "https://user:private-password@mirror.example/path?token=private-token")
        with mock.patch.object(installer, "configuration", side_effect=error), \
             mock.patch.object(installer.sys, "argv", ["installer", "--check"]), \
             mock.patch.object(installer, "emit") as emit:
            status = installer.main()
        self.assertEqual(status, 1)
        value = emit.call_args.kwargs
        self.assertEqual(value["code"], "installation_failed")
        self.assertIn("PermissionError", value["details"])
        self.assertIn("Permission denied", value["details"])
        self.assertIn("https://mirror.example/path", value["details"])
        self.assertNotIn("private-", str(value))
        self.assertNotIn("exitStatus", value)

    def test_atomic_text_ignores_stale_temporary_symlink(self):
        target = self.root / "file"
        other = self.root / "other"
        other.write_text("keep")
        target.with_name("file.new").symlink_to(other)
        installer.atomic_text(target, "replace")
        self.assertEqual(target.read_text(), "replace")
        self.assertEqual(other.read_text(), "keep")

    def test_defaults_keep_the_conventional_home_and_runtime_in_bloom(self):
        args = installer.parser().parse_args([])
        with mock.patch.object(installer, "valid_path"):
            installer.configuration(args)
        self.assertEqual(args.service_home, pathlib.Path("/home/bloom"))
        self.assertEqual(args.install_root, args.service_home / "bloom/server")
        self.assertEqual(args.data_dir, args.service_home / "bloom/data")
        self.assertEqual(installer.marker_path(args), pathlib.Path("/etc/systemd/system/bloom-installations/bloom-server.json"))
        unit = installer.unit_contents(args)
        self.assertIn("Environment=HOME=/home/bloom\n", unit)
        self.assertIn("/home/bloom/.local/bin", unit)
        self.assertIn("User=bloom\n", unit)
        self.assertNotIn("StandardOutput=append:", unit)

    def test_a_home_marker_cannot_claim_a_managed_system_installation(self):
        args = installer.parser().parse_args(["--service-home", str(self.root / "home"),
                                              "--systemd-dir", str(self.root / "systemd")])
        installer.configuration(args)
        args.install_root.mkdir(parents=True)
        (args.install_root / ".bloom-installation.json").write_text(json.dumps(installer.configuration(args)))
        with mock.patch.object(installer, "protected_system_path"):
            self.assertIsNone(installer.marker(args))
        self.assertFalse(installer.marker_path(args).is_relative_to(args.service_home))

    def test_system_metadata_rejects_a_symlink_even_when_the_target_is_a_file(self):
        args = installer.parser().parse_args(["--systemd-dir", str(self.root)])
        marker = installer.marker_path(args)
        marker.parent.mkdir()
        target = self.root / "unrelated"
        target.write_text("preserve")
        marker.symlink_to(target)
        self.assert_error("untrusted_directory", lambda: installer.save_marker(args, {}))
        self.assertEqual(target.read_text(), "preserve")

    @unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "Requires a real privilege drop")
    def test_service_file_operations_drop_identity_and_cannot_write_root_files(self):
        account = pwd.getpwnam("nobody")
        identity = installer.account_operation(account, lambda: [os.getuid(), os.geteuid(), os.getgroups()])
        self.assertEqual(identity, [account.pw_uid, account.pw_uid, []])
        self.root.chmod(0o711)
        protected = self.root / "root-private"
        protected.mkdir(mode=0o700)
        secret = protected / "unchanged"
        secret.write_text("preserve")
        home = self.root / "home"
        home.mkdir(mode=0o700)
        os.chown(home, account.pw_uid, account.pw_gid)
        redirected = home / "redirected"
        redirected.symlink_to(secret)
        self.assert_error("account_files_failed", lambda: installer.account_operation(account, lambda: redirected.write_text("changed")))
        self.assertEqual(secret.read_text(), "preserve")
        created = home / "owned-file"
        installer.account_operation(account, lambda: created.write_text("owned"))
        self.assertEqual(created.stat().st_uid, account.pw_uid)
        self.assertEqual(created.stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "Requires a real privilege drop")
    def test_runtime_copy_and_release_activation_use_only_the_service_uid(self):
        account = pwd.getpwnam("nobody")
        self.root.chmod(0o711)
        home = self.root / "home"
        home.mkdir(mode=0o700)
        os.chown(home, account.pw_uid, account.pw_gid)
        args = installer.parser().parse_args(["--service-home", str(home)])
        installer.configuration(args)
        bundle = self.extract()
        previous = installer.account_operation(account, lambda: installer.prepare_account_files(args, self.key(), bundle, "fixture", account))
        self.assertIsNone(previous)
        release = args.install_root / "releases/fixture"
        installer.account_operation(account, lambda: installer.set_current_release(args, str(release)))
        for path in [args.install_root, args.data_dir, release / "bin/bloom-server", home / ".ssh/authorized_keys"]:
            self.assertEqual(path.stat().st_uid, account.pw_uid)
        self.assertEqual((args.install_root / "current").resolve(), release)
        self.assertEqual(args.install_root.stat().st_mode & 0o777, 0o700)
        self.assertEqual((home / "bloom").stat().st_mode & 0o777, 0o700)
        self.assertFalse((args.install_root / ".bloom-installation.json").exists())
        installed = release / "bin/bloom-server"
        installer.account_operation(account, lambda: installed.write_text("tampered"))
        installer.account_operation(account, lambda: installer.prepare_account_files(args, self.key(), bundle, "fixture", account))
        self.assertEqual(installed.read_bytes(), (bundle / "bin/bloom-server").read_bytes())
        self.assertEqual(installed.stat().st_uid, account.pw_uid)

    @unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "Requires a real privilege drop")
    def test_stuck_or_invalid_service_children_are_bounded_and_reaped(self):
        account = pwd.getpwnam("nobody")
        real_fork = os.fork
        children = []
        def capture_fork():
            pid = real_fork()
            if pid:
                children.append(pid)
            return pid
        def stuck():
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(5)
        with mock.patch.object(installer.os, "fork", side_effect=capture_fork):
            started = time.monotonic()
            self.assert_error("account_files_timeout", lambda: installer.account_operation(account, stuck, timeout=0.05))
            self.assertLess(time.monotonic() - started, 2)
            self.assert_error("account_files_failed", lambda: installer.account_operation(account, lambda: os._exit(23)))
            self.assert_error("account_files_failed", lambda: installer.account_operation(account, lambda: "x" * 1_100_000))
        for child in children:
            with self.assertRaises(ChildProcessError):
                os.waitpid(child, os.WNOHANG)

    @unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "Requires a real privilege drop")
    def test_parent_cancellation_reaps_the_service_child(self):
        account = pwd.getpwnam("nobody")
        real_fork = os.fork
        children = []
        def capture_fork():
            pid = real_fork()
            if pid:
                children.append(pid)
            return pid
        with mock.patch.object(installer.os, "fork", side_effect=capture_fork), \
             mock.patch.object(installer.selectors.DefaultSelector, "select", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                installer.account_operation(account, lambda: time.sleep(5))
        for child in children:
            with self.assertRaises(ChildProcessError):
                os.waitpid(child, os.WNOHANG)

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


class StopServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-stop-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.args = installer.parser().parse_args(["--stop-server", "--service-name", "bloom-fixture",
            "--systemd-dir", str(self.root / "units"), "--install-root", str(self.root / "runtime"),
            "--data-dir", str(self.root / "data"), "--service-home", str(self.root / "home")])
        installer.configuration(self.args)
        self.account = mock.Mock(pw_uid=1234, pw_gid=1234)
        self.active = {"LoadState": "loaded", "ActiveState": "active", "SubState": "running", "MainPID": "123",
            "User": "bloom", "Group": "bloom", "FragmentPath": str(self.args.systemd_dir / "bloom-fixture.service"),
            "DropInPaths": "", "NeedDaemonReload": "no", "ControlGroup": "/system.slice/bloom-fixture.service"}
        self.inactive = {**self.active, "ActiveState": "inactive", "SubState": "dead", "MainPID": "0", "ControlGroup": ""}
        self.check = {"ok": False, "blockers": [{"code": "disk_full"}], "existing": True}
        self.patches = {}
        for name, value in [("marker", {"phase": "installed"}), ("check_ownership", None),
                            ("existing_account", self.account), ("active_work", False), ("daemon_locked", False),
                            ("verify_managed_process", None), ("probe", self.check), ("emit", None), ("command", mock.Mock(returncode=0))]:
            patch = mock.patch.object(installer, name, return_value=value)
            self.patches[name] = patch.start(); self.addCleanup(patch.stop)
        for patch in [mock.patch.object(installer.os, "geteuid", return_value=0),
                      mock.patch.object(installer, "account_operation", side_effect=lambda account, operation: operation())]:
            patch.start(); self.addCleanup(patch.stop)

    def assert_refused(self, code, states=None):
        with mock.patch.object(installer, "managed_service_state", side_effect=states or [self.active]):
            with self.assertRaises(installer.InstallError) as raised:
                installer.stop_server(self.args)
        self.assertEqual(raised.exception.code, code)
        self.patches["command"].assert_not_called()

    def test_only_verified_idle_unit_is_stopped_and_fresh_blockers_are_retained(self):
        with mock.patch.object(installer, "managed_service_state", side_effect=[self.active, self.active, self.inactive]):
            check = installer.stop_server(self.args)
        self.assertEqual(check, self.check)
        self.patches["command"].assert_called_once_with(["systemctl", "stop", "bloom-fixture.service"], timeout=40)
        self.assertEqual(self.patches["active_work"].call_count, 2)
        self.patches["probe"].assert_called_once_with(self.args)

    def test_busy_work_and_newly_arriving_work_prevent_stop(self):
        self.patches["active_work"].return_value = True
        self.assert_refused("server_busy")
        self.patches["active_work"].side_effect = [False, True]
        self.assert_refused("server_busy")

    def test_unmanaged_or_partial_installation_cannot_be_stopped(self):
        for marker in [None, {"phase": "prepared"}]:
            self.patches["marker"].return_value = marker
            self.assert_refused("unmanaged_server")

    def test_manual_process_is_not_stopped(self):
        self.patches["daemon_locked"].return_value = True
        self.assert_refused("unmanaged_server", [self.inactive])

    def test_changed_or_unidentified_main_process_prevents_stop(self):
        self.assert_refused("server_running", [self.active, {**self.active, "MainPID": "999"}])
        self.patches["verify_managed_process"].side_effect = installer.InstallError("unmanaged_server", "Unknown process", "Inspect it")
        self.assert_refused("unmanaged_server")

    def test_unknown_and_unfinished_stop_never_report_success(self):
        with mock.patch.object(installer, "managed_service_state", side_effect=[self.active, self.active, self.active]):
            with self.assertRaises(installer.InstallError) as raised:
                installer.stop_server(self.args)
        self.assertEqual(raised.exception.code, "stop_failed")
        self.patches["probe"].assert_not_called()

    def test_lock_remaining_after_systemd_stop_is_not_success(self):
        self.patches["daemon_locked"].return_value = True
        with mock.patch.object(installer, "managed_service_state", side_effect=[self.active, self.active, self.inactive]):
            with self.assertRaises(installer.InstallError) as raised:
                installer.stop_server(self.args)
        self.assertEqual(raised.exception.code, "stop_failed")
        self.patches["probe"].assert_not_called()

    def test_stop_failure_does_not_restart_or_reinstall(self):
        self.patches["command"].side_effect = installer.InstallError("command_failed", "Stop failed", "Inspect systemd")
        with mock.patch.object(installer, "managed_service_state", side_effect=[self.active, self.active]):
            with self.assertRaises(installer.InstallError): installer.stop_server(self.args)
        self.patches["command"].assert_called_once()
        self.patches["probe"].assert_not_called()


class StopOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-stop-ownership-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.args = installer.parser().parse_args(["--stop-server", "--systemd-dir", str(self.root / "units"),
            "--install-root", str(self.root / "runtime"), "--data-dir", str(self.root / "data"), "--service-home", str(self.root / "home")])
        installer.configuration(self.args)
        self.args.systemd_dir.mkdir()
        self.unit = self.args.systemd_dir / "bloom-server.service"
        self.unit.write_text(installer.unit_contents(self.args))
        self.fields = {"LoadState": "loaded", "ActiveState": "active", "SubState": "running", "MainPID": "123",
            "User": "bloom", "Group": "bloom", "FragmentPath": str(self.unit), "DropInPaths": "", "NeedDaemonReload": "no", "ControlGroup": "/system.slice/bloom-server.service"}

    def state(self, fields):
        result = mock.Mock(returncode=0, stdout="\n".join(key + "=" + value for key, value in fields.items()).encode())
        with mock.patch.object(installer, "protected_system_path"), mock.patch.object(installer, "command", return_value=result):
            return installer.managed_service_state(self.args)

    def test_effective_unit_account_dropins_and_reload_must_match(self):
        self.assertEqual(self.state(self.fields), self.fields)
        for changes in [{"User": "root"}, {"FragmentPath": "/unrelated.service"}, {"DropInPaths": "/other.conf"}, {"NeedDaemonReload": "yes"}, {"LoadState": "not-found"}]:
            with self.subTest(changes=changes), self.assertRaises(installer.InstallError):
                self.state({**self.fields, **changes})
        self.unit.write_text(installer.unit_contents(self.args) + "\nExecStop=/unrelated\n")
        with self.assertRaises(installer.InstallError): self.state(self.fields)

    def test_linux_proc_identity_requires_the_owned_executable_arguments_uid_and_cgroup(self):
        proc = self.root / "proc"
        process = proc / "123"; process.mkdir(parents=True)
        expected = str(self.args.install_root / "current/bin/bloom-server")
        (process / "exe").symlink_to(expected)
        argv = [expected, "serve", "--data-dir", str(self.args.data_dir), ""]
        (process / "cmdline").write_bytes("\0".join(argv).encode())
        (process / "status").write_text("Uid:\t1234\t1234\t1234\t1234\n")
        (process / "cgroup").write_text("0::/system.slice/bloom-server.service\n")
        account = mock.Mock(pw_uid=1234)
        installer.verify_managed_process(self.args, account, self.fields, proc=proc)
        for name, bad in [("cmdline", b"another-server\0"), ("status", b"Uid:\t0\t0\t0\t0\n"), ("cgroup", b"0::/user.slice/manual.scope\n")]:
            file = process / name; original = file.read_bytes(); file.write_bytes(bad)
            with self.subTest(file=name), self.assertRaises(installer.InstallError):
                installer.verify_managed_process(self.args, account, self.fields, proc=proc)
            file.write_bytes(original)

    def test_unfinished_or_corrupt_durable_command_journal_is_not_idle(self):
        self.args.data_dir.mkdir()
        with closing(sqlite3.connect(self.args.data_dir / "server.sqlite")) as connection, connection:
            connection.executescript("CREATE TABLE sessions(state TEXT); CREATE TABLE workspaces(setup_state TEXT); CREATE TABLE settings(key TEXT,value TEXT);")
            connection.execute("INSERT INTO settings VALUES (?, ?)", ("server.command.fixture", json.dumps({"request": {"id": "fixture"}})))
        self.assertFalse(installer.active_work(self.args.data_dir))
        with self.assertRaises(installer.InstallError) as raised:
            installer.active_work(self.args.data_dir, include_commands=True)
        self.assertEqual(raised.exception.code, "command_outcome_unknown")
        self.assertIn("historical", raised.exception.recovery)
        with closing(sqlite3.connect(self.args.data_dir / "server.sqlite")) as connection, connection:
            connection.execute("UPDATE settings SET value=?", (json.dumps({"request": {}, "reply": {}}),))
        self.assertFalse(installer.active_work(self.args.data_dir, include_commands=True))
        with closing(sqlite3.connect(self.args.data_dir / "server.sqlite")) as connection, connection:
            connection.execute("UPDATE settings SET value='invalid record'")
        self.assertFalse(installer.active_work(self.args.data_dir))
        with self.assertRaises(installer.InstallError) as raised: installer.active_work(self.args.data_dir, include_commands=True)
        self.assertEqual(raised.exception.code, "database_unavailable")


if __name__ == "__main__":
    unittest.main()
