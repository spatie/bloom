#!/usr/bin/env python3
"""Install the packaged server over SSH. Stdout is a bounded, secret-free JSONL protocol."""

import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import pwd
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time


class InstallError(Exception):
    def __init__(self, code, message, recovery):
        super().__init__(message)
        self.code, self.message, self.recovery = code, message, recovery


def fail(code, message, recovery):
    raise InstallError(code, message, recovery)


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, separators=(",", ":")), flush=True)


def command(arguments, timeout=30, required=True, account=None):
    # Never forward subprocess output: package managers and authentication helpers can echo secrets.
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if arguments[:2] == ["systemctl", "show"] else subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=timeout, check=False,
                                **({"user": account.pw_uid, "group": account.pw_gid, "extra_groups": []} if account else {}),
                                env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8",
                                     "DEBIAN_FRONTEND": "noninteractive"})
    except (OSError, subprocess.TimeoutExpired):
        if required:
            fail("command_failed", "A server preparation command failed or timed out.",
                 "Check the server's network and package manager, then retry.")
        return None
    if required and result.returncode:
        fail("command_failed", "A server preparation command could not complete.",
             "Check the server's network and package manager, then retry.")
    return result


def valid_path(value):
    path = pathlib.Path(value)
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", value) or ".." in path.parts or path == pathlib.Path("/"):
        raise argparse.ArgumentTypeError("Use an absolute path containing letters, digits, /, _, - and .")
    if any(part.is_symlink() for part in [path, *path.parents]):
        raise argparse.ArgumentTypeError("Installation paths must not contain symbolic links")
    return path


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--check", action="store_true")
    result.add_argument("--package", type=pathlib.Path)
    result.add_argument("--sha256")
    result.add_argument("--install-root", type=valid_path, default=pathlib.Path("/opt/bloom-server"))
    result.add_argument("--data-dir", type=valid_path, default=pathlib.Path("/var/lib/bloom"))
    result.add_argument("--service-home", type=valid_path, default=None)
    result.add_argument("--service-name", default="bloom-server")
    result.add_argument("--systemd-dir", type=valid_path, default=pathlib.Path("/etc/systemd/system"))
    result.add_argument("--user", default="bloom")
    result.add_argument("--client-public-key-file", type=pathlib.Path)
    return result


def configuration(args):
    for name in (args.service_name, args.user):
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", name):
            fail("invalid_configuration", "The service and user names must be simple Linux identifiers.",
                 "Use the default installation settings.")
    args.service_home = args.service_home or pathlib.Path("/var/lib") / (args.user + "-home")
    for path in (args.install_root, args.data_dir, args.service_home, args.systemd_dir):
        valid_path(str(path))
    paths = (args.install_root, args.data_dir, args.service_home)
    if any(a == b or a in b.parents or b in a.parents for i, a in enumerate(paths) for b in paths[i + 1:]):
        fail("invalid_configuration", "The installation, data and home directories must be separate.",
             "Use the default installation settings.")
    return {"format": 1, "installRoot": str(args.install_root), "dataDirectory": str(args.data_dir),
            "serviceHome": str(args.service_home), "serviceUser": args.user, "serviceName": args.service_name,
            "systemdDirectory": str(args.systemd_dir)}


def metadata(args):
    return {"executable": str(args.install_root / "current/bin/bloom-server"),
            "dataDirectory": str(args.data_dir), "serviceUser": args.user, "serviceHome": str(args.service_home)}


def marker(args):
    path = args.install_root / ".bloom-installation.json"
    if not path.exists():
        return None
    if path.is_symlink() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
        fail("untrusted_installation", "The installation marker is not protected.", "Ask the server administrator to check its ownership.")
    try:
        value = json.loads(path.read_text())
    except (ValueError, OSError):
        fail("untrusted_installation", "The installation marker could not be read.", "Restore its original metadata before retrying.")
    expected = configuration(args)
    if any(value.get(key) != item for key, item in expected.items()):
        fail("installation_conflict", "This installation uses different paths or a different service account.",
             "Connect using its original settings. Bloom will not replace another installation.")
    return value


