#!/usr/bin/env python3
"""Optional rootless Docker for a managed Bloom service account. Never grants host Docker access."""
import argparse
import fcntl
import grp
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys

if "stream_install_command" not in globals():
    from bloom_install_process import InstallProcessFailure, install_exception_details, redact_install_text, stream_install_command

CURRENT_STEP = None
PACKAGES = ["docker.io", "docker-compose-v2", "docker-buildx", "uidmap", "rootlesskit", "slirp4netns", "dbus-user-session"]


class DockerError(Exception):
    def __init__(self, code, message, recovery, **metadata):
        super().__init__(redact_install_text(message))
        self.code, self.recovery = code, redact_install_text(recovery)
        self.metadata = metadata


def fail(code, message, recovery, **metadata):
    raise DockerError(code, message, recovery, **metadata)


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
            fail("unsafe_path", f"Docker setup found an unprotected system path: {item}",
                 "Restore root ownership and remove symlinks or group/world write access before retrying.")


def command(arguments, *, account=None, env=None, timeout=300, live=True):
    options = dict(user=account.pw_uid, group=account.pw_gid, extra_groups=[]) if account else {}
    environment = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8", "DEBIAN_FRONTEND": "noninteractive"}
    environment.update(env or {})
    try:
        result = stream_install_command(arguments, timeout=timeout, live=live,
            output=lambda line: emit("output", step=CURRENT_STEP, message=line), env=environment,
            cwd=account.pw_dir if account else "/", **options)
    except InstallProcessFailure as error:
        fail(error.code, f"{error.command} could not complete.",
             "Review Docker setup output and retry. Bloom Server remains available.",
             command=error.command, exitStatus=error.exit_status, details=error.details)
    if result.returncode:
        fail("command_failed", f"{result.command} exited with status {result.returncode}.",
             "Review Docker setup output and retry. Bloom Server remains available.",
             command=result.command, exitStatus=result.returncode, details=result.details)
    return result.stdout.decode("utf-8", errors="replace")


def managed_account(options, marker_directory=Path("/etc/systemd/system/bloom-installations")):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", options.user) or not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", options.service_name):
        fail("invalid_configuration", "Invalid service account or service name.", "Use the managed Bloom Server installation settings.")
    account = pwd.getpwnam(options.user)
    home = options.service_home or account.pw_dir
    if account.pw_uid == 0 or home != account.pw_dir or not re.fullmatch(r"/[A-Za-z0-9_./-]+", home) or ".." in Path(home).parts or home == "/":
        fail("invalid_account", "Docker needs the non-root Bloom service account and its actual home directory.", "Use the account created by Add Server.")
    marker = marker_directory / (options.service_name + ".json")
    protected(marker)
    details = json.loads(marker.read_text())
    if details.get("phase") != "installed" or details.get("serviceUser") != options.user or details.get("serviceHome") != home or details.get("serviceName") != options.service_name:
        fail("unmanaged_account", "This account does not match a completed Bloom Server installation.", "Complete Add Server before installing Docker.")
    protected(Path(home).parent)
    info = Path(home).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != account.pw_uid or info.st_mode & 0o077:
        fail("unsafe_home", "The Bloom account home is not a private directory owned by that account.", "Restore service-user ownership and mode 0700, then retry.")
    return account


def ranges(text):
    result = []
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split(":")
        if len(parts) != 3 or not parts[1].isdigit() or not parts[2].isdigit():
            fail("invalid_subordinate_ids", "A subordinate ID file contains an invalid entry.", "Repair /etc/subuid and /etc/subgid before retrying.")
        start, count = map(int, parts[1:])
        if count < 1 or start < 1 or start + count > 4294967295:
            fail("invalid_subordinate_ids", "A subordinate ID range is invalid.", "Repair /etc/subuid and /etc/subgid before retrying.")
        result.append((parts[0], start, start + count))
    return result


def selected_range(entries, user):
    for owner, start, end in entries:
        if owner == user and end - start >= 65536:
            if any(other != user and start < stop and begin < end for other, begin, stop in entries):
                fail("overlapping_subordinate_ids", "This account's subordinate IDs overlap another account.", "Allocate exclusive ranges in /etc/subuid and /etc/subgid before retrying.")
            return start, end
    return None


