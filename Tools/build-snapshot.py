#!/usr/bin/env python3
"""Snapshot current Git-visible files, then retain unchanged cache source timestamps."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess


def snapshot(checkout, destination):
    checkout = checkout.resolve()
    target_root = destination.resolve()
    if target_root == checkout or checkout in target_root.parents:
        raise ValueError("Snapshot staging must be outside the checkout")
    if any(destination.iterdir()):
        raise ValueError("Snapshot staging must be empty")
    files = subprocess.check_output(["git", "-C", str(checkout), "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
    for raw in sorted(set(files.split(b"\0")) - {b""}):
        relative = Path(os.fsdecode(raw))
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Git returned an unsafe source path")
        if ".build" in relative.parts or ".git" in relative.parts:
            continue
        source = checkout / relative
        # A tracked directory may have become a symlink in the working copy. Copy the link
        # itself when Git lists it, never a tracked descendant through its new external target.
        if any((checkout / parent).is_symlink() for parent in relative.parents if parent != Path(".")):
            continue
        if not source.is_file() and not source.is_symlink():
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=False)


def check_inputs(stage, paths):
    for name in paths:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Identity input must be relative to staging")
        source = stage / relative
        if any((stage / part).is_symlink() for part in [relative, *relative.parents]) or not source.is_file():
            raise ValueError(f"Identity input must be a regular file without symbolic links: {relative}")


def sync(stage, destination):
    if destination.is_symlink():
        raise ValueError("Build cache source directory must not be a symbolic link")
    destination.mkdir(parents=True, exist_ok=True)
    # Identity transforms run in staging first. Copy only changed content; source mtimes from
    # Git/worktree creation must not invalidate every Swift file in the persistent cache.
    subprocess.run(["rsync", "-a", "--no-times", "--checksum", "--delete", "--exclude=.build",
                    str(stage) + "/", str(destination) + "/"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["snapshot", "sync", "check-inputs"])
    parser.add_argument("source", type=Path)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    if args.operation == "check-inputs":
        check_inputs(args.source, args.paths)
    else:
        if len(args.paths) != 1:
            parser.error("Supply one destination")
        (snapshot if args.operation == "snapshot" else sync)(args.source, Path(args.paths[0]))
