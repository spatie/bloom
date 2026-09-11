#!/usr/bin/env python3
"""Rootless provisioning regressions. No package installs, daemon starts or account mutations."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("docker_installer", Path(__file__).with_name("install-bloom-docker.py"))
docker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docker)
from bloom_install_process import standalone_installer_source


class DockerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.account = SimpleNamespace(pw_name="bloom", pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=str(self.home))

    def error(self, code, action):
        with self.assertRaises(docker.DockerError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_standalone_embedding_needs_no_helper_file(self):
        source = standalone_installer_source(Path(docker.__file__))
        path = self.home / "installer.py"
        path.write_text(source)
        result = subprocess.run([sys.executable, "-I", str(path), "--help"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--service-home", result.stdout)
        namespace = {"__name__": "embedded_docker"}
        exec(compile(source, "<docker-setup>", "exec"), namespace)
        self.assertNotIn("__file__", namespace)

    def test_id_allocator_skips_overlaps_and_combined_uid_gid_ranges(self):
        entries = docker.ranges("alice:100000:65536\nbob:160000:65536\ncarol:260000:65536\n")
        self.assertEqual(docker.free_range(entries), (325536, 391072))
        self.assertEqual(docker.free_range([]), (100000, 165536))
        self.assertEqual(docker.free_range([("a", 165536, 200000)]), (100000, 165536))

    def test_reuses_existing_range_and_rejects_other_account_collision(self):
        entries = docker.ranges("bloom:100000:65536\nother:165536:65536\n")
        self.assertEqual(docker.selected_range(entries, "bloom"), (100000, 165536))
        self.error("overlapping_subordinate_ids", lambda: docker.selected_range(entries + [("bad", 160000, 170000)], "bloom"))
        self.assertIsNone(docker.selected_range([("bloom", 1, 32)], "bloom"))

    def test_malformed_subordinate_files_fail_closed(self):
        for value in ("x:abc:42", "x:0:65536", "x:100000:0", "x:4294967294:65536", "x:1:2:3"):
            with self.subTest(value=value):
                self.error("invalid_subordinate_ids", lambda: docker.ranges(value))

    def prepare(self):
        return subprocess.run([sys.executable, "-c", docker.PREPARE_HOME, str(self.home)], capture_output=True, text=True, timeout=5)

    def test_user_home_preparation_is_idempotent_and_keeps_data_in_bloom(self):
        first = self.prepare()
        self.assertEqual(first.returncode, 0, first.stderr)
        config = self.home / ".config/docker/daemon.json"
        stamp = config.stat().st_mtime_ns
        second = self.prepare()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(config.stat().st_mtime_ns, stamp)
        self.assertEqual(json.loads(config.read_text()), {"data-root": str(self.home / "bloom/docker/data")})
        self.assertEqual(os.readlink(self.home / "bloom/bin/docker"), "/usr/bin/docker")
        self.assertEqual(os.readlink(self.home / "bloom/bin/rootlesskit"), "/usr/bin/rootlesskit")

    def test_home_symlink_does_not_write_outside_bloom(self):
        outside = self.home / "outside"
        outside.mkdir()
        (self.home / "bloom").symlink_to(outside)
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_existing_configuration_is_not_replaced(self):
        self.assertEqual(self.prepare().returncode, 0)
        path = self.home / ".config/docker/daemon.json"
        original = '{"data-root":"/other"}'
        path.write_text(original)
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(path.read_text(), original)

    def test_unmanaged_user_service_is_not_adopted(self):
        path = self.home / ".config/systemd/user/docker.service"
        path.parent.mkdir(parents=True)
        path.write_text("another installation")
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(path.read_text(), "another installation")

    def test_verification_requires_rootless_daemon_and_expected_data_root(self):
        info = {"SecurityOptions": ["name=seccomp", "name=rootless"], "DockerRootDir": str(self.home / "bloom/docker/data"), "ServerVersion": "29"}
        endpoint = json.dumps(f"unix:///run/user/{os.getuid()}/docker.sock")
        with mock.patch.object(docker, "command", side_effect=["rootless", endpoint, json.dumps(info), "Compose2"]) as command:
            result = docker.verify(self.account)
            self.assertTrue(result["rootless"])
            for call in command.call_args_list:
                self.assertNotIn("DOCKER_HOST", call.kwargs["env"])
                self.assertNotIn("DOCKER_CONTEXT", call.kwargs["env"])
                self.assertEqual(call.kwargs["env"]["HOME"], str(self.home))
        info["SecurityOptions"] = ["name=seccomp"]
        with mock.patch.object(docker, "command", side_effect=["rootless", endpoint, json.dumps(info)]):
            self.error("not_rootless", lambda: docker.verify(self.account))
        info["SecurityOptions"] = ["name=rootless"]
        info["DockerRootDir"] = "/var/lib/docker"
        with mock.patch.object(docker, "command", side_effect=["rootless", endpoint, json.dumps(info)]):
            self.error("unexpected_data_directory", lambda: docker.verify(self.account))

    def test_default_docker_context_must_target_private_socket(self):
        for context, endpoint in (("default", "unix:///var/run/docker.sock"), ("rootless", "unix:///var/run/docker.sock"),
                                  ("rootless", "tcp://docker.example:2375")):
            with self.subTest(context=context, endpoint=endpoint), mock.patch.object(docker, "command", side_effect=[context, json.dumps(endpoint)]) as command:
                self.error("incorrect_docker_context", lambda: docker.verify(self.account))
                self.assertEqual(command.call_count, 2)

    def test_command_runs_without_supplementary_groups_and_bounds_failure_output(self):
        completed = SimpleNamespace(returncode=0, stdout=b"ok")
        with mock.patch.object(docker, "stream_install_command", return_value=completed) as run:
            self.assertEqual(docker.command(["example"], account=self.account), "ok")
            self.assertEqual(run.call_args.kwargs["extra_groups"], [])
            self.assertEqual(run.call_args.kwargs["user"], os.getuid())
        with self.assertRaises(docker.DockerError) as caught:
            docker.command([sys.executable, "-c", "import sys; print('password=do-not-leak'); print('failure'); sys.exit(4)"], live=False)
        self.assertEqual(caught.exception.metadata["exitStatus"], 4)
        self.assertIn("failure", caught.exception.metadata["details"])
        self.assertNotIn("do-not-leak", str(caught.exception.metadata))

    def test_privileged_system_paths_reject_symlinks(self):
        link = self.home / "link"
        link.symlink_to("/etc")
        self.error("unsafe_path", lambda: docker.protected(link / "subuid"))

    def test_file_watch_floor_is_persisted_without_changing_other_kernel_settings(self):
        path = self.home / "90-bloom-docker.conf"
        current = self.home / "current-watches"
        current.write_text("30691\n")
        with mock.patch.object(docker, "protected"), mock.patch.object(docker, "command") as command:
            result = docker.configure_file_watches(path, current)
        self.assertEqual(result, 262144)
        self.assertEqual(path.read_text(), "# Managed by Bloom optional Docker setup\nfs.inotify.max_user_watches = 262144\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        command.assert_called_once_with(["sysctl", "-w", "fs.inotify.max_user_watches=262144"])
        stamp = path.stat().st_mtime_ns
        current.write_text("262144\n")
        with mock.patch.object(docker, "protected"), mock.patch.object(docker, "command") as command:
            docker.configure_file_watches(path, current)
        command.assert_not_called()
        self.assertEqual(path.stat().st_mtime_ns, stamp)

    def test_higher_existing_file_watch_limit_is_preserved(self):
        path = self.home / "90-bloom-docker.conf"
        current = self.home / "current-watches"
        current.write_text("524288\n")
        with mock.patch.object(docker, "protected"), mock.patch.object(docker, "command") as command:
            self.assertEqual(docker.configure_file_watches(path, current), 524288)
        command.assert_not_called()
        self.assertFalse(path.exists())

    def test_unmanaged_or_linked_file_watch_configuration_is_not_overwritten(self):
        path = self.home / "90-bloom-docker.conf"
        current = self.home / "current-watches"
        current.write_text("30691\n")
        path.write_text("fs.inotify.max_user_watches=8000\n")
        with mock.patch.object(docker, "protected"), mock.patch.object(docker, "command") as command:
            self.error("unmanaged_watch_configuration", lambda: docker.configure_file_watches(path, current))
        command.assert_not_called()
        self.assertEqual(path.read_text(), "fs.inotify.max_user_watches=8000\n")
        path.unlink()
        path.symlink_to(current)
        self.error("unsafe_path", lambda: docker.configure_file_watches(path, current))
        self.assertEqual(current.read_text(), "30691\n")

    def test_managed_account_must_match_root_marker(self):
        options = argparse.Namespace(user="bloom", service_name="bloom-server", service_home=str(self.home))
        account = SimpleNamespace(pw_name="bloom", pw_uid=1001, pw_gid=1001, pw_dir=str(self.home))
        marker = {"phase": "installed", "serviceUser": "bloom", "serviceHome": str(self.home), "serviceName": "bloom-server"}
        metadata = SimpleNamespace(st_mode=0o040700, st_uid=1001)
        with mock.patch.object(docker.pwd, "getpwnam", return_value=account), mock.patch.object(docker, "protected"), \
             mock.patch.object(Path, "read_text", return_value=json.dumps(marker)), mock.patch.object(Path, "lstat", return_value=metadata):
            self.assertIs(docker.managed_account(options), account)
        marker["serviceUser"] = "someone-else"
        with mock.patch.object(docker.pwd, "getpwnam", return_value=account), mock.patch.object(docker, "protected"), \
             mock.patch.object(Path, "read_text", return_value=json.dumps(marker)):
            self.error("unmanaged_account", lambda: docker.managed_account(options))
        account.pw_uid = 0
        with mock.patch.object(docker.pwd, "getpwnam", return_value=account):
            self.error("invalid_account", lambda: docker.managed_account(options))

    def test_range_reservation_uses_native_usermod_and_is_idempotent(self):
        files = {"/etc/subuid": "alice:100000:65536\n", "/etc/subgid": "group-owner:200000:65536\n"}
        def read(path):
            return files[str(path)]
        def update(arguments):
            self.assertEqual(arguments[0], "usermod")
            self.assertEqual(arguments[-1], "bloom")
            for index in range(1, len(arguments) - 1, 2):
                start, end = map(int, arguments[index + 1].split("-"))
                path = "/etc/subuid" if arguments[index] == "--add-subuids" else "/etc/subgid"
                files[path] += f"bloom:{start}:{end - start + 1}\n"
        with mock.patch.object(docker, "protected"), mock.patch.object(Path, "exists", return_value=True), \
             mock.patch.object(Path, "read_text", read), mock.patch.object(docker.pwd, "getpwall", return_value=[]), \
             mock.patch.object(docker.grp, "getgrall", return_value=[]), mock.patch.object(docker, "command", side_effect=update) as command:
            docker.reserve_ranges(self.account)
            self.assertEqual(command.call_count, 1)
            docker.reserve_ranges(self.account)
            self.assertEqual(command.call_count, 1)
        uid_range = docker.selected_range(docker.ranges(files["/etc/subuid"]), "bloom")
        gid_range = docker.selected_range(docker.ranges(files["/etc/subgid"]), "bloom")
        self.assertEqual(uid_range, (265536, 331072))
        self.assertEqual(gid_range, (331072, 396608))

    def test_install_commands_use_user_service_without_force_or_group_changes(self):
        with mock.patch.object(Path, "read_text", return_value='ID=ubuntu\n'), mock.patch.object(Path, "is_file", return_value=True), \
             mock.patch.object(docker, "protected"), mock.patch.object(docker, "configure_file_watches"), mock.patch.object(docker, "reserve_ranges") as reserve, \
             mock.patch.object(docker, "command", return_value="") as run, mock.patch.object(docker, "verify", return_value={"ready": True}):
            self.assertEqual(docker.install(self.account), {"ready": True})
        reserve.assert_called_once_with(self.account)
        calls = run.call_args_list
        self.assertIn(["loginctl", "enable-linger", "bloom"], [c.args[0] for c in calls])
        helper = next(c for c in calls if "dockerd-rootless-setuptool.sh" in c.args[0][0])
        self.assertEqual(helper.args[0][-1], "install")
        self.assertIs(helper.kwargs["account"], self.account)
        prepare = next(c for c in calls if c.args[0][0] == sys.executable)
        self.assertIs(prepare.kwargs["account"], self.account)
        selection = next(c for c in calls if c.args[0] == ["/usr/bin/docker", "context", "use", "rootless"])
        self.assertIs(selection.kwargs["account"], self.account)
        self.assertFalse(any("--force" in c.args[0] or "usermod" in c.args[0] for c in calls))


if __name__ == "__main__":
    unittest.main()
