#!/usr/bin/env python3
"""Verify shipped library hashes with a disposable package and a simulated ELF relocation."""

import hashlib
import importlib.util
import json
import pathlib
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("linux_package", pathlib.Path(__file__).with_name("package-linux-server.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageManifestTests(unittest.TestCase):
    def test_manifest_hashes_relocated_archive_bytes_not_original_libraries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            repo = root / "repo"
            toolchain = root / "toolchain/usr"
            runtime = toolchain / "lib/swift/linux"
            library = runtime / "libswiftCore.so"
            binary = repo / ".build/debug/bloom-server"
            files = {
                repo / "LICENSE.md": "Bloom licence",
                repo / "Tools/server-licences/ICU.txt": "ICU licence",
                repo / "Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift": "public enum BloomWire {\n    public static let version = 15\n}\n",
                repo / ".build/checkouts/swift-crypto/LICENSE.txt": "Crypto licence",
                repo / ".build/checkouts/swift-asn1/LICENSE.txt": "ASN.1 licence",
                toolchain / "share/swift/LICENSE.txt": "Swift licence",
                toolchain / "bin/swift": "Swift fixture",
                library: "Original shared library",
                binary: "Server fixture",
                binary.with_name("bloom-bridge"): "Bridge fixture",
            }
            for path, contents in files.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            original_hash = hashlib.sha256(library.read_bytes()).hexdigest()

            def run(*arguments):
                if arguments == ("swift", "--version"):
                    return "Swift version 6.3.3 (fixture)"
                if arguments == ("swift", "-print-target-info"):
                    return json.dumps({"paths": {"runtimeLibraryPaths": [str(runtime)]}})
                if arguments == ("getconf", "GNU_LIBC_VERSION"):
                    return "glibc 2.39"
                if arguments[0] == "ldd":
                    candidate = pathlib.Path(arguments[1]).parent.parent / "lib/libswiftCore.so"
                    selected = candidate if candidate.exists() else library
                    return f"libswiftCore.so => {selected} (0x1234)"
                if arguments[0] == "patchelf":
                    destination = pathlib.Path(arguments[-1])
                    destination.write_bytes(destination.read_bytes() + b"\nRelocated RPATH")
                    return ""
                if arguments[-1] == "--help":
                    return "Bloom server"
                raise AssertionError(f"Unexpected packaging subprocess: {arguments}")

            read_text = pathlib.Path.read_text

            def fixture_text(path, *args, **kwargs):
                if path == pathlib.Path("/etc/os-release"):
                    return 'ID=ubuntu\nVERSION_ID="24.04"\n'
                return read_text(path, *args, **kwargs)

            output = root / "server.tar.gz"
            temporary_directory = tempfile.TemporaryDirectory
            with mock.patch.object(package.sys, "platform", "linux"), \
                    mock.patch.object(package.platform, "machine", return_value="x86_64"), \
                    mock.patch.object(package, "__file__", str(repo / "Tools/package-linux-server.py")), \
                    mock.patch.object(package.shutil, "which", return_value=str(toolchain / "bin/swift")), \
                    mock.patch.object(package, "run", side_effect=run), \
                    mock.patch.object(package.tempfile, "TemporaryDirectory", side_effect=lambda **kwargs: temporary_directory(dir=root, **kwargs)), \
                    mock.patch.object(pathlib.Path, "read_text", fixture_text), \
                    mock.patch.dict(package.os.environ, {"BLOOM_SERVER_VERSION": "1.2.3"}):
                package.package(binary, output)
            with tarfile.open(output) as archive:
                manifest = json.load(archive.extractfile("bloom-server-linux-x86_64/manifest.json"))
                shipped = archive.extractfile("bloom-server-linux-x86_64/lib/libswiftCore.so").read()
            self.assertEqual(manifest["libraries"]["libswiftCore.so"], hashlib.sha256(shipped).hexdigest())
            self.assertNotEqual(manifest["libraries"]["libswiftCore.so"], original_hash)
            self.assertEqual(hashlib.sha256(library.read_bytes()).hexdigest(), original_hash)


if __name__ == "__main__":
    unittest.main()
