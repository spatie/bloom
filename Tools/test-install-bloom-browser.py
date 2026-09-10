#!/usr/bin/env python3
"""Browser installer safety tests, no apt, downloads or browser launches."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

spec = importlib.util.spec_from_file_location("browser", Path(__file__).with_name("install-bloom-browser.py"))
browser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browser)


class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def error(self, code, callback):
        with self.assertRaises(browser.BrowserError) as error:
            callback()
        self.assertEqual(error.exception.code, code)

    def archive(self, name, mode=stat.S_IFREG | 0o4755, contents=b"chrome"):
        path = self.root / "chrome.zip"
        with zipfile.ZipFile(path, "w") as archive:
            info = zipfile.ZipInfo(name)
            info.external_attr = mode << 16
            archive.writestr(info, contents)
        return path

    def test_wizard_stdin_source_creates_standalone_launchers_without_file_global(self):
        script = Path(__file__).with_name("install-bloom-browser.py")
        source = browser.standalone_installer_source(script)
        namespace = {"__name__": "browser_wizard_fixture", "__bloom_browser_source": source}
        exec(compile(source, "<bloom-browser>", "exec"), namespace)
        self.assertNotIn("__file__", namespace)
        launcher = namespace["launcher_source"]()
        self.assertEqual(launcher, source)
        self.assertIn("class InstallProcessFailure(", launcher)
        copied = self.root / "standalone-browser-installer.py"
        copied.write_text(launcher)
        result = subprocess.run([sys.executable, "-I", str(copied), "--help"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--service-home", result.stdout)

    def test_browser_state_is_inside_bloom_while_the_trusted_bundle_stays_protected(self):
        self.assertEqual(browser.browser_state("/home/bloom"), Path("/home/bloom/bloom/data/browser"))
        self.assertEqual(browser.ROOT, Path("/opt/bloom-browser"))

    def test_direct_file_install_also_embeds_helper_into_its_launchers(self):
        launcher = browser.launcher_source()
        self.assertTrue(launcher.startswith("#!/usr/bin/env python3\n"))
        self.assertIn("class InstallProcessFailure(", launcher)
        self.assertTrue(launcher.endswith(Path(__file__).with_name("install-bloom-browser.py").read_text()))

    def test_browser_command_failure_redacts_output_and_preserves_exit_status(self):
        with self.assertRaises(browser.BrowserError) as caught:
            browser.command([sys.executable, "-c", "import sys;print('password=hidden-password');print('missing library');sys.exit(12)"])
        self.assertEqual(caught.exception.metadata["exitStatus"], 12)
        self.assertIn("missing library", caught.exception.metadata["details"])
        self.assertNotIn("hidden-password", str(caught.exception) + str(caught.exception.metadata))
        self.assertNotIn("-c", caught.exception.metadata["command"])

    def test_browser_command_timeout_keeps_actionable_metadata(self):
        with self.assertRaises(browser.BrowserError) as caught:
            browser.command([sys.executable, "-c", "import time;print('waiting',flush=True);time.sleep(60)"], timeout=.1)
        self.assertEqual(caught.exception.code, "command_timeout")
        self.assertIn("waiting", caught.exception.metadata["details"])
        self.assertIn("remains available", caught.exception.recovery)

    def test_generic_browser_failure_preserves_redacted_exception_details(self):
        error = OSError(13, "Permission denied", "https://user:private-password@mirror.example/browser?token=private-token")
        with mock.patch.object(browser, "main", side_effect=error), mock.patch.object(browser, "emit") as emit:
            status = browser.entrypoint()
        self.assertEqual(status, 1)
        value = emit.call_args.kwargs
        self.assertEqual(value["code"], "browser_setup_failed")
        self.assertIn("PermissionError", value["details"])
        self.assertIn("Permission denied", value["details"])
        self.assertIn("https://mirror.example/browser", value["details"])
        self.assertNotIn("private-", str(value))
        self.assertNotIn("exitStatus", value)

    def test_extract_strips_setuid_and_preserves_readable_directories(self):
        destination = self.root / "release"
        destination.mkdir()
        archive = self.archive("chrome-linux64/chrome")
        mask = os.umask(0o077)
        try:
            browser.extract_chrome(archive, destination)
        finally:
            os.umask(mask)
        self.assertEqual((destination / "chrome-linux64/chrome").stat().st_mode & 0o7777, 0o755)
        self.assertEqual((destination / "chrome-linux64").stat().st_mode & 0o7777, 0o755)

    def test_archive_rejects_traversal_absolute_and_symbolic_links(self):
        for name, mode in [("../escape", stat.S_IFREG), ("/escape", stat.S_IFREG), ("chrome/link", stat.S_IFLNK)]:
            with self.subTest(name=name):
                archive = self.archive(name, mode)
                self.error("unsafe_archive", lambda: browser.extract_chrome(archive, self.root / "release"))
        self.assertFalse((self.root / "release").exists())

    def test_download_requires_pinned_checksum(self):
        response = io.BytesIO(b"tampered binary")
        response.url = "https://downloads.example/browser"
        with mock.patch.object(browser.urllib.request, "urlopen", return_value=response):
            self.error("checksum_mismatch", lambda: browser.download(response.url, self.root / "binary", "0" * 64))

    def test_download_rejects_insecure_redirect(self):
        response = io.BytesIO(b"binary")
        response.url = "http://downloads.example/browser"
        with mock.patch.object(browser.urllib.request, "urlopen", return_value=response):
            self.error("insecure_download", lambda: browser.download("https://example/browser", self.root / "binary", hashlib.sha256(b"binary").hexdigest()))

    def test_chrome_guard_rejects_upstream_automatic_sandbox_bypass(self):
        for flag in ("--no-sandbox", "--no-sandbox=true", "--disable-namespace-sandbox", "--disable-seccomp-filter-sandbox", "--single-process", "--remote-debugging-address=0.0.0.0", "--remote-debugging-port=9222"):
            with self.subTest(flag=flag):
                self.error("unsafe_browser_flags", lambda: browser.chrome_arguments(["--headless=new", flag]))

    def test_chrome_guard_keeps_ephemeral_loopback(self):
        arguments = browser.chrome_arguments(["--headless=new", "--remote-debugging-port=0"])
        self.assertEqual(arguments[-1], "--remote-debugging-address=127.0.0.1")
        self.assertNotIn("--no-sandbox", arguments)

    def test_sandbox_requires_actual_namespace_pid_network_and_seccomp_reports(self):
        healthy = "Layer 1 Sandbox\tNamespace\nPID namespaces\tYes\nNetwork namespaces\tYes\nSeccomp-BPF sandbox\tYes"
        self.assertTrue(all(browser.sandbox_status(healthy).values()))
        for label in ("Layer 1 Sandbox\tNamespace", "PID namespaces\tYes", "Network namespaces\tYes", "Seccomp-BPF sandbox\tYes"):
            with self.subTest(label=label):
                self.assertFalse(all(browser.sandbox_status(healthy.replace(label, "Unavailable")).values()))
        self.assertFalse(all(browser.sandbox_status("Chrome launched successfully without --no-sandbox").values()))

    def test_profile_rejects_symlinks_and_other_user_readable_state(self):
        profile = self.root / "profile"
        profile.symlink_to(self.root, target_is_directory=True)
        self.error("unsafe_profile", lambda: browser.private_directory(profile))
        profile.unlink()
        profile.mkdir(mode=0o755)
        self.error("unsafe_profile", lambda: browser.private_directory(profile))
        profile.chmod(0o700)
        browser.private_directory(profile)

    def test_container_provisioning_fails_before_apt(self):
        options = mock.Mock(user="bloom", service_home="/var/lib/bloom-home")
        with mock.patch.object(browser.platform, "system", return_value="Linux"), mock.patch.object(browser.platform, "machine", return_value="x86_64"), mock.patch.object(browser.os, "geteuid", return_value=0), mock.patch.object(browser, "container_environment", return_value=True), mock.patch.object(browser, "dependencies") as dependencies:
            self.error("container_unsupported", lambda: browser.install(options))
            dependencies.assert_not_called()

    def test_cdp_requires_an_actual_loopback_listener(self):
        def read(path, *args, **kwargs):
            if path.name == "DevToolsActivePort":
                return "41234\n/devtools/browser/test\n"
            if path.name == "tcp":
                return "header\n0: 0100007F:A112 00000000:0000 0A remainder\n"
            return "header\n"
        with mock.patch.object(Path, "read_text", read), mock.patch.object(Path, "exists", return_value=True):
            self.assertTrue(browser.loopback_evidence(self.root)["loopbackOnly"])
        def public(path, *args, **kwargs):
            return read(path, *args, **kwargs).replace("0100007F", "00000000")
        with mock.patch.object(Path, "read_text", public), mock.patch.object(Path, "exists", return_value=True):
            self.error("debugging_not_private", lambda: browser.loopback_evidence(self.root))

    def test_root_never_launches_browser(self):
        config = {"user": "bloom", "uid": 1001, "chrome": "/chrome", "agentBrowser": "/agent", "emptyConfig": "/config", "chromeGuard": "/guard"}
        with mock.patch.object(browser, "protected"), mock.patch.object(Path, "read_text", return_value=__import__("json").dumps(config)), mock.patch.object(browser.os, "geteuid", return_value=0):
            self.error("wrong_user", browser.checked_runtime_config)

    def test_renderer_evidence_handles_chrome_rewritten_process_titles(self):
        process = self.root / "123"
        process.mkdir()
        (process / "exe").symlink_to("/protected/chrome")
        (process / "status").write_text("Seccomp:\t2\nNoNewPrivs:\t1\n")
        arguments = ["/protected/chrome", "--type=renderer", "--user-data-dir=/profile"]
        for delimiter in ("\0", " "):
            with self.subTest(delimiter=delimiter):
                (process / "cmdline").write_bytes((delimiter.join(arguments) + "\0").encode())
                self.assertTrue(browser.process_evidence("/protected/chrome", os.getuid(), "/profile", self.root)[0]["renderer"])
        self.error("sandbox_unverified", lambda: browser.process_evidence("/protected/chrome", os.getuid(), "/other-profile", self.root))
        (process / "exe").unlink()
        (process / "exe").symlink_to("/untrusted/program")
        self.error("sandbox_unverified", lambda: browser.process_evidence("/protected/chrome", os.getuid(), "/profile", self.root))

    def test_install_does_not_replace_another_service_accounts_browser(self):
        service_uid = 12345
        (self.root / "configuration.json").write_text(json.dumps({"uid": service_uid + 1, "serviceHome": "/another/home"}))
        options = mock.Mock(user="bloom", service_home=str(self.root))
        account = mock.Mock(pw_uid=service_uid)
        original_read = Path.read_text
        original_stat = Path.stat
        def service_home_stat(path, *args, **kwargs):
            info = original_stat(path, *args, **kwargs)
            if path == self.root:
                fields = list(info)
                fields[4] = service_uid
                return os.stat_result(fields)
            return info
        def read(path, *args, **kwargs):
            if str(path) == "/etc/os-release":
                return 'ID=ubuntu\nVERSION_ID="24.04"\n'
            return original_read(path, *args, **kwargs)
        with mock.patch.object(browser, "ROOT", self.root), mock.patch.object(browser, "protected"), mock.patch.object(browser, "container_environment", return_value=False), mock.patch.object(browser.platform, "system", return_value="Linux"), mock.patch.object(browser.platform, "machine", return_value="x86_64"), mock.patch.object(browser.os, "geteuid", return_value=0), mock.patch.object(browser.pwd, "getpwnam", return_value=account), mock.patch.object(Path, "read_text", read), mock.patch.object(Path, "stat", service_home_stat), mock.patch.object(browser, "dependencies") as dependencies:
            self.error("different_service_user", lambda: browser.install(options))
            account.pw_uid = 0
            self.error("invalid_service_user", lambda: browser.install(options))
            dependencies.assert_not_called()


if __name__ == "__main__":
    unittest.main()
