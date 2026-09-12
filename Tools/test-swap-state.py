#!/usr/bin/env python3
"""A read-only probe must preserve active and configured swap, including inactive units."""

import pathlib
import tempfile
import unittest
from unittest import mock

import bloom_swap_state as swap


class SwapStateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.active = self.root / "swaps"
        self.fstab = self.root / "fstab"
        self.units = self.root / "units"
        self.zram = self.root / "zram-generator.conf"
        self.units.mkdir()
        self.active.write_text("Filename\tType\tSize\tUsed\tPriority\n")
        self.fstab.write_text("# /old-swap none swap sw 0 0\n/dev/root / ext4 defaults 0 1\n")
        for name, value in (("PROC_SWAPS", self.active), ("FSTAB", self.fstab),
                            ("SYSTEMD_UNIT_DIRECTORIES", (self.units,)), ("ZRAM_CONFIGURATION", (self.zram,))):
            patch = mock.patch.object(swap, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def test_empty_status_requires_reading_active_and_configured_state(self):
        result = swap.read_swap_status()
        self.assertEqual(result, {"activeSwapBytes": 0, "activeSwapPaths": [],
                                  "configuredSwap": False, "configuredSwapSources": []})
        self.active.unlink()
        with self.assertRaises(OSError):
            swap.read_swap_status()

    def test_missing_optional_unit_directories_do_not_make_state_unknown(self):
        with mock.patch.object(swap, "SYSTEMD_UNIT_DIRECTORIES", (self.units, self.root / "absent")):
            result = swap.read_swap_status()
        self.assertFalse(result["configuredSwap"])
        self.assertEqual(result["activeSwapBytes"], 0)

    def test_unreadable_unit_directory_is_unknown(self):
        with mock.patch.object(swap.os, "walk", side_effect=PermissionError("not readable")):
            with self.assertRaises(PermissionError):
                swap.read_swap_status()

    def test_invalid_managed_unit_symlinks_are_reported_as_unknown(self):
        unit = self.units / "managed.swap"
        unit.symlink_to(unit)
        with self.assertRaises((OSError, ValueError)):
            swap.read_swap_status(ignore_unit=unit)

    def test_active_swap_counts_all_files_and_devices_in_bytes(self):
        self.active.write_text("Filename Type Size Used Priority\n/swapfile file 2097152 0 -2\n/dev/zram0 partition 524288 1024 100\n")
        result = swap.read_swap_status()
        self.assertEqual(result["activeSwapBytes"], 2684354560)
        self.assertEqual(result["activeSwapPaths"], ["/swapfile", "/dev/zram0"])

    def test_inactive_fstab_swap_is_preserved_even_with_noauto(self):
        self.fstab.write_text("/custom/swap none swap noauto 0 0\n")
        result = swap.read_swap_status()
        self.assertEqual(result["activeSwapBytes"], 0)
        self.assertTrue(result["configuredSwap"])
        self.assertEqual(result["configuredSwapSources"], [str(self.fstab)])

    def test_inactive_systemd_swap_is_preserved_without_enablement(self):
        unit = self.units / "custom.swap"
        unit.write_text("[Swap]\nWhat=/custom\n")
        result = swap.read_swap_status()
        self.assertTrue(result["configuredSwap"])
        self.assertEqual(result["configuredSwapSources"], [str(unit)])

    def test_ignoring_verified_managed_unit_does_not_hide_other_units(self):
        unit = self.units / "managed.swap"
        unit.write_text("[Swap]\nWhat=/managed\n")
        enabled = self.units / "swap.target.wants"
        enabled.mkdir()
        (enabled / unit.name).symlink_to(unit)
        self.assertFalse(swap.read_swap_status(ignore_unit=unit)["configuredSwap"])
        (self.units / "other.swap").write_text("[Swap]\nWhat=/other\n")
        self.assertTrue(swap.read_swap_status(ignore_unit=unit)["configuredSwap"])
        with self.assertRaises(ValueError):
            swap.read_swap_status(ignore_unit="managed.swap")

    def test_zram_configuration_is_preserved_before_device_is_active(self):
        self.zram.write_text("[zram0]\n")
        self.assertTrue(swap.read_swap_status()["configuredSwap"])

    def test_malformed_active_listing_is_unknown_not_empty(self):
        for value in ("", "invalid header\n", "Filename Type Size Used Priority\n/swap file invalid 0 -2\n"):
            with self.subTest(value=value):
                self.active.write_text(value)
                with self.assertRaises(ValueError):
                    swap.read_swap_status()

    def test_unreadable_configuration_is_unknown_not_empty(self):
        original = pathlib.Path.read_text
        def read(path, *args, **kwargs):
            if path == self.fstab:
                raise PermissionError("not readable")
            return original(path, *args, **kwargs)
        with mock.patch.object(pathlib.Path, "read_text", read):
            with self.assertRaises(PermissionError):
                swap.read_swap_status()


if __name__ == "__main__":
    unittest.main()