def check_ownership(args, existing):
    unit = args.systemd_dir / (args.service_name + ".service")
    if existing:
        protected = [args.install_root] + ([unit] if unit.exists() else [])
        if not unit.exists() and existing.get("phase") != "prepared":
            fail("installation_conflict", "The server service file is missing.", "Restore the original service file before retrying.")
        for path in protected:
            if path.is_symlink() or not path.exists() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
                fail("untrusted_installation", "The existing server installation is not protected.",
                     "Ask the server administrator to restore root ownership and permissions.")
        try:
            account = pwd.getpwnam(args.user)
        except KeyError:
            if existing.get("phase") == "prepared":
                return
            fail("installation_conflict", "The server account is missing.", "Restore the original server account before retrying.")
        if account.pw_dir != str(args.service_home) or account.pw_uid == 0:
            fail("installation_conflict", "The server account does not match this installation.", "Restore the original server account settings.")
        for path in (args.data_dir, args.service_home):
            if not path.exists() and existing.get("phase") == "prepared":
                continue
            if not path.is_dir() or path.stat().st_uid != account.pw_uid or path.stat().st_mode & 0o077:
                fail("untrusted_installation", "The server's private directories have unexpected permissions.",
                     "Restore service account ownership and mode 700 before retrying.")
        return
    for path in (args.install_root, args.data_dir, args.service_home):
        for parent in path.parents:
            if parent.exists() and (parent.stat().st_uid != 0 or (parent.stat().st_mode & 0o022 and not parent.stat().st_mode & stat.S_ISVTX)):
                fail("untrusted_directory", "An installation parent directory is writable by another account.", "Use directories under /opt and /var/lib.")
        if path.exists() and path.stat().st_uid != 0:
            fail("untrusted_directory", "An installation directory belongs to another account.", "Choose empty root-owned installation directories.")
    if unit.exists() or unit.is_symlink():
        fail("installation_conflict", "A system service already uses this name.", "Choose a different service name.")
    for path in (args.install_root, args.data_dir, args.service_home):
        if path.exists() and (not path.is_dir() or any(path.iterdir())):
            fail("installation_conflict", "An installation directory already contains unrelated files.",
                 "Choose empty directories. Existing files will not be replaced.")
    try:
        pwd.getpwnam(args.user)
    except KeyError:
        return
    fail("installation_conflict", "The service account already exists outside this installation.", "Choose another service account name.")


def active_work(data_directory):
    database = data_directory / "server.sqlite"
    if not database.exists():
        return False
    if database.is_symlink():
        fail("untrusted_database", "The server database is a symbolic link.", "Restore the database to its private data directory.")
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2)) as connection, connection:
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not {"sessions", "workspaces"}.issubset(tables):
                raise ValueError("unknown schema")
            if connection.execute("SELECT 1 FROM sessions WHERE state NOT IN ('idle','failed','cancelled') LIMIT 1").fetchone():
                return True
            if connection.execute("SELECT 1 FROM workspaces WHERE setup_state='running' LIMIT 1").fetchone():
                return True
            if "deliveries" in tables and connection.execute("SELECT 1 FROM deliveries WHERE delivered_at IS NULL LIMIT 1").fetchone():
                return True
            return False
    except (sqlite3.Error, ValueError, OSError):
        fail("database_unavailable", "Bloom could not safely check whether the server is busy.",
             "Check the existing server and database before attempting an update.")


def service_running(args):
    result = command(["systemctl", "show", args.service_name + ".service", "--property=ActiveState", "--value"], required=False)
    return result is not None and result.returncode == 0 and result.stdout.strip() not in (b"inactive", b"failed", b"")


def daemon_locked(args):
    path = args.data_dir / "server.lock"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return False
    with os.fdopen(fd, "rb") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)
            return False
        except BlockingIOError:
            return True


