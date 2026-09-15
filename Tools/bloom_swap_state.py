"""Read swap ownership hints without enabling, resizing or removing existing swap."""

import os
import pathlib

PROC_SWAPS = pathlib.Path("/proc/swaps")
FSTAB = pathlib.Path("/etc/fstab")
SYSTEMD_UNIT_DIRECTORIES = tuple(pathlib.Path(path) for path in (
    "/etc/systemd/system", "/run/systemd/system", "/run/systemd/generator",
    "/run/systemd/generator.early", "/run/systemd/generator.late",
    "/usr/local/lib/systemd/system", "/usr/lib/systemd/system", "/lib/systemd/system",
))
ZRAM_CONFIGURATION = tuple(pathlib.Path(path) for path in (
    "/etc/default/zramswap", "/etc/default/zram-config",
    "/etc/systemd/zram-generator.conf", "/etc/systemd/zram-generator.conf.d",
    "/run/systemd/zram-generator.conf", "/run/systemd/zram-generator.conf.d",
    "/usr/local/lib/systemd/zram-generator.conf", "/usr/local/lib/systemd/zram-generator.conf.d",
    "/usr/lib/systemd/zram-generator.conf", "/usr/lib/systemd/zram-generator.conf.d",
))


def _raise_read_error(error):
    raise error


def _ignored_unit(path, ignored):
    if ignored is None:
        return False
    if path == ignored:
        return True
    try:
        return path.resolve(strict=True) == ignored
    except FileNotFoundError:
        return False
    except RuntimeError as error:
        raise ValueError("A configured swap unit has an invalid symlink") from error


def read_swap_status(ignore_unit=None):
    """Unknown state raises; only a fully checked empty state allows a new swap allocation.

    The installer may ignore its own unit only after verifying its protected ownership marker
    and exact unit contents. Preflight never excludes any unit.
    """
    ignored = pathlib.Path(ignore_unit) if ignore_unit is not None else None
    if ignored is not None and not ignored.is_absolute():
        raise ValueError("An ignored swap unit must use an absolute path")
    if ignored is not None:
        try:
            ignored = ignored.resolve(strict=True)
        except RuntimeError as error:
            raise ValueError("The managed swap unit has an invalid symlink") from error
    lines = PROC_SWAPS.read_text().splitlines()
    if not lines or lines[0].split() != ["Filename", "Type", "Size", "Used", "Priority"]:
        raise ValueError("The active swap listing could not be read")
    active_paths, active_bytes = [], 0
    for line in lines[1:]:
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 5 or not fields[2].isdigit():
            raise ValueError("The active swap listing is invalid")
        active_paths.append(fields[0])
        active_bytes += int(fields[2]) * 1024

    configured = []
    try:
        fstab = FSTAB.read_text()
    except FileNotFoundError:
        fstab = ""
    for line in fstab.splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) >= 3 and fields[2] == "swap":
            configured.append(str(FSTAB))
            break
    for directory in SYSTEMD_UNIT_DIRECTORIES:
        try:
            directory.stat()
        except FileNotFoundError:
            continue
        for root, _, files in os.walk(directory, onerror=_raise_read_error):
            for name in files:
                path = pathlib.Path(root) / name
                if name.endswith(".swap") and not _ignored_unit(path, ignored):
                    configured.append(str(path))
    for path in ZRAM_CONFIGURATION:
        try:
            path.stat()
        except FileNotFoundError:
            continue
        configured.append(str(path))
    return {"activeSwapBytes": active_bytes, "activeSwapPaths": active_paths,
            "configuredSwap": bool(configured), "configuredSwapSources": sorted(set(configured))}
