#!/usr/bin/env python3
"""Optional 2 GiB host swap. Preserves existing swap and never modifies fstab or disables swap.

Swap can contain process credentials, so its file and every writable parent remain root-owned.
It cannot live beneath the Bloom service account's writable home directory.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile

if "stream_install_command" not in globals():
    from bloom_install_process import InstallProcessCancelled, InstallProcessFailure, install_cancellation_scope, install_exception_details, redact_install_text, stream_install_command
if "read_swap_status" not in globals():
    from bloom_swap_state import read_swap_status

ROOT = Path("/var/lib/bloom")
SWAP_FILE = ROOT / "swapfile"
MARKER = ROOT / ".swap-managed.json"
UNIT = Path("/etc/systemd/system/var-lib-bloom-swapfile.swap")
SWAP_BYTES = 2 * 1024 * 1024 * 1024
DISK_RESERVE = 2 * 1024 * 1024 * 1024
CURRENT_STEP = None


class SwapError(Exception):
    def __init__(self, code, message, recovery, **metadata):
        super().__init__(redact_install_text(message))
        self.code, self.recovery = code, redact_install_text(recovery)
        self.metadata = metadata


def fail(code, message, recovery, **metadata):
    raise SwapError(code, message, recovery, **metadata)


def emit(event, **fields):
    global CURRENT_STEP
    if event == "progress":
        CURRENT_STEP = fields.get("step")
    print(json.dumps(dict(event=event, **fields)), flush=True)


def protected(path):
    for item in (path, *path.parents):
        try:
            info = item.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            fail("unsafe_swap_path", f"Swap setup found an unprotected path: {item}",
                 "Use root-owned paths without symlinks or group/world write access. Do not put swap in a user's home.")


def private_file(path):
    protected(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o077:
        fail("unsafe_swap_file", "The swap file is not a private regular file with a single link.",
             "Review the managed swap installation before retrying. Existing files will not be reformatted.")
    return info


def command(arguments, *, timeout=60, live=True):
    try:
        result = stream_install_command(arguments, timeout=timeout, live=live, cwd="/", umask=0o077,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"},
            output=lambda line: emit("output", step=CURRENT_STEP, message=line))
    except InstallProcessFailure as error:
        fail(error.code, f"{error.command} could not complete.",
             "Review swap setup output and retry. Existing swap and Bloom Server remain available.",
             command=error.command, exitStatus=error.exit_status, details=error.details)
    if result.returncode:
        fail("swap_command_failed", f"{result.command} exited with status {result.returncode}.",
             "Review swap setup output and retry. Existing swap and Bloom Server remain available.",
             command=result.command, exitStatus=result.returncode, details=result.details)
    return result.stdout.decode("utf-8", errors="replace").strip()


def atomic_text(path, text, mode=0o600):
    protected(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".bloom-swap-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def marker_value(phase, identity=None):
    if identity is None:
        info = SWAP_FILE.lstat()
        identity = (info.st_dev, info.st_ino)
    return {"format": 1, "path": str(SWAP_FILE), "bytes": SWAP_BYTES, "phase": phase,
            "device": identity[0], "inode": identity[1]}


def unit_contents():
    return f"""# Managed by Bloom optional swap setup
[Unit]
Description=Bloom memory reserve

[Swap]
What={SWAP_FILE}
TimeoutSec=30

