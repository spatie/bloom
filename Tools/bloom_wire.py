"""The app wire protocol, read from the Swift that declares it.

`BloomWire.version` in BloomClient is the only place the number is written. The packager, the app
embedder and the release asset check each used to grep `version = (\\d+)` out of that file on their
own, which takes the first matching line whatever type it belongs to, and the supervisor and its
installer carried the number again as a literal 14. Protocol 15 then shipped a package the
installer refused as `maintenance_package_required` on a real server while every test, pinned to
14 as well, stayed green. Anything in Tools that needs the number reads it here.

The server-side maintenance scripts never import this: a supervisor on a server has no checkout,
and it takes the protocol from the manifest of the release it installed.
"""
import pathlib
import re

SOURCE = 'Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift'


def wire_protocol(root=None):
    root = pathlib.Path(root) if root is not None else pathlib.Path(__file__).resolve().parent.parent
    text = (root / SOURCE).read_text()
    match = re.search(r'enum\s+BloomWire\s*\{[^}]*?static\s+let\s+version\s*=\s*(\d+)', text)
    if match is None:
        raise ValueError(f'BloomWire.version was not found in {SOURCE}')
    return int(match[1])