def free_range(entries):
    candidate = 100000
    for _owner, start, end in sorted(entries, key=lambda item: item[1]):
        if candidate + 65536 <= start:
            break
        if candidate < end:
            candidate = end
    if candidate + 65536 > 4294967295:
        fail("subordinate_ids_exhausted", "No free subordinate ID range is available.", "Ask the server administrator to reserve 65536 subordinate IDs.")
    return candidate, candidate + 65536


def reserve_ranges(account):
    paths = [Path("/etc/subuid"), Path("/etc/subgid")]
    for path in paths:
        protected(path)
    entries = [ranges(path.read_text()) if path.exists() else [] for path in paths]
    additions = []
    occupied = entries[0] + entries[1] + [(item.pw_name, item.pw_uid, item.pw_uid + 1) for item in pwd.getpwall()]
    occupied += [(item.gr_name, item.gr_gid, item.gr_gid + 1) for item in grp.getgrall()]
    for flag, values in zip(("--add-subuids", "--add-subgids"), entries):
        if selected_range(values, account.pw_name):
            continue
        start, end = free_range(occupied)
        occupied.append((account.pw_name, start, end))
        additions.extend([flag, f"{start}-{end - 1}"])
    if additions:
        # usermod owns shadow's native file locks and atomic replacement. The outer installer
        # lock serialises our allocation decisions; rereading also detects external edits.
        command(["usermod", *additions, account.pw_name])
    for path in paths:
        protected(path)
        if not selected_range(ranges(path.read_text()), account.pw_name):
            fail("missing_subordinate_ids", "The service account has no usable subordinate ID range.", "Reserve 65536 IDs in both /etc/subuid and /etc/subgid, then retry.")


# Every access beneath the user-writable home happens after dropping root. A hostile symlink
# can at most exercise that account's existing rights, never redirect privileged writes.
PREPARE_HOME = r'''
import json, os, pathlib, stat, sys
home = pathlib.Path(sys.argv[1])
def directory(path):
    if path.exists() or path.is_symlink():
        value = path.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or value.st_mode & 0o022:
            raise RuntimeError("Unsafe user configuration directory: " + str(path))
    else:
        path.mkdir(mode=0o700)
def file(path, content):
    if path.exists() or path.is_symlink():
        value = path.lstat()
        if not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid() or path.read_text() != content:
            raise RuntimeError("Existing Docker configuration differs: " + str(path))
    else:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as output: output.write(content)
for relative in ("bloom", "bloom/bin", "bloom/docker", ".config", ".config/docker", ".config/systemd", ".config/systemd/user"):
    directory(home / relative)
binary = home / "bloom/bin"
for name, target in {"docker": "/usr/bin/docker", "rootlesskit": "/usr/bin/rootlesskit",
        "dockerd-rootless.sh": "/usr/share/docker.io/contrib/dockerd-rootless.sh"}.items():
    link = binary / name
    if link.exists() or link.is_symlink():
        if not link.is_symlink() or os.readlink(link) != target:
            raise RuntimeError("Existing Docker executable differs: " + str(link))
    else:
        link.symlink_to(target)
marker = home / "bloom/docker/.bloom-managed"
unit = home / ".config/systemd/user/docker.service"
if (unit.exists() or unit.is_symlink()) and not marker.exists():
    raise RuntimeError("An existing user Docker service is not managed by Bloom")
file(home / ".config/docker/daemon.json", json.dumps({"data-root": str(home / "bloom/docker/data")}, sort_keys=True) + "\n")
file(marker, "Bloom rootless Docker v1\n")
'''


def user_environment(account):
    runtime = f"/run/user/{account.pw_uid}"
    return {"HOME": account.pw_dir, "USER": account.pw_name, "LOGNAME": account.pw_name,
            "PATH": account.pw_dir + "/bloom/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "XDG_RUNTIME_DIR": runtime, "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + runtime + "/bus"}


