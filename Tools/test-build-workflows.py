#!/usr/bin/env python3
"""Exercise isolated source snapshots, app publication and Remote option handling without compiling apps."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Tools" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


snapshot = load("build-snapshot")
publication = load("install-built-app")


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-build-workflow-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / "checkout"
        self.repo.mkdir()
        self.stage = self.base / "stage"
        self.stage.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)

    def track(self, name, content="original"):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        subprocess.run(["git", "-C", str(self.repo), "add", "--", name], check=True)
        return path

    def test_current_edits_new_files_deletions_and_ignored_builds(self):
        existing = self.track("Sources/Existing.swift")
        existing.write_text("working edit")
        self.track("deleted.txt").unlink()
        (self.repo / "new file\nwith space.swift").write_text("new")
        (self.repo / ".gitignore").write_text("*.ignored\n")
        (self.repo / "secret.ignored").write_text("excluded")
        self.track(".build/previous.swift", "build cache")
        snapshot.snapshot(self.repo, self.stage)
        self.assertEqual((self.stage / "Sources/Existing.swift").read_text(), "working edit")
        self.assertTrue((self.stage / "new file\nwith space.swift").exists())
        for path in ["deleted.txt", "secret.ignored", ".git", ".build"]:
            self.assertFalse((self.stage / path).exists(), path)

    def test_executable_and_symlink_identity_are_preserved(self):
        file = self.track("Tools/run")
        file.chmod(0o755)
        (self.repo / "link").symlink_to("Tools/run")
        snapshot.snapshot(self.repo, self.stage)
        self.assertEqual((self.stage / "Tools/run").stat().st_mode & 0o777, 0o755)
        self.assertTrue((self.stage / "link").is_symlink())
        self.assertEqual(os.readlink(self.stage / "link"), "Tools/run")

    def test_replaced_directory_symlink_does_not_copy_external_descendants(self):
        file = self.track("folder/tracked.txt")
        file.unlink(); file.parent.rmdir()
        outside = self.base / "external"
        outside.mkdir()
        (outside / "tracked.txt").write_text("outside must remain unchanged")
        (self.repo / "folder").symlink_to(outside, target_is_directory=True)
        snapshot.snapshot(self.repo, self.stage)
        self.assertTrue((self.stage / "folder").is_symlink())
        self.assertEqual((outside / "tracked.txt").read_text(), "outside must remain unchanged")

    def test_nested_staging_is_rejected_before_recursive_copy(self):
        nested = self.repo / "snapshot"
        nested.mkdir()
        with self.assertRaisesRegex(ValueError, "outside"):
            snapshot.snapshot(self.repo, nested)
        self.assertEqual(list(nested.iterdir()), [])

    def test_identity_transform_refuses_external_file_and_parent_symlinks(self):
        outside = self.base / "external-plist"
        outside.write_text("original identity")
        resources = self.stage / "Resources"
        resources.mkdir()
        (resources / "Info.plist").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            snapshot.check_inputs(self.stage, ["Resources/Info.plist"])
        self.assertEqual(outside.read_text(), "original identity")
        (resources / "Info.plist").unlink()
        resources.rmdir()
        resources.symlink_to(self.base, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            snapshot.check_inputs(self.stage, ["Resources/external-plist"])
        self.assertEqual(outside.read_text(), "original identity")

    @unittest.skipUnless(shutil.which("rsync"), "rsync is required by fast builds")
    def test_sync_retains_unchanged_mtimes_and_removes_deleted_files(self):
        self.track("source.swift")
        snapshot.snapshot(self.repo, self.stage)
        cache = self.base / "cache"
        snapshot.sync(self.stage, cache)
        source = cache / "source.swift"
        os.utime(source, ns=(1_000_000_000, 1_000_000_000))
        (cache / "removed.swift").write_text("old")
        (cache / ".build").symlink_to(self.base / "build")
        snapshot.sync(self.stage, cache)
        self.assertEqual(source.stat().st_mtime_ns, 1_000_000_000)
        self.assertFalse((cache / "removed.swift").exists())
        self.assertTrue((cache / ".build").is_symlink())
        (self.stage / "source.swift").write_text("changed")
        snapshot.sync(self.stage, cache)
        self.assertEqual(source.read_text(), "changed")

    def structure_fixture(self):
        self.track("Package.swift", "// root manifest")
        self.track("Packages/Local/Package.swift", "// local manifest")
        self.track("Packages/Local/Package.resolved", "first resolution")
        self.track("Packages/Local/Sources/Local/Existing.swift", "existing source")
        self.track("Packages/Local/Sources/Local/Resources/first.txt", "resource")
        snapshot.snapshot(self.repo, self.stage)
        cache = self.base / "cache"
        snapshot.sync(self.stage, cache)
        return cache

    @unittest.skipUnless(shutil.which("rsync"), "rsync is required by fast builds")
    def test_dependency_membership_and_manifest_changes_replan_without_touching_sources(self):
        cache = self.structure_fixture()
        manifest = cache / "Package.swift"
        existing = cache / "Packages/Local/Sources/Local/Existing.swift"
        os.utime(existing, ns=(2_000_000_000, 2_000_000_000))
        local = self.stage / "Packages/Local"
        changes = [
            lambda: (local / "Sources/Local/Added.swift").write_text("new source"),
            lambda: (local / "Sources/Local/Added.swift").unlink(),
            lambda: (local / "Sources/Local/Resources/second.txt").write_text("new resource"),
            lambda: (local / "Sources/Local/Resources/first.txt").unlink(),
            lambda: (local / "Package.swift").write_text("// changed local manifest"),
            lambda: (local / "Package.resolved").write_text("changed resolution"),
        ]
        for index, change in enumerate(changes):
            with self.subTest(change=index):
                os.utime(manifest, ns=(1_000_000_000, 1_000_000_000))
                change()
                snapshot.sync(self.stage, cache)
                self.assertGreater(manifest.stat().st_mtime_ns, 1_000_000_000)
                self.assertEqual(existing.stat().st_mtime_ns, 2_000_000_000)

    @unittest.skipUnless(shutil.which("rsync"), "rsync is required by fast builds")
    def test_source_content_edits_and_warm_sync_keep_the_plan_timestamp(self):
        cache = self.structure_fixture()
        manifest = cache / "Package.swift"
        os.utime(manifest, ns=(1_000_000_000, 1_000_000_000))
        (self.stage / "Packages/Local/Sources/Local/Existing.swift").write_text("edited source")
        snapshot.sync(self.stage, cache)
        self.assertEqual(manifest.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual((cache / "Packages/Local/Sources/Local/Existing.swift").read_text(), "edited source")
        snapshot.sync(self.stage, cache)
        self.assertEqual(manifest.stat().st_mtime_ns, 1_000_000_000)

    @unittest.skipUnless(shutil.which("rsync"), "rsync is required by fast builds")
    def test_older_cache_without_structure_marker_replans_once_and_retains_objects(self):
        cache = self.structure_fixture()
        marker = cache.with_name(".cache-package-structure")
        marker.unlink()
        manifest = cache / "Package.swift"
        source = cache / "Packages/Local/Sources/Local/Existing.swift"
        os.utime(manifest, ns=(1_000_000_000, 1_000_000_000))
        os.utime(source, ns=(2_000_000_000, 2_000_000_000))
        build = self.base / "objects"
        build.mkdir()
        (build / "existing.o").write_text("object")
        (cache / ".build").symlink_to(build)
        snapshot.sync(self.stage, cache)
        self.assertGreater(manifest.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual(source.stat().st_mtime_ns, 2_000_000_000)
        self.assertEqual((build / "existing.o").read_text(), "object")
        self.assertTrue(marker.is_file())
        refreshed = manifest.stat().st_mtime_ns
        snapshot.sync(self.stage, cache)
        self.assertEqual(manifest.stat().st_mtime_ns, refreshed)

    @unittest.skipUnless(shutil.which("swift") and shutil.which("rsync"), "Requires SwiftPM and rsync")
    def test_swiftpm_finds_a_new_local_dependency_source_in_a_warm_build(self):
        self.track("Package.swift", '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SnapshotFixture", dependencies: [.package(path: "Packages/Local")],
    targets: [.target(name: "App", dependencies: [.product(name: "Local", package: "Local")])])
''')
        self.track("Packages/Local/Package.swift", '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Local", products: [.library(name: "Local", targets: ["Local"])], targets: [.target(name: "Local")])
''')
        self.track("Packages/Local/Sources/Local/Existing.swift", "public let oldValue = 1")
        self.track("Sources/App/App.swift", "import Local\npublic func sample() -> Int { oldValue }")
        snapshot.snapshot(self.repo, self.stage)
        cache = self.base / "cache"
        snapshot.sync(self.stage, cache)
        def build():
            result = subprocess.run(["swift", "build", "--package-path", str(cache), "--target", "App", "-j", "2"],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build()
        (self.stage / "Packages/Local/Sources/Local/New.swift").write_text("public let newValue = 2")
        (self.stage / "Sources/App/App.swift").write_text("import Local\npublic func sample() -> Int { newValue }")
        snapshot.sync(self.stage, cache)
        build()


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bloom-app-publication-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.staging, self.destination = base / "staging", base / "installed"
        self.staging.mkdir(); self.destination.mkdir()
        (self.staging / "version").write_text("new")
        (self.destination / "version").write_text("old")

    def test_failed_exchange_keeps_installed_bundle(self):
        def failure(*args):
            raise OSError("fixture publication failure")
        with self.assertRaises(OSError):
            publication.install(self.staging, self.destination, swap=failure)
        self.assertEqual((self.destination / "version").read_text(), "old")
        self.assertEqual((self.staging / "version").read_text(), "new")

    def test_atomic_exchange_publishes_candidate_and_cleans_old_bundle(self):
        publication.install(self.staging, self.destination)
        self.assertEqual((self.destination / "version").read_text(), "new")
        self.assertFalse(self.staging.exists())

    def test_symlink_destination_is_refused(self):
        link = self.destination.parent / "alias"
        link.symlink_to(self.destination, target_is_directory=True)
        with self.assertRaises(ValueError):
            publication.install(self.staging, link)
        self.assertEqual((self.destination / "version").read_text(), "old")


@unittest.skipUnless(shutil.which("zsh"), "Remote build uses zsh")
class RemoteOptionsTests(unittest.TestCase):
    def parse(self, *arguments, legacy=False):
        # Run the script's real option parser, stopping before any cache or app access.
        source = (ROOT / "Tools/remote-build.sh").read_text().split('resolved="', 1)[0]
        source = source.replace('cd "$(dirname "$0")/.."', 'cd "$BLOOM_PARSER_FIXTURE_ROOT"')
        source += '\nprint -r -- "$fast|$install|$launch|$legacy_export|$ref"\n'
        environment = dict(os.environ, BLOOM_PARSER_FIXTURE_ROOT=str(ROOT), BLOOM_REMOTE_BUILD_ONLY="1" if legacy else "0")
        return subprocess.run(["zsh", "-f", "-c", source, "fixture", *arguments], env=environment, capture_output=True, text=True)

    def test_fast_no_install_never_launches_regardless_of_order(self):
        for arguments in [("--fast", "--no-install", "--launch"), ("--launch", "--fast", "--no-install")]:
            result = self.parse(*arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "1|0|0|0|HEAD")

    def test_release_default_and_legacy_export_are_preserved(self):
        self.assertEqual(self.parse("main").stdout.strip(), "0|1|0|0|main")
        self.assertEqual(self.parse("--launch", legacy=True).stdout.strip(), "0|0|0|1|HEAD")
        self.assertEqual(self.parse("--fast", "--launch", "--no-launch").stdout.strip(), "1|1|0|0|HEAD")

    def test_conflicting_revision_and_unknown_options_are_refused(self):
        for arguments in [("--fast", "HEAD"), ("HEAD", "main"), ("--unknown",)]:
            self.assertNotEqual(self.parse(*arguments).returncode, 0)


if __name__ == "__main__":
    unittest.main()
