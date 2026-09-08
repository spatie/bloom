#!/usr/bin/env python3
"""Give a detached Bloom build its own identity and a non-secret server connection preset."""

import os
import pathlib
import plistlib
import sys


def prepare(source, previous_app, commit, environment):
    plist = source / "Resources/Info.plist"
    with plist.open("rb") as stream:
        info = plistlib.load(stream)
    connection = {}
    previous = previous_app / "Contents/Info.plist"
    if previous.is_file():
        with previous.open("rb") as stream:
            old = plistlib.load(stream)
        if old.get("CFBundleIdentifier") == "be.spatie.bloom.remote":
            connection = old.get("BloomRemoteConnection", {})
    for key, variable in {
        "host": "BLOOM_REMOTE_HOST", "executable": "BLOOM_REMOTE_EXECUTABLE",
        "directory": "BLOOM_REMOTE_DIRECTORY", "repository": "BLOOM_REMOTE_REPOSITORY",
        "model": "BLOOM_REMOTE_MODEL", "identityFile": "BLOOM_REMOTE_IDENTITY_FILE",
    }.items():
        if variable in environment:
            connection[key] = environment[variable]
    info.update({
        "CFBundleName": "Bloom Remote", "CFBundleDisplayName": "Bloom Remote",
        "CFBundleIdentifier": "be.spatie.bloom.remote", "BloomRemoteBuild": True,
        "BloomMasterCommit": commit, "BloomRemoteConnection": connection,
        "LSEnvironment": {"BLOOM_DB_PATH": str(pathlib.Path.home() / "Library/Application Support/Bloom Remote/bloom.sqlite")},
    })
    # The verification app must never claim Bloom's deep links or Finder services.
    info.pop("CFBundleURLTypes", None)
    info.pop("NSServices", None)
    with plist.open("wb") as stream:
        plistlib.dump(info, stream)


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], os.environ)
