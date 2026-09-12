#!/usr/bin/env python3
"""Snapshot current Git-visible files, then retain unchanged cache source timestamps."""
import argparse
import hashlib
import json
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


def package_structure(root):
    # SwiftPM's cached plan watches the root target directories, but not local dependency
    # source directories. Track names and manifests separately from source content so adding
    # or removing a dependency source replans without recompiling unchanged source files.
    entries = []
    for directory, folders, files in os.walk(root, followlinks=False):
        folders[:] = sorted(name for name in folders if name not in {".build", ".git"})
        files = [name for name in files if name not in {".build", ".git"}]
        if Path(directory) == root:
            folders[:] = [name for name in folders if name in {"Sources", "Tests", "Packages"}]
            files = [name for name in files if name == "Package.resolved" or
                     (name.startswith("Package") and name.endswith(".swift"))]
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                entries.append((relative, os.readlink(path)))
            elif (name == "Package.resolved" or (name.startswith("Package") and name.endswith(".swift"))) and path.is_file():
                entries.append((relative, hashlib.sha256(path.read_bytes()).hexdigest()))
            else:
                entries.append((relative, None))
    return hashlib.sha256(json.dumps(entries).encode()).hexdigest()


def sync(stage, destination):
    if destination.is_symlink():
        raise ValueError("Build cache source directory must not be a symbolic link")
    destination.mkdir(parents=True, exist_ok=True)
    structure = package_structure(stage)
    # Keep this beside src, outside rsync's deletion scope. An absent marker also heals build
    # caches created before dependency membership was tracked, without discarding any objects.
    marker = destination.with_name("." + destination.name + "-package-structure")
    structure_changed = not marker.is_file() or marker.read_text() != structure
    # Identity transforms run in staging first. Copy only changed content; source mtimes from
    # Git/worktree creation must not invalidate every Swift file in the persistent cache.
    subprocess.run(["rsync", "-a", "--no-times", "--checksum", "--delete", "--exclude=.build",
                    str(stage) + "/", str(destination) + "/"], check=True)
    manifest = destination / "Package.swift"
    if structure_changed and manifest.is_file() and not manifest.is_symlink():
        # This is a declared PackageStructure input. Updating it refreshes only the build
        # plan, leaving dependency checkouts, object files and unchanged source mtimes intact.
        manifest.touch()
    marker.write_text(structure)


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
