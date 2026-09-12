#!/usr/bin/env python3
"""Verify that Bloom Remote has an independent identity and preserves only connection presets."""

import importlib.util
import pathlib
import plistlib
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("remote_packaging", pathlib.Path(__file__).with_name("prepare-remote-app.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="bloom-remote-packaging-") as directory:
    root = pathlib.Path(directory)
    source = root / "source"
    (source / "Resources").mkdir(parents=True)
    plist = source / "Resources/Info.plist"
    with plist.open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "be.spatie.bloom", "CFBundleURLTypes": [{}], "NSServices": [{}]}, stream)
    previous = root / "previous.app"
    (previous / "Contents").mkdir(parents=True)
    with (previous / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "be.spatie.bloom.remote", "BloomRemoteConnection": {"host": "old-server", "directory": "/srv/data"}}, stream)
    module.prepare(source, previous, "test-commit", {"BLOOM_REMOTE_HOST": "new-server", "OPENAI_API_KEY": "must-not-be-packaged"})
    with plist.open("rb") as stream:
        info = plistlib.load(stream)
    assert info["CFBundleIdentifier"] == "be.spatie.bloom.remote"
    assert info["CFBundleDisplayName"] == "Bloom Remote"
    assert info["BloomMasterCommit"] == "test-commit"
    assert info["BloomRemoteConnection"] == {"host": "new-server", "directory": "/srv/data"}
    assert "Bloom Remote/bloom.sqlite" in info["LSEnvironment"]["BLOOM_DB_PATH"]
    assert "CFBundleURLTypes" not in info and "NSServices" not in info
    assert "must-not-be-packaged" not in str(info)
    with (previous / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "be.spatie.bloom", "BloomRemoteConnection": {"host": "production"}}, stream)
    module.prepare(source, previous, "next-commit", {})
    with plist.open("rb") as stream:
        assert plistlib.load(stream)["BloomRemoteConnection"] == {}

print("PASS: remote app isolation, connection presets, commit identity and credential exclusion")
