#!/usr/bin/env python3
"""Swap provisioning contracts in isolated files. No real swap, root accounts or system units."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("swap_installer", Path(__file__).with_name("install-bloom-swap.py"))
swap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(swap)
from bloom_install_process import standalone_installer_source


class SwapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.root = self.directory / "storage"
        self.unit = self.directory / "system/var-lib-bloom-swapfile.swap"
        self.unit.parent.mkdir()
        self.actual_protected = swap.protected
        for name, value in (("ROOT", self.root), ("SWAP_FILE", self.root / "swapfile"),
                            ("MARKER", self.root / ".swap-managed.json"), ("UNIT", self.unit),
                            ("SWAP_BYTES", 4096), ("DISK_RESERVE", 4096)):
            patch = mock.patch.object(swap, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        for name, side_effect in (("protected", lambda path: None), ("read_swap_status", self.state), ("command", self.command)):
            patch = mock.patch.object(swap, name, side_effect=side_effect)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(swap.shutil, "disk_usage", return_value=SimpleNamespace(free=8192))
        self.disk = patch.start()
        self.addCleanup(patch.stop)
        self.active = []
        self.configured = False
        self.commands = []
        self.filesystem = "ext4"
        self.failure = None

    def state(self, ignore_unit=None):
        configured = self.configured or self.unit.exists() and str(self.unit) != ignore_unit
        return {"activeSwapPaths": list(self.active), "activeSwapBytes": len(self.active) * 4096,
                "configuredSwap": configured, "configuredSwapSources": ["fixture"] if configured else []}

    def command(self, arguments, **options):
        self.commands.append(arguments)
        if self.failure == arguments[0] or self.failure == "enable" and arguments[:2] == ["systemctl", "enable"]:
            raise swap.SwapError("command_failed", "Fixture failure", "Retry")
        if arguments[0] == "findmnt": return self.filesystem
        if arguments[0] == "dd": swap.SWAP_FILE.write_bytes(bytes(swap.SWAP_BYTES))
        if arguments[0] == "blkid": return "swap"
        if arguments[:2] == ["systemctl", "start"]: self.active.append(str(swap.SWAP_FILE))
        return ""

    def error(self, code, action):
        with self.assertRaises(swap.SwapError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def prepare(self, phase="prepared"):
        self.root.mkdir(mode=0o700, exist_ok=True)
        swap.SWAP_FILE.write_bytes(bytes(swap.SWAP_BYTES))
        swap.SWAP_FILE.chmod(0o600)
        swap.MARKER.write_text(json.dumps(swap.marker_value(phase)))
        swap.MARKER.chmod(0o600)

    def test_fixed_production_size_and_root_only_location(self):
        namespace = {"__name__": "fixture"}
        exec(Path(swap.__file__).read_text(), namespace)
        self.assertEqual(namespace["SWAP_BYTES"], 2147483648)
        self.assertEqual(namespace["DISK_RESERVE"], 2147483648)
        self.assertEqual(str(namespace["SWAP_FILE"]), "/var/lib/bloom/swapfile")

    def test_new_swap_uses_full_allocation_private_file_and_optional_boot_unit(self):
        result = swap.install()
        self.assertEqual(result["outcome"], "added")
        self.assertTrue(result["active"])
        self.assertEqual(swap.SWAP_FILE.stat().st_mode & 0o777, 0o600)
        allocation = next(args for args in self.commands if args[0] == "dd")
        self.assertIn("if=/dev/zero", allocation)
        self.assertIn("conv=fsync", allocation)
        self.assertIn("oflag=nofollow", allocation)
        self.assertEqual(self.unit.read_text(), swap.unit_contents())
        self.assertIn("WantedBy=swap.target", self.unit.read_text())
        self.assertNotIn("RequiredBy", self.unit.read_text())
        self.assertEqual(json.loads(swap.MARKER.read_text())["phase"], "active")

    def test_existing_active_swap_including_zram_is_preserved_without_commands(self):
        for path in ("/dev/zram0", "/swap.img"):
            self.active = [path]
            result = swap.install()
            self.assertEqual(result["outcome"], "preserved")
            self.assertTrue(result["active"])
            self.assertFalse(self.root.exists())
        self.assertEqual(self.commands, [])

    def test_configured_inactive_swap_is_preserved_without_claiming_it_is_active(self):
        self.configured = True
        result = swap.install()
        self.assertFalse(result["active"])
        self.assertIn("not currently active", result["message"])
        self.assertFalse(self.root.exists())
        self.assertEqual(self.commands, [])

    def test_own_active_swap_is_not_reformatted_or_restarted(self):
        self.prepare("active")
        self.unit.write_text(swap.unit_contents())
        self.active = [str(swap.SWAP_FILE)]
        identity = swap.SWAP_FILE.stat().st_ino
        result = swap.install()
        self.assertEqual(result["outcome"], "managedExisting")
        self.assertTrue(result["unchanged"])
        self.assertEqual(swap.SWAP_FILE.stat().st_ino, identity)
        self.assertFalse(any(args[0] in ("dd", "mkswap", "swapoff") or args[:2] == ["systemctl", "start"] for args in self.commands))

    def test_inactive_own_unit_resumes_a_partial_install(self):
        self.prepare()
        self.unit.write_text(swap.unit_contents())
        result = swap.install()
        self.assertTrue(result["active"])
        self.assertIn(["systemctl", "start", self.unit.name], self.commands)
        self.assertFalse(any(args[0] in ("dd", "mkswap") for args in self.commands))

    def test_disk_headroom_and_supported_filesystem_checked_before_creating_files(self):
        self.disk.return_value = SimpleNamespace(free=8191)
        self.error("insufficient_swap_disk", swap.install)
        self.assertFalse(self.root.exists())
        self.disk.return_value = SimpleNamespace(free=8192)
        for filesystem in ("btrfs", "nfs", "overlay", "tmpfs"):
            self.filesystem = filesystem
            self.error("unsupported_swap_filesystem", swap.install)
            self.assertFalse(self.root.exists())

    def test_allocation_failure_cleans_only_its_owned_inactive_file_and_can_retry(self):
        self.failure = "dd"
        self.error("command_failed", swap.install)
        self.assertFalse(swap.SWAP_FILE.exists())
        self.assertFalse(swap.MARKER.exists())
        self.failure = None
        self.assertTrue(swap.install()["active"])

    def test_conflicting_file_at_exclusive_create_does_not_gain_an_ownership_marker(self):
        self.root.mkdir()
        swap.SWAP_FILE.write_text("unrelated data")
        with self.assertRaises(FileExistsError): swap.allocate()
        self.assertFalse(swap.MARKER.exists())
        self.error("unmanaged_swap", swap.install)
        self.assertEqual(swap.SWAP_FILE.read_text(), "unrelated data")

    def test_interrupted_allocation_never_removes_a_replacement_inode(self):
        self.prepare("allocating")
        original = self.root / "original"
        swap.SWAP_FILE.rename(original)
        swap.SWAP_FILE.write_text("unrelated replacement")
        swap.SWAP_FILE.chmod(0o600)
        self.error("swap_file_replaced", swap.install)
        self.assertEqual(swap.SWAP_FILE.read_text(), "unrelated replacement")
        self.assertEqual(original.stat().st_size, swap.SWAP_BYTES)
        self.assertEqual(self.commands, [])

    def test_verified_partial_allocation_can_be_recreated_after_abrupt_interruption(self):
        self.prepare("allocating")
        self.assertTrue(swap.install()["active"])
        self.assertTrue(any(args[0] == "dd" for args in self.commands))

    def test_activation_configuration_failure_retains_prepared_file_for_retry(self):
        self.failure = "enable"
        self.error("command_failed", swap.install)
        identity = swap.SWAP_FILE.stat().st_ino
        self.assertEqual(json.loads(swap.MARKER.read_text())["phase"], "prepared")
        self.failure = None
        self.commands.clear()
        self.assertTrue(swap.install()["active"])
        self.assertEqual(swap.SWAP_FILE.stat().st_ino, identity)
        self.assertFalse(any(args[0] == "mkswap" for args in self.commands))

    def test_unmanaged_file_is_never_overwritten(self):
        self.root.mkdir()
        swap.SWAP_FILE.write_text("existing data")
        self.error("unmanaged_swap", swap.install)
        self.assertEqual(swap.SWAP_FILE.read_text(), "existing data")
        self.assertEqual(self.commands, [])

    def test_symlink_and_hardlink_swap_paths_are_refused(self):
        self.root.mkdir()
        outside = self.directory / "outside"
        outside.write_text("keep")
        swap.SWAP_FILE.symlink_to(outside)
        self.error("unsafe_swap_path", lambda: self.actual_protected(swap.SWAP_FILE))
        swap.SWAP_FILE.unlink()
        os.link(outside, swap.SWAP_FILE)
        self.error("unsafe_swap_file", lambda: swap.private_file(swap.SWAP_FILE))
        self.assertEqual(outside.read_text(), "keep")

    def test_rechecks_unit_after_daemon_reload_before_enable(self):
        self.prepare()
        original = self.command
        def mutate_unit(arguments, **options):
            if arguments == ["systemctl", "daemon-reload"]:
                self.unit.write_text("[Swap]\nWhat=/unrelated\n")
            return original(arguments, **options)
        with mock.patch.object(swap, "command", side_effect=mutate_unit):
            self.error("unmanaged_swap_unit", swap.install)
        self.assertFalse(any(args[:2] == ["systemctl", "enable"] for args in self.commands))

    def test_external_configuration_added_during_allocation_keeps_prepared_file_inactive(self):
        original = self.command
        def configure_elsewhere(arguments, **options):
            if arguments[0] == "mkswap": self.configured = True
            return original(arguments, **options)
        with mock.patch.object(swap, "command", side_effect=configure_elsewhere):
            result = swap.install()
        self.assertEqual(result["outcome"], "preserved")
        self.assertFalse(result["active"])
        self.assertIn("prepared swap file was left inactive", result["message"])
        self.assertTrue(swap.SWAP_FILE.exists())
        self.assertFalse(self.unit.exists())
        self.assertFalse(any(args[:2] == ["systemctl", "start"] for args in self.commands))

    def test_unknown_inventory_does_not_mutate(self):
        with mock.patch.object(swap, "read_swap_status", side_effect=PermissionError("cannot inspect")):
            with self.assertRaises(PermissionError): swap.install()
        self.assertFalse(self.root.exists())
        self.assertEqual(self.commands, [])

    def test_standalone_source_includes_shared_inventory(self):
        path = self.directory / "standalone.py"
        source = standalone_installer_source(Path(swap.__file__))
        self.assertIn("def read_swap_status(", source)
        path.write_text(source)
        result = subprocess.run([sys.executable, "-I", str(path), "--help"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cancellation_reaps_writer_and_removes_partial_allocation(self):
        source = self.directory / "source.py"
        source.write_text(standalone_installer_source(Path(swap.__file__)))
        harness = self.directory / "cancel.py"
        harness.write_text(CANCELLATION_HARNESS)
        process = subprocess.Popen([sys.executable, str(harness), str(source), str(self.directory)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.directory / "writer.pid").exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.directory / "writer.pid").exists())
            writer = int((self.directory / "writer.pid").read_text())
            process.send_signal(signal.SIGTERM)
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, errors.decode())
            self.assertEqual(output, b"cancelled and cleaned\n")
            with self.assertRaises(ProcessLookupError): os.kill(writer, 0)
            self.assertFalse((self.directory / "cancel-storage/swapfile").exists())
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()
            marker = self.directory / "writer.pid"
            if marker.exists():
                try: os.kill(int(marker.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass


CANCELLATION_HARNESS = r'''
import pathlib,sys
source,root=map(pathlib.Path,sys.argv[1:])
ns={'__name__':'fixture'}
exec(compile(source.read_text(),'<swap-cancel>','exec'),ns)
base=root/'cancel-storage';base.mkdir()
ns.update(ROOT=base,SWAP_FILE=base/'swapfile',MARKER=base/'.swap-managed.json',SWAP_BYTES=4096)
ns['protected']=lambda path:None
ns['check_storage']=lambda:None
ns['read_swap_status']=lambda **kwargs:{'activeSwapPaths':[]}
real_command=ns['command']
def command(arguments,**options):
    if arguments[0]=='dd':
        writer="import os,pathlib,signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path("+repr(str(root/'writer.pid'))+").write_text(str(os.getpid()));time.sleep(60)"
        return real_command([sys.executable,'-c',writer],timeout=60,live=False)
    raise AssertionError(arguments)
ns['command']=command
try:
    with ns['install_cancellation_scope']():ns['allocate']()
except ns['SwapError'] as error:
    assert error.code=='cancelled'
    print('cancelled and cleaned')
else:raise AssertionError('expected cancellation')
'''


if __name__ == "__main__":
    unittest.main()
