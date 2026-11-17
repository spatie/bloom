#!/usr/bin/env python3
"""Release retention checks without signing credentials or a live bucket."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

TOOLS = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.feed = self.work / "appcast.xml"

    def release(self, version, build):
        subprocess.run([
            sys.executable, str(TOOLS / "appcast.py"), "--existing", str(self.feed),
            "--output", str(self.feed), "--version", version, "--build", str(build),
            "--url", f"https://example.invalid/releases/Bloom-{version}.zip",
            "--length", "123", "--signature", "signature", "--min-system", "26.0",
            "--dmg-url", f"https://example.invalid/releases/Bloom-{version}.dmg",
            "--dmg-length", "456",
        ], check=True, capture_output=True)

    def items(self):
        return ET.parse(self.feed).getroot().findall("channel/item")

    def prune(self, names, base_url="https://example.invalid"):
        objects = self.work / "objects.json"
        objects.write_text(json.dumps({"Contents": [{"Key": name} for name in names]}))
        return subprocess.run([
            sys.executable, str(TOOLS / "prune.py"), "--feed", str(self.feed),
            "--objects", str(objects), "--base-url", base_url, "--prefix", "releases",
        ], capture_output=True, text=True)

    def test_keeps_five_newest_builds_including_on_rerun(self):
        for version, build in [("1.9", 10), ("1.10", 20), ("1.11", 30),
                               ("1.12", 40), ("1.13", 50), ("1.14", 60)]:
            self.release(version, build)
        self.release("1.14", 60)
        self.assertEqual([item.findtext(f"{{{SPARKLE}}}shortVersionString") for item in self.items()],
                         ["1.14", "1.13", "1.12", "1.11", "1.10"])

    def test_prunes_both_old_assets_but_not_other_files_or_prefixes(self):
        self.release("1.10", 20)
        self.release("1.11", 30)
        names = [f"releases/Bloom-{version}.{extension}" for version in
                 ["1.9", "1.10", "1.11"] for extension in ["zip", "dmg"]]
        names += ["releases/appcast.xml", "releases/notes.zip", "other/Bloom-1.0.zip",
                  "releases/nested/Bloom-1.0.zip", "releases/Bloom-icon.zip"]
        result = self.prune(names)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["releases/Bloom-1.9.dmg", "releases/Bloom-1.9.zip"])

    def test_missing_retained_asset_or_wrong_origin_prevents_all_deletions(self):
        self.release("1.10", 20)
        names = ["releases/Bloom-1.9.zip", "releases/Bloom-1.10.zip"]
        for result in [self.prune(names), self.prune(names, "https://wrong.invalid")]:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_empty_feed_prevents_all_deletions(self):
        self.feed.write_text("<rss><channel /></rss>")
        result = self.prune(["releases/Bloom-1.9.zip"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_feed_read_only_treats_a_missing_object_as_an_empty_feed(self):
        aws = self.work / "aws"
        aws.write_text('#!/bin/sh\nprintf "An error occurred (%s)\\n" "$BUCKET_ERROR" >&2\nexit 1\n')
        aws.chmod(0o755)
        env = dict(os.environ, PATH=f"{self.work}:{os.environ['PATH']}", BLOOM_BUCKET="bucket",
                   BLOOM_S3_ENDPOINT="https://s3.invalid", BLOOM_S3_REGION="auto",
                   BLOOM_PUBLIC_BASE_URL="https://example.invalid")
        for error in ["AccessDenied", "RequestTimeout", "NoSuchKey"]:
            self.feed.write_text("existing feed")
            result = subprocess.run(["zsh", str(TOOLS / "bucket.sh"), "get", "appcast.xml", str(self.feed)],
                                    env=dict(env, BUCKET_ERROR=error), capture_output=True)
            if error == "NoSuchKey":
                self.assertEqual(result.returncode, 0)
                self.assertEqual(self.feed.read_text(), "")
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.feed.read_text(), "existing feed")


if __name__ == "__main__":
    unittest.main()
