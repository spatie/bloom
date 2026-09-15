#!/usr/bin/env python3
"""Exercise the maintained packaging check without building or launching an app."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
COLOURSET = Path("Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
PALETTE = Path("Packages/BloomClient/Sources/BloomClient/PaletteInk.swift")


class AccentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for path in (COLOURSET, PALETTE):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, self.root / path)
        self.function = re.search(r"^verify_accent_matches_palette\(\) \{\n.*?^\}",
                                  (ROOT / "Tools/build.sh").read_text(), re.M | re.S).group()

    def check(self):
        return subprocess.run(["/bin/zsh", "-f", "-c", self.function + "\nverify_accent_matches_palette"],
                              cwd=self.root, text=True, capture_output=True)

    def test_packaging_reads_shared_palette_without_a_core_definition(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_asset_mismatch_still_fails(self):
        path = self.root / COLOURSET
        asset = json.loads(path.read_text())
        asset["colors"][0]["color"]["components"]["blue"] = "0x00"
        path.write_text(json.dumps(asset))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PaletteInk.accentFill says #197593", result.stderr)

    def test_different_appearance_colours_still_fail(self):
        path = self.root / PALETTE
        path.write_text(path.read_text().replace("accentFill = Pair(light: 0x197593, dark: 0x197593)",
                                                "accentFill = Pair(light: 0x197593, dark: 0xFFFFFF)"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a pair", result.stderr)

    def test_alias_or_missing_declaration_cannot_bypass_check(self):
        (self.root / PALETTE).write_text("public typealias PaletteInk = BloomClient.PaletteInk\n")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read one accentFill pair", result.stderr)

    def test_missing_source_or_asset_cannot_bypass_check(self):
        for path in (PALETTE, COLOURSET):
            with self.subTest(path=path):
                target = self.root / path
                contents = target.read_bytes()
                target.unlink()
                self.assertNotEqual(self.check().returncode, 0)
                target.write_bytes(contents)


if __name__ == "__main__":
    unittest.main()
