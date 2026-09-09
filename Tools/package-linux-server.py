#!/usr/bin/env python3
"""Bundle a trusted Linux build with its libraries, keeping the host's glibc and loader."""

import argparse
import hashlib
import json
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


# Mixing a bundled glibc with the host's dynamic loader is unsupported. Build on the oldest
# supported Ubuntu release; its glibc requirement is the package's minimum, even on newer hosts.
HOST_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1",
    "libresolv.so.2", "libutil.so.1", "libanl.so.1",
}


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def linked_libraries(binary):
    result = {}
    for line in run("ldd", str(binary)).splitlines():
        if "not found" in line:
            raise RuntimeError(f"Unresolved library: {line.strip()}")
        match = re.match(r"\s*(\S+) => (/\S+) \(", line)
        if match and match[1] not in HOST_LIBRARIES:
            result[match[1]] = pathlib.Path(match[2]).resolve()
    if not result:
        raise RuntimeError("Expected a dynamically linked Swift executable")
    return result


def copy_notice(source, destination):
    if not source.is_file() or not source.stat().st_size:
        raise RuntimeError(f"Missing licence notice: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def package(binary, output):
    if sys.platform != "linux":
        raise RuntimeError("Package inside the Ubuntu Swift build environment")
    release = dict(line.split("=", 1) for line in pathlib.Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') != "ubuntu" or release.get("VERSION_ID", "").strip('"') != "24.04" or platform.machine() != "x86_64":
        raise RuntimeError("The preview package must be built on Ubuntu 24.04 x86_64")
    swift_version = run("swift", "--version")
    if "Swift version 6.3.3 " not in swift_version:
        raise RuntimeError("Use Swift 6.3.3; update the runtime notices before changing toolchains")
    root = pathlib.Path(__file__).resolve().parent.parent
    libraries = linked_libraries(binary)
    target = json.loads(run("swift", "-print-target-info"))
    runtime_paths = [pathlib.Path(path).resolve() for path in target["paths"]["runtimeLibraryPaths"]]
    bundle_name = "bloom-server-linux-" + platform.machine()
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="bloom-linux-package-") as directory:
        bundle = pathlib.Path(directory) / bundle_name
        (bundle / "bin").mkdir(parents=True)
        (bundle / "lib").mkdir()
        notices = bundle / "licences"
        copy_notice(root / "LICENSE.md", notices / "Bloom.txt")
        swift_root = pathlib.Path(shutil.which("swift")).resolve().parent.parent
        copy_notice(swift_root / "share/swift/LICENSE.txt", notices / "Swift.txt")
        copy_notice(root / "Tools/server-licences/ICU.txt", notices / "ICU.txt")
        checkouts = root / ".build/checkouts"
        for dependency in ("swift-crypto", "swift-asn1"):
            checkout = checkouts / dependency
            copy_notice(checkout / "LICENSE.txt", notices / dependency / "LICENSE.txt")
            for notice in checkout.rglob("*"):
                if notice.is_file() and notice.name.upper().startswith(("LICENSE", "NOTICE")):
                    copy_notice(notice, notices / dependency / notice.relative_to(checkout))

        protocol = int(re.search(r"protocolVersion = (\d+)", (root / "Sources/BloomCore/Server/ServerProtocol.swift").read_text())[1])
        manifest = {"protocolVersion": protocol, "architecture": platform.machine(), "glibc": run("getconf", "GNU_LIBC_VERSION"),
                    "swift": swift_version, "libraries": {}}
        for name, source in sorted(libraries.items()):
            destination = bundle / "lib" / name
            shutil.copy2(source, destination)
            # RUNPATH is local to each ELF object. Setting it on the executable alone does not
            # cover indirect Foundation/ICU dependencies. Avoid LD_LIBRARY_PATH, which would
            # also change library resolution in the agent processes the server launches.
            run("patchelf", "--set-rpath", "$ORIGIN", str(destination))
            manifest["libraries"][name] = hashlib.sha256(source.read_bytes()).hexdigest()
            if not any(source.is_relative_to(path) for path in runtime_paths):
                owner = run("dpkg-query", "-S", str(source)).splitlines()[0].split(": ", 1)[0].split(":")[0]
                copy_notice(pathlib.Path("/usr/share/doc") / owner / "copyright", notices / (owner + ".txt"))

        executable = bundle / "bin/bloom-server"
        shutil.copy2(binary, executable)
        run("patchelf", "--set-rpath", "$ORIGIN/../lib", str(executable))
        (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (bundle / "README.txt").write_text(
            "Bloom server preview\n\n"
            "Keep bin/ and lib/ together. No Swift installation is needed.\n"
            "Built for Ubuntu 24.04 x86_64 and newer compatible systems.\n"
            "Install Git and your authenticated agent CLIs on the server.\n"
            "Run: bin/bloom-server serve --data-dir /absolute/private/directory\n"
            "The data directory must belong to the service user and have mode 700.\n"
            "See https://github.com/spatie/bloom/blob/freekmurze/client-server-runtime/docs/SERVER.md\n"
        )
        # Fail before producing an archive if relocation left an unresolved dependency.
        relocated = linked_libraries(executable)
        if any(not path.is_relative_to(bundle) for path in relocated.values()):
            raise RuntimeError("A bundled dependency still resolves outside the package")
        run(str(executable), "--help")
        with tarfile.open(output, "w:gz") as archive:
            archive.add(bundle, arcname=bundle.name)
    print(f"Packaged {output} ({output.stat().st_size // 1_048_576} MiB)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    arguments = parser.parse_args()
    package(arguments.binary.resolve(), arguments.output.resolve())