[Install]
WantedBy=swap.target
"""


def managed_marker():
    protected(MARKER)
    if not MARKER.exists():
        return None
    private_file(MARKER)
    value = json.loads(MARKER.read_text())
    if not isinstance(value, dict):
        fail("unmanaged_swap", "The swap installation marker is invalid.", "Review /var/lib/bloom before retrying.")
    identity = (value.get("device"), value.get("inode"))
    valid_identity = all(type(number) is int and number >= 0 for number in identity) and identity[1] > 0
    if not valid_identity or value.get("phase") not in ("allocating", "prepared", "active") or value != marker_value(value.get("phase"), identity):
        fail("unmanaged_swap", "The swap installation marker does not match this installer.", "Review /var/lib/bloom before retrying.")
    return value


def verify_unit():
    protected(UNIT)
    if not UNIT.is_file() or UNIT.read_text() != unit_contents():
        fail("unmanaged_swap_unit", "The existing Bloom swap unit has different settings.", "Review its configuration before retrying; Bloom will not overwrite it.")


def inventory(managed):
    # Exclude only our exact verified unit. A disabled unit from a partially completed install
    # can then resume; an unrelated configured swap, including noauto/zram, is always preserved.
    ignore = None
    if managed and UNIT.exists():
        verify_unit()
        ignore = str(UNIT)
    return read_swap_status(ignore_unit=ignore)


def external_swap(state, managed):
    own = str(SWAP_FILE) if managed else None
    return state["configuredSwap"] or any(path != own for path in state["activeSwapPaths"])


def preserved(state):
    active = state["activeSwapBytes"] > 0
    return dict(ready=True, unchanged=True, active=active, outcome="preserved",
                activeSwapBytes=state["activeSwapBytes"],
                message="Existing active swap was preserved. No additional swap was activated." if active else
                "Existing swap configuration was preserved. It is not currently active; no additional swap was activated.")


def check_storage():
    parent = ROOT if ROOT.exists() else ROOT.parent
    protected(parent)
    filesystem = command(["findmnt", "--noheadings", "--output", "FSTYPE", "--target", str(parent)], live=False)
    if filesystem not in ("ext4", "xfs"):
        fail("unsupported_swap_filesystem", f"Automatic swap setup does not support the {filesystem or 'unknown'} filesystem.",
             "Configure swap with the server provider or administrator. Bloom only creates swap files on ext4 and XFS.")
    if shutil.disk_usage(parent).free < SWAP_BYTES + DISK_RESERVE:
        fail("insufficient_swap_disk", "Swap setup needs at least 4 GiB of free disk space.",
             "Free disk space before retrying. The 2 GiB swap file must leave at least 2 GiB available for projects.")


def owned_file(managed):
    if managed is None:
        fail("unmanaged_swap", "The swap ownership marker is missing.", "Review /var/lib/bloom before retrying. Existing files will not be changed.")
    info = private_file(SWAP_FILE)
    if (info.st_dev, info.st_ino) != (managed["device"], managed["inode"]):
        fail("swap_file_replaced", "The managed swap file was replaced after setup began.",
             "Review the existing file before retrying. Bloom will not remove or reformat it.")
    return info


def verify_file():
    info = owned_file(managed_marker())
    if info.st_size != SWAP_BYTES or info.st_blocks * 512 < SWAP_BYTES:
        fail("invalid_swap_file", "The managed swap file is incomplete or has unallocated space.", "Review the managed installation before retrying. An active swap file is never rewritten.")
    if command(["blkid", "--probe", "--match-tag", "TYPE", "--output", "value", str(SWAP_FILE)], live=False) != "swap":
        fail("invalid_swap_signature", "The managed file does not contain a valid swap signature.", "Review the managed installation before retrying. Existing files will not be reformatted.")


def allocate():
    check_storage()
    protected(ROOT)
    ROOT.mkdir(mode=0o700, exist_ok=True)
    descriptor = os.open(SWAP_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    identity = os.fstat(descriptor)
    os.close(descriptor)
    prepared = False
    try:
        # Bind ownership only after exclusive creation succeeds. A conflicting file appearing
        # before O_EXCL must not gain a marker that authorises deleting it on the next retry.
        atomic_text(MARKER, json.dumps(marker_value("allocating", (identity.st_dev, identity.st_ino))) + "\n")
        # util-linux documents fully writing /dev/zero as the portable way to avoid holes.
        # Do not use truncate, sparse dd, or filesystem-dependent fallocate here.
        command(["dd", "if=/dev/zero", "of=" + str(SWAP_FILE), "bs=1048576", "count=2048",
                 "oflag=nofollow", "conv=fsync", "status=progress"], timeout=300)
        command(["mkswap", str(SWAP_FILE)])
        verify_file()
        atomic_text(MARKER, json.dumps(marker_value("prepared")) + "\n")
        prepared = True
    finally:
        if not prepared and SWAP_FILE.exists():
            current = private_file(SWAP_FILE)
            # A killed dd is reaped by the shared process helper before this cleanup. Never
            # unlink a different inode or a file an administrator activated concurrently.
            state = read_swap_status()
            if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino) and str(SWAP_FILE) not in state["activeSwapPaths"]:
                SWAP_FILE.unlink()
                managed = managed_marker()
                if managed and (managed["device"], managed["inode"]) == (identity.st_dev, identity.st_ino):
                    MARKER.unlink()


def install():
    emit("progress", step="swap_check", message="Checking existing swap and available disk space")
    # Existing swap takes precedence even when an unrelated object occupies our proposed path.
    initial = read_swap_status()
    if initial["activeSwapBytes"] > 0 and str(SWAP_FILE) not in initial["activeSwapPaths"]:
        return preserved(initial)
    managed = managed_marker()
    state = inventory(managed)
    if external_swap(state, managed):
        return preserved(state)
    protected(ROOT)
    protected(SWAP_FILE)
    protected(UNIT)
    if not managed and (SWAP_FILE.exists() or ROOT.exists() and any(ROOT.iterdir())):
        fail("unmanaged_swap", "The proposed swap directory already contains unmanaged files.", "Review /var/lib/bloom before retrying. Bloom will not remove or overwrite existing data.")
    if not managed and UNIT.exists():
        fail("unmanaged_swap_unit", "An unrelated swap unit already uses Bloom's unit name.", "Review the existing swap unit before retrying.")
    was_active = str(SWAP_FILE) in state["activeSwapPaths"]
    if managed and managed["phase"] == "allocating":
        if was_active:
            fail("active_partial_swap", "Swap was activated before its managed setup completed.", "Review its configuration manually. Bloom will not rewrite or disable active swap.")
        if SWAP_FILE.exists():
            owned_file(managed)
            SWAP_FILE.unlink()
    if not managed or managed["phase"] == "allocating":
        emit("progress", step="swap_create", message="Creating a private 2 GiB memory reserve")
        allocate()
    else:
        verify_file()
    # Another administrator may have configured swap during allocation. Leave that choice
    # untouched rather than enabling a second swap area behind their back.
    latest = inventory(True)
    if external_swap(latest, True):
        result = preserved(latest)
        result["preparedSwapFile"] = str(SWAP_FILE)
        if str(SWAP_FILE) not in latest["activeSwapPaths"]:
            result["message"] += " Bloom's prepared swap file was left inactive for a later retry."
        return result
    emit("progress", step="swap_persist", message="Saving the swap configuration for future restarts")
    if not UNIT.exists():
        atomic_text(UNIT, unit_contents(), mode=0o644)
    command(["systemctl", "daemon-reload"])
    verify_unit()
    command(["systemctl", "enable", UNIT.name])
    if str(SWAP_FILE) not in latest["activeSwapPaths"]:
        emit("progress", step="swap_activate", message="Activating the memory reserve")
        verify_unit()
        command(["systemctl", "start", UNIT.name], timeout=45)
    final = read_swap_status()
    if str(SWAP_FILE) not in final["activeSwapPaths"]:
        fail("swap_not_active", "The swap file was created, but activation could not be confirmed.", "Review the swap unit status and retry. The prepared file can be reused safely.")
    atomic_text(MARKER, json.dumps(marker_value("active")) + "\n")
    return dict(ready=True, unchanged=was_active, active=True, outcome="managedExisting" if managed else "added",
                activeSwapBytes=final["activeSwapBytes"], swapFile=str(SWAP_FILE),
                message="Bloom's existing 2 GiB swap is active and configured for restarts." if managed else
                "Added 2 GiB of swap and configured it for future restarts.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="bloom")
    parser.add_argument("--service-home")
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    if options.check:
        state = read_swap_status()
        emit("complete", **(preserved(state) if state["activeSwapBytes"] or state["configuredSwap"] else
             dict(ready=False, active=False, unchanged=True, outcome="absent", activeSwapBytes=0, message="No active or configured swap was found.")))
        return
    if os.geteuid() != 0:
        fail("root_required", "Adding swap requires administrator access.", "Use the server administrator connection to add this optional memory reserve.")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", options.user):
        fail("invalid_service_account", "Invalid Bloom service account.", "Use the account created by Add Server.")
    account = pwd.getpwnam(options.user)
    if account.pw_uid == 0 or options.service_home is not None and options.service_home != account.pw_dir:
        fail("invalid_service_account", "Use Bloom's non-root service account and its actual home directory.", "Check the Add Server installation settings.")
    directory = Path("/run/bloom-installers")
    protected(directory)
    directory.mkdir(mode=0o755, exist_ok=True)
    lock_path = directory / "swap.lock"
    protected(lock_path)
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077 or info.st_nlink != 1:
            fail("unsafe_swap_lock", "The swap installation lock is not private and root-owned.", "Restore the protected installer lock before retrying.")
        fcntl.flock(lock, fcntl.LOCK_EX)
        emit("complete", **install())


def entrypoint():
    try:
        with install_cancellation_scope():
            main()
        return 0
    except InstallProcessCancelled:
        emit("error", ready=False, code="cancelled", message="Swap setup was cancelled.",
             recovery="Retry setup to resume the managed installation. Existing swap was not disabled.")
    except SwapError as error:
        emit("error", ready=False, code=error.code, message=str(error), recovery=error.recovery, **error.metadata)
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        emit("error", ready=False, code="swap_setup_failed", message="Optional swap setup could not complete.",
             recovery="Review the diagnostic and retry. Existing swap and Bloom Server remain available.", details=install_exception_details(error))
    return 1


if __name__ == "__main__":
    sys.exit(entrypoint())