def verify(account):
    environment = user_environment(account)
    expected_socket = f"/run/user/{account.pw_uid}/docker.sock"
    context = command(["/usr/bin/docker", "context", "show"], account=account, env=environment, timeout=15, live=False).strip()
    endpoint = command(["/usr/bin/docker", "context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"],
                       account=account, env=environment, timeout=15, live=False)
    if context != "rootless" or json.loads(endpoint) != "unix://" + expected_socket:
        fail("incorrect_docker_context", "The Bloom account is not using its private Docker connection.",
             "Run optional Docker setup again to select the rootless context. Do not grant access to the host Docker socket.")
    # Probe the same HOME-selected context workspace commands use, without DOCKER_HOST or
    # DOCKER_CONTEXT overrides that could disguise a broken default connection.
    raw = command(["/usr/bin/docker", "info", "--format", "{{json .}}"], account=account, env=environment, timeout=30, live=False)
    info = json.loads(raw)
    if not any(value == "name=rootless" or value.startswith("name=rootless,") for value in info.get("SecurityOptions", [])):
        fail("not_rootless", "Docker did not report rootless protection.", "Use Bloom's private user Docker daemon. Do not grant access to the host Docker socket.")
    expected = account.pw_dir + "/bloom/docker/data"
    if info.get("DockerRootDir") != expected:
        fail("unexpected_data_directory", "Docker is using an unexpected data directory.", "Review the user Docker daemon configuration before retrying.")
    command(["/usr/bin/docker", "compose", "version"], account=account, env=environment, timeout=15, live=False)
    return dict(ready=True, rootless=True, user=account.pw_name, serviceHome=account.pw_dir,
                dataDirectory=expected, socket=expected_socket, version=info.get("ServerVersion"))


def install(account):
    release = Path("/etc/os-release").read_text()
    if not re.search(r'^ID=["\']?ubuntu["\']?$', release, re.M):
        fail("unsupported_system", "Automatic Docker setup supports Ubuntu servers.", "Configure rootless Docker manually on other distributions.")
    emit("progress", step="docker_dependencies", message="Installing Docker, Compose and rootless dependencies")
    command(["apt-get", "update"], timeout=600)
    command(["apt-get", "install", "--simulate", "--no-remove", "--no-install-recommends", *PACKAGES])
    command(["apt-get", "install", "-y", "--no-remove", "--no-install-recommends", *PACKAGES], timeout=900)
    for path in ("/usr/share/docker.io/contrib/dockerd-rootless.sh", "/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh", "/usr/bin/docker", "/usr/bin/rootlesskit"):
        protected(Path(path))
        if not Path(path).is_file():
            fail("missing_rootless_tool", "The Ubuntu Docker package is missing its rootless helper.", "Install an Ubuntu package version with Docker rootless support, then retry.")
    emit("progress", step="docker_account", message="Preparing private container storage and subordinate user IDs")
    reserve_ranges(account)
    environment = user_environment(account)
    command([sys.executable, "-c", PREPARE_HOME, account.pw_dir], account=account, env=environment, live=False)
    emit("progress", step="docker_service", message="Starting Docker as the Bloom account")
    command(["loginctl", "enable-linger", account.pw_name])
    command(["systemctl", "start", f"user@{account.pw_uid}.service"])
    # No --force: the upstream prerequisite checks must succeed without bypasses.
    command(["/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh", "install"],
            account=account, env=environment, timeout=180)
    command(["/usr/bin/docker", "context", "use", "rootless"], account=account, env=environment, timeout=15)
    emit("progress", step="docker_verify", message="Checking the private Docker daemon and Compose")
    return verify(account)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="bloom")
    parser.add_argument("--service-home")
    parser.add_argument("--service-name", default="bloom-server")
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    if os.geteuid() != 0:
        fail("root_required", "Docker setup needs administrator access.", "Run this optional installer using the server administrator connection.")
    account = managed_account(options)
    if options.check:
        emit("complete", **verify(account))
        return
    directory = Path("/run/bloom-installers")
    protected(directory)
    directory.mkdir(mode=0o755, exist_ok=True)
    path = directory / "docker.lock"
    protected(path)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            fail("unsafe_lock", "Docker's installation lock is not private and root-owned.", "Restore the protected installer lock before retrying.")
        fcntl.flock(lock, fcntl.LOCK_EX)
        emit("complete", **install(account))


def entrypoint():
    try:
        main()
        return 0
    except DockerError as error:
        emit("error", ready=False, code=error.code, message=str(error), recovery=error.recovery, **error.metadata)
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        emit("error", ready=False, code="docker_setup_failed", message="Optional Docker setup could not complete.",
             recovery="Review the diagnostic and retry Docker setup. Bloom Server remains available.", details=install_exception_details(error))
    return 1


if __name__ == "__main__":
    sys.exit(entrypoint())
