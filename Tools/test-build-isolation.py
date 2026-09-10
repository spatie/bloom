#!/usr/bin/env python3
"""Exercise build locks and publication with disposable bundles and mocked Mac commands."""
import os
import json
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(shutil.which("zsh"), "Installed builds use zsh")
class InstalledBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-isolation-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        for name in ("candidate", "installed"):
            bundle = self.base / name
            (bundle / "Contents").mkdir(parents=True)
            with (bundle / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "test.bloom.fixture"}, file)
            (bundle / "version").write_text(name)
        self.environment = dict(os.environ, HOME=str(self.base / "home"), FIXTURE=str(self.base), HELPER=str(ROOT / "Tools/isolated-build.sh"))
        self.preamble = '''set -euo pipefail
source "$HELPER"
bloom_refuse_if_own_host() { [[ "${FAIL_MODE:-}" != host ]]; }
bloom_app_pids() { if [[ -f "$FIXTURE/running" ]]; then print 123; fi; return 0; }
codesign() {
  print -r -- "sign $*" >> "$FIXTURE/events"
  [[ "${FAIL_MODE:-}" != sign ]] || return 1
  if [[ "$*" == *installing* && "${FAIL_MODE:-}" == verify ]]; then return 1; fi
  return 0
}
python3() {
  if [[ "$1" == *install-built-app.py && "${FAIL_MODE:-}" == publish ]]; then return 1; fi
  command python3 "$@"
}
ditto() {
  command python3 -c 'import shutil,sys; shutil.copytree(sys.argv[1], sys.argv[2], dirs_exist_ok=True)' "$1" "$2"
  [[ "${FAIL_MODE:-}" != copy ]]
}
osascript() {
  cat >/dev/null
  print quit >> "$FIXTURE/events"
  [[ "${FAIL_MODE:-}" != quit ]] || return 1
  rm "$FIXTURE/running"
}
'''

    def run_shell(self, body, **environment):
        return subprocess.run(["zsh", "-f", "-c", self.preamble + body],
                              env=dict(self.environment, **environment), capture_output=True, text=True, timeout=10)

    def publish(self, launch="0", **environment):
        return self.run_shell('''bloom_build_lock "$FIXTURE/install.lock"
bloom_sign_built_app "$FIXTURE/candidate"
bloom_publish_built_app "$FIXTURE/candidate" "$FIXTURE/installed" test.bloom.fixture "$FIXTURE/database" ''' + launch, **environment)

    def test_candidate_failures_keep_existing_bundle_and_release_locks(self):
        for mode in ("sign", "copy", "verify", "host", "publish"):
            with self.subTest(mode=mode):
                result = self.publish(FAIL_MODE=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.base / "installed/version").read_text(), "installed")
                self.assertFalse((self.base / "install.lock").exists())
                self.assertEqual(list(self.base.glob(".Bloom.installing.*")), [])

    def test_verified_candidate_is_published_after_the_running_app_quits(self):
        (self.base / "running").touch()
        result = self.publish("1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "installed/version").read_text(), "candidate")
        events = (self.base / "events").read_text().splitlines()
        self.assertEqual(events[-1], "quit")
        self.assertIn("installing", events[-2])
        self.assertFalse((self.base / "running").exists())

    def test_no_launch_and_failed_quit_preserve_the_running_installation(self):
        (self.base / "running").touch()
        for launch, mode in (("0", ""), ("1", "quit")):
            result = self.publish(launch, FAIL_MODE=mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((self.base / "running").exists())
            self.assertEqual((self.base / "installed/version").read_text(), "installed")

    def test_wrong_identity_and_destination_symlink_are_rejected(self):
        plist = self.base / "installed/Contents/Info.plist"
        with plist.open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "another.application"}, file)
        self.assertNotEqual(self.publish().returncode, 0)
        (self.base / "installed").rename(self.base / "other")
        (self.base / "installed").symlink_to(self.base / "other")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual((self.base / "other/version").read_text(), "installed")

    def test_second_builder_cannot_remove_the_first_builders_lock(self):
        body = self.preamble + '''bloom_build_lock "$FIXTURE/build.lock"
print ready
read answer
'''
        with subprocess.Popen(["zsh", "-f", "-c", body], env=self.environment,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as first:
            try:
                self.assertEqual(first.stdout.readline().strip(), "ready")
                second = self.run_shell('bloom_build_lock "$FIXTURE/build.lock"')
                self.assertNotEqual(second.returncode, 0)
                self.assertTrue((self.base / "build.lock").is_dir())
            finally:
                first.communicate("done\n", timeout=5)
        self.assertFalse((self.base / "build.lock").exists())
        self.assertEqual(self.run_shell('bloom_build_lock "$FIXTURE/build.lock"').returncode, 0)

    def test_master_stamps_candidate_before_signing_and_publication(self):
        # Execute the real publication stanza with fixture paths and shell command adapters.
        source = (ROOT / "Tools/master.sh").read_text().split("# Stamp the candidate", 1)[1]
        source = "# Stamp the candidate" + source.split("\ngit worktree remove", 1)[0]
        adapters = '''
BUILT="$FIXTURE/candidate"
DEST="$FIXTURE/installed"
RESOLVED=fixture-commit
BLOOM_REAL_BUNDLE_ID=test.bloom.fixture
BLOOM_REAL_DB="$FIXTURE/database"
LAUNCH=0
/usr/bin/defaults() {
  command python3 -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]); v=plistlib.loads(p.read_bytes()); v[sys.argv[2]]=sys.argv[3]; p.write_bytes(plistlib.dumps(v))' "$2" "$3" "$5"
}
codesign() {
  command python3 -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]); assert plistlib.loads((p/"Contents/Info.plist").read_bytes())["BloomMasterCommit"] == "fixture-commit"' "${@[-1]}"
  [[ "${FAIL_MODE:-}" != sign ]]
}
'''
        failed = self.run_shell(adapters + source, FAIL_MODE="sign")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual((self.base / "installed/version").read_text(), "installed")
        succeeded = self.run_shell(adapters + source)
        self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
        with (self.base / "installed/Contents/Info.plist").open("rb") as file:
            self.assertEqual(plistlib.load(file)["BloomMasterCommit"], "fixture-commit")

    def test_termination_releases_owned_locks(self):
        body = self.preamble + 'bloom_build_lock "$FIXTURE/build.lock"; print ready; read answer'
        with subprocess.Popen(["zsh", "-f", "-c", body], env=self.environment,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            try:
                self.assertEqual(process.stdout.readline().strip(), "ready")
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 143)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertFalse((self.base / "build.lock").exists())


class IOSBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-ios-isolation-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("BLOOM_IOS_")}
        self.environment["HOME"] = str(self.base / "home")
        for name in ("first", "second"):
            tools = self.base / name / "Tools"
            tools.mkdir(parents=True)
            shutil.copy2(ROOT / "Tools/ios-build-environment.sh", tools)

    def shell(self, checkout, body, **environment):
        source = self.base / checkout / "Tools/ios-build-environment.sh"
        return ["bash", "-c", 'set -euo pipefail; source "$1"; ' + body, "fixture", str(source)], dict(self.environment, **environment)

    def paths(self, checkout, **environment):
        command, env = self.shell(checkout, 'bloom_ios_begin archive; printf "%s\\n" "$project_dir" "$build_dir" "$archive_path"', **environment)
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_defaults_are_persistent_and_distinct_for_each_checkout(self):
        first = self.paths("first")
        self.assertEqual(first, self.paths("first"))
        second = self.paths("second")
        self.assertTrue(set(first).isdisjoint(second))
        self.assertTrue(all(path.startswith(str(self.base / "home")) for path in first + second))
        self.assertEqual(list(self.base.rglob("*.bloom-build.lock")), [])

    def test_explicit_shared_paths_lock_across_checkouts_and_cleanup_partial_acquisition(self):
        overrides = dict(BLOOM_IOS_PROJECT_DIR=str(self.base / "project"),
                         BLOOM_IOS_BUILD_DIR=str(self.base / "build"),
                         BLOOM_IOS_ARCHIVE_PATH=str(self.base / "archive"))
        self.assertEqual(self.paths("first", **overrides), list(overrides.values()))
        command, env = self.shell("first", 'bloom_ios_begin; echo ready; read -r answer', **overrides)
        with subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as first:
            try:
                self.assertEqual(first.stdout.readline().strip(), "ready")
                second_overrides = dict(overrides, BLOOM_IOS_PROJECT_DIR=str(self.base / "separate-project"))
                command, env = self.shell("second", 'bloom_ios_begin', **second_overrides)
                second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(second.returncode, 0)
                self.assertTrue((self.base / "build.bloom-build.lock").exists())
                self.assertFalse((self.base / "separate-project.bloom-build.lock").exists())
            finally:
                first.communicate("done\n", timeout=5)
        self.assertEqual(self.paths("second", **overrides), list(overrides.values()))

    def test_build_keeps_preparation_locks_until_xcodebuild_finishes(self):
        checkout = self.base / "first"
        for name in ("prepare-ios.sh", "build-ios.sh", "ios-project.py"):
            shutil.copy2(ROOT / "Tools" / name, checkout / "Tools" / name)
        (checkout / "Tools/check-ios-build-plugins.py").write_text("# Fixture plugin inspection.\n")
        (checkout / "LICENSE.md").write_text("fixture licence")
        build = self.base / "build"
        dependencies = ["SwiftTerm", "AppAuth-iOS", "swift-nio-ssh", "swift-nio", "swift-crypto",
                        "swift-atomics", "swift-collections", "swift-system", "swift-asn1"]
        for dependency in dependencies:
            path = build / "SourcePackages/checkouts" / dependency
            path.mkdir(parents=True)
            (path / "LICENSE").write_text("fixture licence")
        binaries = self.base / "bin"
        binaries.mkdir()
        xcodebuild = binaries / "xcodebuild"
        xcodebuild.write_text('#!/bin/bash\nif [[ "${!#}" == build ]]; then echo READY; read -r answer; fi\n')
        xcodebuild.chmod(0o755)
        environment = dict(self.environment, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                           BLOOM_IOS_PROJECT_DIR=str(self.base / "project"), BLOOM_IOS_BUILD_DIR=str(build))
        with subprocess.Popen(["bash", str(checkout / "Tools/build-ios.sh")], env=environment,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            try:
                while True:
                    line = process.stdout.readline()
                    self.assertTrue(line, "Fixture build exited before xcodebuild")
                    if line.strip() == "READY":
                        break
                result = subprocess.run(["bash", str(checkout / "Tools/prepare-ios.sh")], env=environment,
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Another iOS build owns", result.stderr)
                self.assertTrue((self.base / "project.bloom-build.lock").exists())
            finally:
                stdout, stderr = process.communicate("done\n", timeout=5)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertEqual(list(self.base.rglob("*.bloom-build.lock")), [])


@unittest.skipUnless(shutil.which("zsh") and shutil.which("rsync"), "Core snapshots use zsh and rsync")
class CoreTestSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-core-snapshot-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / "repo"
        tools = self.repo / "Tools"
        tools.mkdir(parents=True)
        for name in ("test-core.sh", "isolated-build.sh", "build-snapshot.py"):
            shutil.copy2(ROOT / "Tools" / name, tools)
        inputs = {
            "Package.swift": "// original root manifest",
            "Sources/BloomCore/Core.swift": "original core",
            "Sources/bloom-bridge/main.swift": "original shim",
            "Packages/BloomClient/Package.swift": "// client manifest",
            "Packages/BloomClient/Sources/BloomClient/Client.swift": "original client",
            "Tests/BloomCoreTests/CoreTests.swift": "original tests",
            "Tests/fixtures/session.json": "original fixture",
        }
        for name, value in inputs.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        binaries = self.base / "bin"
        binaries.mkdir()
        swift = binaries / "swift"
        swift.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if "--show-bin-path" in sys.argv:
    print(os.environ["TMPDIR"])
elif sys.argv[1] == "test":
    if os.environ.get("FIXTURE_PAUSE") == "1":
        print("READY", flush=True)
        input()
    names = ["Sources/BloomCore/Core.swift", "Packages/BloomClient/Sources/BloomClient/Client.swift", "Tests/fixtures/session.json"]
    record = {"directory": str(pathlib.Path.cwd()), "arguments": sys.argv[1:], "inputs": {name: pathlib.Path(name).read_text() for name in names}}
    with open(os.environ["FIXTURE_REPORT"], "a") as output:
        output.write(json.dumps(record) + "\\n")
''')
        swift.chmod(0o755)
        scratch = self.base / "temporary"
        scratch.mkdir()
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("BLOOM_TEST_")}
        self.environment.update(HOME=str(self.base / "home"), TMPDIR=str(scratch) + "/", BLOOM_TEST_ID="fixture",
                                PATH=str(binaries) + os.pathsep + os.environ["PATH"], FIXTURE_REPORT=str(self.base / "report"))
        self.command = ["zsh", str(tools / "test-core.sh"), "FirstFilter", "SecondFilter"]

    def reports(self):
        return [json.loads(line) for line in (self.base / "report").read_text().splitlines()]

    def test_inputs_stay_frozen_during_a_run_and_refresh_incrementally_for_the_next(self):
        temporary = Path(self.environment["TMPDIR"])
        work = temporary / "bloom-core-tests-fixture"
        work.mkdir()
        # Upgrade the previous live-symlink mirror without writing through it.
        (work / "Sources").mkdir()
        (work / "Sources/BloomCore").symlink_to(self.repo / "Sources/BloomCore")
        (work / "Packages").symlink_to(self.repo / "Packages")
        with subprocess.Popen(self.command, env=dict(self.environment, FIXTURE_PAUSE="1"),
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as first:
            try:
                self.assertEqual(first.stdout.readline().strip(), "READY")
                for name in ("Sources/BloomCore/Core.swift", "Packages/BloomClient/Sources/BloomClient/Client.swift", "Tests/fixtures/session.json"):
                    (self.repo / name).write_text("edited during test")
                second = subprocess.run(self.command, env=self.environment, capture_output=True, text=True, timeout=5)
                self.assertNotEqual(second.returncode, 0)
                self.assertIn("Another build owns", second.stderr)
            finally:
                stdout, stderr = first.communicate("continue\n", timeout=10)
            self.assertEqual(first.returncode, 0, stdout + stderr)
        record = self.reports()[0]
        self.assertEqual(list(record["inputs"].values()), ["original core", "original client", "original fixture"])
        self.assertFalse((work / "Sources/BloomCore").is_symlink())
        self.assertFalse((work / "Packages").is_symlink())
        stable = work / "Sources/bloom-bridge/main.swift"
        os.utime(stable, ns=(1_000_000_000, 1_000_000_000))
        scratch = temporary / "bloom-core-build-fixture"
        scratch.mkdir()
        (scratch / "existing.o").write_text("object")
        result = subprocess.run(self.command, env=self.environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.reports()[-1]["inputs"].values()), ["edited during test"] * 3)
        self.assertEqual(stable.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual((scratch / "existing.o").read_text(), "object")
        self.assertEqual((self.repo / "Package.swift").read_text(), "// original root manifest")

    def test_disposable_runs_cleanup_and_preserve_filters_repetitions_and_flags(self):
        environment = dict(self.environment, BLOOM_TEST_RUNS="2", BLOOM_TEST_SWIFT_ARGS="-j 2")
        environment.pop("BLOOM_TEST_ID")
        result = subprocess.run(self.command, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.reports()
        self.assertEqual(len(records), 2)
        arguments = records[0]["arguments"]
        self.assertEqual(arguments[-6:], ["-j", "2", "--filter", "FirstFilter", "--filter", "SecondFilter"])
        self.assertFalse(Path(records[0]["directory"]).exists())
        self.assertEqual(list(Path(environment["TMPDIR"]).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
