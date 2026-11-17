#!/usr/bin/env python3
"""Print obsolete release object keys, refusing to prune an incomplete bucket or feed."""

import argparse
import json
import re
import xml.etree.ElementTree as ET

from appcast import BLOOM


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", required=True)
    parser.add_argument("--objects", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--prefix", default="")
    args = parser.parse_args()

    prefix = args.prefix.strip("/")
    prefix = f"{prefix}/" if prefix else ""
    release_name = re.compile(r"Bloom-[0-9]+(?:\.[0-9]+){0,3}(?:-[0-9A-Za-z.-]+)?\.(?:zip|dmg)")
    items = ET.parse(args.feed).getroot().findall("channel/item")
    if not 1 <= len(items) <= 5:
        raise SystemExit("prune.py: expected one to five releases; nothing deleted")

    keep = set()
    url_prefix = f"{args.base_url.rstrip('/')}/{prefix}"
    for item in items:
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise SystemExit("prune.py: release has no enclosure; nothing deleted")
        assets = [enclosure, *item.findall(f"{{{BLOOM}}}diskImage")]
        for asset in assets:
            url = asset.get("url", "")
            name = url.removeprefix(url_prefix)
            if not url.startswith(url_prefix) or not release_name.fullmatch(name):
                raise SystemExit(f"prune.py: unexpected release URL {url}; nothing deleted")
            keep.add(prefix + name)

    with open(args.objects, encoding="utf-8") as handle:
        objects = json.load(handle)
    keys = {obj["Key"] for obj in objects.get("Contents", [])}
    if not keep <= keys:
        raise SystemExit("prune.py: a retained download is missing; nothing deleted")

    for key in sorted(keys - keep):
        if key.startswith(prefix) and release_name.fullmatch(key[len(prefix):]):
            print(key)


if __name__ == "__main__":
    main()
