#!/usr/bin/env python3
"""Publish a verified staged app with an atomic directory exchange, retaining the old app on failure."""
import ctypes
import os
from pathlib import Path
import shutil
import sys


def exchange(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        operation = libc.renamex_np
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = operation(os.fsencode(source), os.fsencode(destination), 2)  # RENAME_SWAP
    elif sys.platform.startswith("linux"):
        operation = libc.renameat2
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = operation(-100, os.fsencode(source), -100, os.fsencode(destination), 2)  # RENAME_EXCHANGE
    else:
        raise RuntimeError("Atomic app replacement is unsupported on this platform")
    if result != 0:
        raise OSError(ctypes.get_errno(), "Atomic app replacement failed")


def install(staging, destination, swap=exchange):
    if staging.is_symlink() or not staging.is_dir() or destination.is_symlink():
        raise ValueError("App publication requires real directories")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError("The existing app is not a directory")
        swap(staging, destination)
        # A cleanup failure cannot roll back a successfully verified atomic replacement.
        try:
            shutil.rmtree(staging)
        except OSError:
            print(f"Previous bundle retained at {staging}", file=sys.stderr)
    else:
        os.rename(staging, destination)


if __name__ == "__main__":
    install(Path(sys.argv[1]), Path(sys.argv[2]))
