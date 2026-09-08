#!/usr/bin/env python3
"""Check service identities in disposable bundles without registering any background service."""

import importlib.util
import pathlib
import plistlib
import sys
import tempfile

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "server_packaging", pathlib.Path(__file__).with_name("prepare-server-service.py"),
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def bundle_at(root, name, application_id, has_server=True):
    bundle = root / (name + ".app")
    (bundle / "Contents/MacOS").mkdir(parents=True)
    with (bundle / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": application_id}, output)
    if has_server:
        (bundle / "Contents/MacOS/bloom-server").touch()
    return bundle


with tempfile.TemporaryDirectory(prefix="bloom-server-packaging-") as directory:
    root = pathlib.Path(directory)
    labels = set()
    for name, application_id in [
        ("Bloom", "be.spatie.bloom"),
        ("Bloom Dev", "be.spatie.bloom.dev"),
        ("Bloom Subagents", "be.spatie.bloom.subagents"),
    ]:
        bundle = bundle_at(root, name, application_id)
        module.prepare(bundle)
        with (bundle / "Contents/Library/LaunchAgents/BloomServer.plist").open("rb") as source:
            job = plistlib.load(source)
        assert job["Label"] == application_id + ".local-server"
        labels.add(job["Label"])
        assert job["BundleProgram"] == "Contents/MacOS/bloom-server"
        assert job["ProgramArguments"] == ["bloom-server", "serve", "--application-id", application_id]
        assert job["KeepAlive"] is True and job["RunAtLoad"] is True
        assert str(root) not in str(job), "A bundle baked the builder's home path into its service"
    assert len(labels) == 3, "Development and release servers share an identity"
    old = bundle_at(root, "Old Bloom", "be.spatie.bloom.dev", has_server=False)
    module.prepare(old)
    assert not (old / "Contents/Library/LaunchAgents/BloomServer.plist").exists()
    bad = bundle_at(root, "Invalid Bloom", "../Bloom")
    try:
        module.prepare(bad)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid bundle identity was accepted")

print("PASS: service bundle paths, channel isolation and old-revision compatibility")
