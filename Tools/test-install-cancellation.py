#!/usr/bin/env python3
"""Real parent signals must reap installer file workers, without requiring root privileges."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from bloom_install_process import install_cancellation_scope


class InstallerSignalTests(unittest.TestCase):
    def test_nested_signal_scopes_restore_handlers_after_failure(self):
        original = signal.getsignal(signal.SIGTERM)
        with self.assertRaisesRegex(ValueError, "fixture"):
            with install_cancellation_scope():
                parent_handler = signal.getsignal(signal.SIGTERM)
                with install_cancellation_scope():
                    self.assertIsNot(signal.getsignal(signal.SIGTERM), parent_handler)
                self.assertIs(signal.getsignal(signal.SIGTERM), parent_handler)
                raise ValueError("fixture")
        self.assertIs(signal.getsignal(signal.SIGTERM), original)

    def test_termination_and_hangup_reap_account_worker(self):
        for stop_signal in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=stop_signal), tempfile.TemporaryDirectory(prefix="bloom-installer-signal-") as directory:
                ready = Path(directory) / "worker.pid"
                code = r'''
import importlib.util, os, pathlib, signal, sys, time, types
spec = importlib.util.spec_from_file_location("installer", pathlib.Path(sys.argv[1]) / "install-bloom-server.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
account = types.SimpleNamespace(pw_uid=os.getuid() + 1, pw_gid=os.getgid(), pw_dir=sys.argv[2])
# Existing Linux-only tests cover real privilege dropping. This fixture exercises the real
# fork, signals and waitpid as the test user, so it runs on both macOS and Linux.
installer.os.setgroups = lambda value: None
installer.os.setgid = lambda value: None
installer.os.setuid = lambda value: None
installer.os.geteuid = lambda: account.pw_uid
def work():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pathlib.Path(sys.argv[2], "worker.pid").write_text(str(os.getpid()))
    time.sleep(60)
try:
    installer.account_operation(account, work)
except installer.InstallError as error:
    print(error.code, flush=True)
    sys.exit(0 if error.code == "cancelled" else 2)
'''
                tools = Path(__file__).resolve().parent
                environment = dict(os.environ, PYTHONPATH=str(tools), PYTHONDONTWRITEBYTECODE="1")
                process = subprocess.Popen([sys.executable, "-c", code, str(tools), directory],
                                           env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), "The fixture worker did not start")
                    worker = int(ready.read_text())
                    os.kill(process.pid, stop_signal)
                    time.sleep(0.03)
                    if process.poll() is None:
                        os.kill(process.pid, stop_signal)
                    output, error = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, error)
                    self.assertEqual(output.strip(), "cancelled")
                    with self.assertRaises(ProcessLookupError):
                        os.kill(worker, 0)
                finally:
                    # Even a regression must not leave the fixture's worker behind.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