def probe(args):
    blockers, warnings = [], []
    release = {}
    try:
        release = dict(line.split("=", 1) for line in pathlib.Path("/etc/os-release").read_text().splitlines() if "=" in line)
    except OSError:
        pass
    version = release.get("VERSION_ID", "").strip('"')
    supported = release.get("ID", "").strip('"') == "ubuntu" and version in ("24.04", "26.04")
    if not supported:
        blockers.append({"code": "unsupported_os", "message": "Use Ubuntu 24.04 or 26.04."})
    if platform.machine() != "x86_64":
        blockers.append({"code": "unsupported_architecture", "message": "This package requires an x86_64 server."})
    if not pathlib.Path("/run/systemd/system").is_dir():
        blockers.append({"code": "systemd_required", "message": "The server must run systemd."})
    privilege = "root" if os.geteuid() == 0 else "none"
    if privilege == "none":
        result = command(["sudo", "-n", "true"], required=False)
        if result is not None and result.returncode == 0:
            privilege = "sudo"
        else:
            blockers.append({"code": "administrator_required", "message": "Connect as root or an account with passwordless sudo for installation."})
    existing = None
    try:
        existing = marker(args)
        # The root check is repeated during installation; unprivileged probes cannot inspect private homes.
        if privilege == "root":
            check_ownership(args, existing)
        if existing and privilege == "root" and active_work(args.data_dir):
            warnings.append({"code": "server_busy", "message": "Existing work must finish before updating this server."})
    except InstallError as error:
        blockers.append({"code": error.code, "message": error.message})
    target = args.install_root
    while not target.exists():
        target = target.parent
    free = shutil.disk_usage(target).free
    if free < 512 * 1024 * 1024:
        blockers.append({"code": "disk_full", "message": "Free at least 512 MB for the server installation."})
    elif free < 2 * 1024 * 1024 * 1024:
        warnings.append({"code": "low_disk", "message": "Less than 2 GB is free. Project dependencies may need more space."})
    memory_bytes = None
    try:
        memory_bytes = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
        if memory_bytes < 2 * 1024 * 1024 * 1024:
            warnings.append({"code": "limited_memory", "message": "This server has less than 2 GB of memory. Larger projects and containers may need more."})
    except (ValueError, OSError):
        pass
    return {"ok": not blockers, "freeDiskBytes": free, "memoryBytes": memory_bytes, "platform": "Ubuntu " + version if supported else "unsupported",
            "architecture": platform.machine(), "privilege": privilege, "existing": bool(existing),
            "blockers": blockers, "warnings": warnings, **metadata(args)}


def extract_package(package, destination, expected_hash):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_hash or ""):
        fail("invalid_checksum", "A SHA-256 package checksum is required.", "Select the package and its matching checksum again.")
    # Snapshot an unprivileged upload into a private root-owned directory before hashing or extracting.
    archive_path = destination / "upload.tar.gz"
    with package.open("rb") as source, archive_path.open("xb") as target:
        digest = hashlib.sha256()
        total = 0
        while chunk := source.read(1024 * 1024):
            total += len(chunk)
            if total > 512 * 1024 * 1024:
                fail("package_too_large", "The uploaded package is too large.", "Use an official Bloom server package.")
            digest.update(chunk)
            target.write(chunk)
    if digest.hexdigest() != expected_hash.lower():
        fail("checksum_mismatch", "The server package checksum does not match.", "Upload the package again before retrying.")
    prefix = "bloom-server-linux-x86_64"
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members, paths, total = [], set(), 0
            for entry in archive:
                name = pathlib.PurePosixPath(entry.name)
                if (name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != prefix
                        or not (entry.isdir() or entry.isfile()) or entry.name in paths
                        or len(entry.name) > 512 or len(members) >= 20000):
                    fail("unsafe_package", "The package contains an unsafe archive entry.", "Use an official Bloom server package.")
                total += entry.size
                if total > 1024 * 1024 * 1024:
                    fail("package_too_large", "The extracted package is too large.", "Use an official Bloom server package.")
                paths.add(entry.name)
                members.append(entry)
            # Extract only regular files and directories, without archive ownership or special modes.
            for entry in sorted(members, key=lambda value: (not value.isdir(), value.name)):
                target = destination / entry.name
                if entry.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o755)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                    with archive.extractfile(entry) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    target.chmod(0o755 if entry.mode & 0o111 else 0o644)
    except (tarfile.TarError, ValueError, OSError):
        fail("invalid_package", "The server package could not be extracted.", "Upload a complete Bloom server package and retry.")
    bundle = destination / prefix
    if not bundle.is_dir():
        fail("invalid_package", "The archive does not contain a server bundle.", "Use an official Bloom server package.")
    for directory in [bundle, *(path for path in bundle.rglob("*") if path.is_dir())]:
        directory.chmod(0o755)
    try:
        manifest = json.loads((bundle / "manifest.json").read_text())
        binary = bundle / "bin/bloom-server"
        if (manifest.get("architecture") != "x86_64" or not binary.is_file()
                or not binary.stat().st_mode & 0o111 or not (bundle / "lib").is_dir()
                or not (bundle / "licences").is_dir()):
            raise ValueError("invalid bundle")
    except (ValueError, OSError):
        fail("invalid_package", "The archive is not a compatible Bloom server package.", "Select the Ubuntu x86_64 package.")
    return bundle


