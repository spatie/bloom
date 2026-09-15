#!/usr/bin/env python3
"""Generate the embedded launch agent after a bundle receives its final application identity."""

import pathlib
import plistlib
import re
import sys


def prepare(bundle):
    executable = bundle / "Contents/MacOS/bloom-server"
    if not executable.exists():
        return  # Older revisions can still be built through the isolated development script.
    with (bundle / "Contents/Info.plist").open("rb") as source:
        application_id = plistlib.load(source)["CFBundleIdentifier"].lower()
    if len(application_id) > 200 or not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", application_id):
        raise ValueError("Invalid application identifier for the local server")
    destination = bundle / "Contents/Library/LaunchAgents/BloomServer.plist"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        plistlib.dump({
            "Label": application_id + ".local-server",
            "BundleProgram": "Contents/MacOS/bloom-server",
            "ProgramArguments": ["bloom-server", "serve", "--application-id", application_id],
            "RunAtLoad": True,
            "KeepAlive": True,
            "ProcessType": "Background",
            "ExitTimeOut": 15,
        }, output)


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]))