def public_key(path):
    import base64
    import struct
    try:
        value = path.read_text().strip()
        parts = value.split(maxsplit=2)
        if len(value) > 1024 or "\n" in value or len(parts) not in (2, 3) or parts[0] != "ssh-ed25519":
            raise ValueError("invalid key")
        raw = base64.b64decode(parts[1], validate=True)
        if len(raw) != 51 or raw[:19] != struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32):
            raise ValueError("invalid key")
        return "ssh-ed25519 " + parts[1]
    except (OSError, ValueError, AttributeError):
        fail("invalid_public_key", "A valid single Ed25519 public key is required.", "Let Bloom create a new server connection key and retry.")


def install_key(args, key, account):
    # Use directory descriptors: the service user can rename .ssh while an update is running.
    home_fd = os.open(args.service_home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    directory_fd = None
    try:
        try:
            os.mkdir(".ssh", mode=0o700, dir_fd=home_fd)
        except FileExistsError:
            pass
        directory_fd = os.open(".ssh", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=home_fd)
        os.fchmod(directory_fd, 0o700)
        os.fchown(directory_fd, account.pw_uid, account.pw_gid)
        existing = ""
        try:
            fd = os.open("authorized_keys", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
            with os.fdopen(fd) as source:
                existing = source.read(1048577)
            if len(existing) > 1048576:
                fail("untrusted_keys", "The SSH key file is unexpectedly large.", "Ask the administrator to inspect authorized_keys.")
        except FileNotFoundError:
            pass
        if not any(key in line.split(" #", 1)[0] for line in existing.splitlines()):
            existing = existing.rstrip("\n") + ("\n" if existing else "") + key + " bloom-client\n"
        name = ".bloom-key-" + os.urandom(8).hex()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
        with os.fdopen(fd, "w") as output:
            os.fchown(output.fileno(), account.pw_uid, account.pw_gid)
            output.write(existing)
        os.replace(name, "authorized_keys", src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    finally:
        if directory_fd is not None:
            os.close(directory_fd)
        os.close(home_fd)


def unit_contents(args):
    return f"""# Managed by Bloom Add Server.
[Unit]
Description=Bloom Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={args.user}
Group={args.user}
Environment=HOME={args.service_home}
Environment=PATH=/opt/bloom-browser/bin:{args.service_home}/.local/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory={args.service_home}
ExecStart={args.install_root}/current/bin/bloom-server serve --data-dir {args.data_dir}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
"""


def socket_path(args):
    value = 2166136261
    for byte in str(args.data_dir / "server.sqlite").encode():
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return pathlib.Path(f"/tmp/bloom-bridge-{value:08x}.sock")


def wait_ready(args, uid):
    deadline = time.monotonic() + 20
    path = socket_path(args)
    while time.monotonic() < deadline:
        result = command(["systemctl", "is-active", "--quiet", args.service_name + ".service"], required=False)
        try:
            info = path.lstat()
            if (result is not None and result.returncode == 0 and stat.S_ISSOCK(info.st_mode)
                    and info.st_uid == uid and not info.st_mode & 0o077):
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(1)
                    connection.connect(str(path))
                    return
        except OSError:
            pass
        time.sleep(0.25)
    fail("startup_failed", "Bloom Server did not start successfully.",
         "The previous installation was restored. Check systemctl status for this service before retrying.")


def atomic_text(path, value):
    temporary = path.with_name(path.name + ".new-" + os.urandom(8).hex())
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w") as output:
        output.write(value)
    os.replace(temporary, path)


# These helpers are deliberately executed with the service UID, including during rollback.
DATABASE_BACKUP = """import os, pathlib, sqlite3, sys
from contextlib import closing
os.umask(0o077)
source, destination = map(pathlib.Path, sys.argv[1:])
with closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)) as source_db, closing(sqlite3.connect(destination)) as target_db:
    source_db.backup(target_db)
"""
DATABASE_RESTORE = """import os, pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
for suffix in ('-wal', '-shm'):
    pathlib.Path(str(destination) + suffix).unlink(missing_ok=True)
temporary = destination.with_name('.bloom-rollback-' + os.urandom(8).hex())
with temporary.open('xb') as target, source.open('rb') as origin:
    shutil.copyfileobj(origin, target)
temporary.chmod(0o600)
os.replace(temporary, destination)
"""


def backup_database(database, staging, account):
    # SQLite needs to create its journal beside the destination. Giving the account only
    # the backup file in a root-owned directory makes every real upgrade fail read-only.
    staging.chmod(0o711)
    private = staging / "database-backup"
    private.mkdir(mode=0o700)
    os.chown(private, account.pw_uid, account.pw_gid)
    backup = private / "server.sqlite"
    try:
        command([sys.executable, "-c", DATABASE_BACKUP, str(database), str(backup)], account=account)
    except InstallError:
        fail("database_backup_failed", "The existing server database could not be backed up.",
             "Check free disk space and the service account's database access. The previous release and database were not replaced.")
    return backup


def install(args):
    if os.geteuid() != 0:
        fail("administrator_required", "Installation needs administrator access.", "Run the installer through sudo -n or connect as root.")
    if not args.package or not args.sha256:
        fail("package_required", "Select a server package and its checksum.", "Choose the packaged Ubuntu server build in Bloom.")
    key = public_key(args.client_public_key_file)
    result = probe(args)
    emit("check", **result)
    if not result["ok"]:
        fail("preflight_failed", "This server is not ready for installation.", "Resolve the reported checks and retry.")
    existing = marker(args)
    if existing and existing.get("sha256") == args.sha256.lower() and service_running(args):
        account = pwd.getpwnam(args.user)
        wait_ready(args, account.pw_uid)
        install_key(args, key, account)
        emit("complete", unchanged=True, **metadata(args))
        return
    if existing and active_work(args.data_dir):
        fail("server_busy", "Agents, queued messages or workspace setup still need this server.", "Finish or stop that work before updating.")
    if existing and (service_running(args) or daemon_locked(args)):
        fail("server_running", "The existing server must be stopped before this update.",
             "Wait for work to finish, stop the Bloom service, and retry. Running sessions are never interrupted automatically.")
    args.install_root.mkdir(parents=True, exist_ok=True, mode=0o755)
    args.install_root.chmod(0o755)
    with tempfile.TemporaryDirectory(prefix=".prepare-", dir=args.install_root) as temporary:
        staging = pathlib.Path(temporary)
        emit("progress", step="verify", message="Verifying the server package")
        bundle = extract_package(args.package, staging, args.sha256)
        # --help checks the loader and bundled libraries without opening a database.
        command([str(bundle / "bin/bloom-server"), "--help"])
        emit("progress", step="dependencies", message="Installing Git, tmux, GitHub CLI and Node.js")
        command(["apt-get", "update", "-qq"], timeout=180)
        command(["apt-get", "install", "-y", "-qq", "git", "tmux", "gh", "ca-certificates", "nodejs", "npm"], timeout=300)
        emit("progress", step="account", message="Preparing a private server account")
        details = {**configuration(args), "sha256": args.sha256.lower(), "phase": "prepared"}
        if not existing:
            atomic_text(args.install_root / ".bloom-installation.json", json.dumps(details) + "\n")
        try:
            pwd.getpwnam(args.user)
        except KeyError:
            command(["useradd", "--system", "--user-group", "--create-home", "--home-dir", str(args.service_home),
                     "--shell", "/bin/bash", args.user])
        account = pwd.getpwnam(args.user)
        for path in (args.service_home, args.data_dir):
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.chmod(0o700)
            os.chown(path, account.pw_uid, account.pw_gid)
        install_key(args, key, account)
        releases = args.install_root / "releases"
        releases.mkdir(mode=0o755, exist_ok=True)
        releases.chmod(0o755)
        release = releases / args.sha256.lower()
        if not release.exists():
            os.replace(bundle, release)
        current = args.install_root / "current"
        previous = os.readlink(current) if current.is_symlink() else None
        if current.exists() and not current.is_symlink():
            fail("installation_conflict", "The server's current release path is not managed by Bloom.", "Restore the managed installation before retrying.")
        unit = args.systemd_dir / (args.service_name + ".service")
        previous_unit = unit.read_text() if unit.exists() else None
        database = args.data_dir / "server.sqlite"
        backup = None
        if database.exists():
            # SQLite and restoration run as the service account. A replaced database symlink must
            # never let an agent trick a root installer into reading or overwriting a root file.
            backup = backup_database(database, staging, account)
        details = {**configuration(args), "sha256": args.sha256.lower(), "phase": "prepared"}
        # Record ownership before starting. A failed first install can safely be retried.
        atomic_text(args.install_root / ".bloom-installation.json", json.dumps(details) + "\n")
        emit("progress", step="service", message="Starting Bloom Server")
        next_link = args.install_root / (".current-new-" + os.urandom(8).hex())
        next_link.symlink_to(release)
        os.replace(next_link, current)
        try:
            atomic_text(unit, unit_contents(args))
            command(["systemctl", "daemon-reload"])
            command(["systemctl", "enable", args.service_name + ".service"])
            command(["systemctl", "start", args.service_name + ".service"])
            wait_ready(args, account.pw_uid)
        except (InstallError, OSError):
            stopped = command(["systemctl", "stop", args.service_name + ".service"], required=False)
            if stopped is None or stopped.returncode != 0:
                fail("rollback_blocked", "The failed service could not be stopped safely.", "Stop the service before restoring its previous release or database.")
            current.unlink(missing_ok=True)
            if previous:
                current.symlink_to(previous)
            if previous_unit is not None:
                atomic_text(unit, previous_unit)
            else:
                command(["systemctl", "disable", args.service_name + ".service"], required=False)
            if backup is not None:
                command([sys.executable, "-c", DATABASE_RESTORE, str(backup), str(database)], account=account)
            if existing:
                atomic_text(args.install_root / ".bloom-installation.json", json.dumps(existing) + "\n")
            command(["systemctl", "daemon-reload"], required=False)
            raise
    details["phase"] = "installed"
    atomic_text(args.install_root / ".bloom-installation.json", json.dumps(details) + "\n")
    emit("complete", unchanged=False, **metadata(args))


def main():
    args = parser().parse_args()
    try:
        configuration(args)
        if args.check:
            result = probe(args)
            emit("check", **result)
            return 0 if result["ok"] else 1
        if os.geteuid() != 0:
            fail("administrator_required", "Installation needs administrator access.", "Run the installer through sudo -n or connect as root.")
        # Serialise concurrent installers without touching the service account's writable home.
        lock_path = pathlib.Path("/run/lock") / ("bloom-install-" + args.service_name + ".lock")
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail("installation_busy", "Another installation is already running.", "Wait for it to finish, then retry.")
            install(args)
        return 0
    except InstallError as error:
        emit("error", code=error.code, message=error.message, recovery=error.recovery)
    except (OSError, ValueError, argparse.ArgumentTypeError):
        emit("error", code="installation_failed", message="Server preparation could not complete.",
             recovery="Check the server's permissions and available disk space, then retry.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
