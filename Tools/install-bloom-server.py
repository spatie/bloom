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
import signal
import selectors
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time


if "stream_install_command" not in globals():
    from bloom_install_process import InstallProcessCancelled, InstallProcessFailure, install_cancellation_scope, install_exception_details, redact_install_text, stream_install_command

CURRENT_STEP = None
SYSTEM_PATH = "/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


class InstallError(Exception):
    def __init__(self, code, message, recovery, **metadata):
        super().__init__(message)
        self.code, self.message, self.recovery = code, message, recovery
        self.metadata = metadata


def fail(code, message, recovery, **metadata):
    raise InstallError(code, redact_install_text(message), redact_install_text(recovery),
        **{key: redact_install_text(value) if isinstance(value, str) else value for key, value in metadata.items()})


def emit(event, **fields):
    global CURRENT_STEP
    if event == "progress" and fields.get("step"):
        CURRENT_STEP = fields["step"]
    print(json.dumps({"event": event, **fields}, separators=(",", ":")), flush=True)


def command(arguments, timeout=30, required=True, account=None):
    name = pathlib.Path(arguments[0]).name
    live = name in ("apt-get", "systemctl", "useradd") and arguments[:2] not in (["systemctl", "show"], ["systemctl", "is-active"])
    try:
        result = stream_install_command(arguments, timeout=timeout, live=live,
            output=lambda line: emit("output", message=line, step=CURRENT_STEP),
            **({"user": account.pw_uid, "group": account.pw_gid, "extra_groups": [], "cwd": "/"} if account else {}),
            env={"PATH": SYSTEM_PATH, "LANG": "C.UTF-8", "DEBIAN_FRONTEND": "noninteractive",
                 **({"HOME": account.pw_dir} if account else {})})
    except InstallProcessFailure as error:
        if not required and error.code != "cancelled":
            return None
        fail(error.code, f"{error.command} " + ("timed out." if error.code == "command_timeout" else "could not complete."),
             "Review the command output below. Check the server's network, package manager and available disk space, then retry.",
             command=error.command, exitStatus=error.exit_status, details=error.details)
    if required and result.returncode:
        fail("command_failed", f"{result.command} exited with status {result.returncode}.",
             "Review the command output below. Resolve the reported package or service problem, then choose Check Again.",
             command=result.command, exitStatus=result.returncode, details=result.details)
    return result


def package_installed(name):
    result = command(["dpkg-query", "-W", "-f=${db:Status-Status}", name], required=False)
    return result is not None and result.returncode == 0 and result.stdout.strip() == b"installed"


def node_tool_status(account):
    status = {}
    for name in ("node", "npm"):
        executable = shutil.which(name, path=SYSTEM_PATH)
        result = command([executable, "--version"], required=False, account=account) if executable else None
        status[name] = result is not None and result.returncode == 0
    return status


def verify_node_tools(account, status=None):
    status = node_tool_status(account) if status is None else status
    if not all(status.values()):
        missing = ", ".join(name for name, ready in status.items() if not ready)
        fail("npm_unavailable", f"The server account cannot run {missing} from the system PATH.",
             "Ask your administrator to repair Node.js and its matching npm installation in /usr/local/bin or /usr/bin, "
             "then choose Check Again. A root-only nvm installation is not available to Bloom. "
             "Bloom will not replace an existing Node.js provider or remove packages to resolve a conflict.",
             command=missing + " --version", exitStatus=None,
             details="Check executable permissions and ensure node and npm can run as the dedicated Bloom account.")


def install_dependencies(args):
    emit("progress", step="dependencies", message="Checking existing Git, GitHub CLI, tmux and Node.js/npm")
    # Probe under an unprivileged account, using only paths the eventual service can see.
    # In particular, NodeSource's nodejs package already contains npm and conflicts with
    # Ubuntu's separate npm package. Never replace a working provider with that package.
    try:
        account = pwd.getpwnam(args.user)
    except KeyError:
        account = pwd.getpwnam("nobody")
    status = node_tool_status(account)
    packages = [name for name in ("git", "tmux", "gh", "ca-certificates") if not package_installed(name)]
    if not all(status.values()):
        if any(status.values()) or package_installed("nodejs"):
            verify_node_tools(account, status=status)
        packages.extend(name for name in ("nodejs", "npm") if not package_installed(name))
    if not packages:
        emit("progress", step="dependencies", message="Git, tmux, GitHub CLI, certificates and Node.js/npm are already available")
        return
    emit("progress", step="dependencies", message="Installing missing packages: " + ", ".join(packages))
    command(["apt-get", "update"], timeout=180)
    command(["apt-get", "install", "--simulate", "--no-remove", *packages], timeout=180)
    command(["apt-get", "install", "-y", "--no-remove", *packages], timeout=600)


def valid_path(value):
    path = pathlib.Path(value)
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", value) or ".." in path.parts or path == pathlib.Path("/"):
        raise argparse.ArgumentTypeError("Use an absolute path containing letters, digits, /, _, - and .")
    if any(part.is_symlink() for part in [path, *path.parents]):
        raise argparse.ArgumentTypeError("Installation paths must not contain symbolic links")
    return path


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    mode = result.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--stop-server", action="store_true")
    result.add_argument("--package", type=pathlib.Path)
    result.add_argument("--sha256")
    result.add_argument("--install-root", type=valid_path, default=None)
    result.add_argument("--data-dir", type=valid_path, default=None)
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
    args.service_home = args.service_home or pathlib.Path("/home") / args.user
    args.install_root = args.install_root or args.service_home / "bloom/server"
    args.data_dir = args.data_dir or args.service_home / "bloom/data"
    for path in (args.install_root, args.data_dir, args.service_home, args.systemd_dir):
        valid_path(str(path))
    paths = (args.install_root, args.data_dir)
    if any(a == b or a in b.parents or b in a.parents for i, a in enumerate(paths) for b in paths[i + 1:]):
        fail("invalid_configuration", "The server executable and data directories must be separate.",
             "Use the default installation settings.")
    return {"format": 2, "installRoot": str(args.install_root), "dataDirectory": str(args.data_dir),
            "serviceHome": str(args.service_home), "serviceUser": args.user, "serviceName": args.service_name,
            "systemdDirectory": str(args.systemd_dir)}


def metadata(args):
    return {"installationRoot": str(args.install_root), "executable": str(args.install_root / "current/bin/bloom-server"),
            "dataDirectory": str(args.data_dir), "serviceUser": args.user, "serviceHome": str(args.service_home)}


def protected_system_path(path, allow_sticky=False):
    for item in (path, *path.parents):
        if item.is_symlink():
            fail("untrusted_directory", "A system integration path is a symbolic link.", "Use protected system directories without symlinks.")
        if item.exists():
            info = item.stat()
            if info.st_uid != 0 or (info.st_mode & 0o022 and not (allow_sticky and info.st_mode & stat.S_ISVTX)):
                fail("untrusted_directory", "A system integration path is writable by another account.", "Restore root ownership and protected permissions.")


def marker_path(args):
    return args.systemd_dir / "bloom-installations" / (args.service_name + ".json")


def save_marker(args, value):
    path = marker_path(args)
    protected_system_path(path)
    path.parent.mkdir(mode=0o755, exist_ok=True)
    atomic_text(path, json.dumps(value) + "\n")


def marker(args):
    path = marker_path(args)
    protected_system_path(path)
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text())
    except (ValueError, OSError):
        fail("untrusted_installation", "The installation marker could not be read.", "Restore its original metadata before retrying.")
    expected = configuration(args)
    if any(value.get(key) != item for key, item in expected.items()):
        fail("installation_conflict", "This installation uses different paths or a different service account.",
             "Connect using its original settings. Bloom will not replace another installation.")
    return value


def account_operation(account, operation, timeout=120):
    """User-controlled paths are never opened or changed with installer privileges."""
    try:
        with install_cancellation_scope():
            return _account_operation(account, operation, timeout)
    except InstallProcessCancelled:
        fail("cancelled", "Server file preparation was cancelled.", "Choose Check Again to inspect the server before retrying setup.")


def _account_operation(account, operation, timeout):
    if account.pw_uid == 0:
        fail("invalid_service_user", "Bloom file operations require a non-root service account.", "Use the dedicated Bloom service account.")
    if os.getuid() == account.pw_uid:
        previous_mask = os.umask(0o077)
        try:
            return operation()
        finally:
            os.umask(previous_mask)
    reader, writer = os.pipe()
    try:
        pid = os.fork()
    except BaseException:
        os.close(reader)
        os.close(writer)
        raise
    if pid == 0:
        os.close(reader)
        try:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            signal.signal(signal.SIGHUP, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_SETMASK, [])
            os.setgroups([])
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
            os.umask(0o077)
            if os.geteuid() == 0:
                raise RuntimeError("The service account must not be root")
            os.environ["HOME"] = account.pw_dir
            os.environ["PATH"] = SYSTEM_PATH
            value = {"result": operation()}
        except InstallError as error:
            value = {"error": {"code": error.code, "message": error.message, "recovery": error.recovery, "metadata": error.metadata}}
        except BaseException as error:
            value = {"error": {"code": "account_files_failed", "message": "The server account could not prepare its files.",
                               "recovery": "Check the service account's directory permissions and free space, then retry.",
                               "metadata": {"details": install_exception_details(error)}}}
        try:
            with os.fdopen(writer, "w") as output:
                json.dump(value, output)
        finally:
            os._exit(0)
    os.close(writer)
    reaped = False
    deadline = time.monotonic() + timeout
    try:
        raw = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(reader, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    fail("account_files_timeout", "The server account file operation timed out.",
                         "Check filesystem availability and free space, then retry.")
                chunk = os.read(reader, 65536)
                if not chunk:
                    break
                raw.extend(chunk)
                if len(raw) > 1_048_576:
                    raise ValueError("The service file operation returned too much data")
        while True:
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                reaped = True
                break
            if time.monotonic() >= deadline:
                fail("account_files_timeout", "The server account process did not finish.", "Check filesystem availability and retry.")
            time.sleep(0.01)
        if status != 0:
            raise ValueError("The service file operation did not finish")
        value = json.loads(raw)
        if "error" in value:
            error = value["error"]
            fail(error["code"], error["message"], error["recovery"], **error.get("metadata", {}))
        return value["result"]
    except (OSError, ValueError, KeyError) as error:
        fail("account_files_failed", "The server account file operation failed.",
             "Inspect its directory permissions and retry.", details=install_exception_details(error))
    finally:
        os.close(reader)
        if not reaped:
            stop_account_child(pid)


def stop_account_child(pid):
    # Cancellation must not wait indefinitely for user-owned storage or inherited handlers.
    for pending_signal, grace in ((signal.SIGTERM, 0.25), (signal.SIGKILL, 1.0)):
        try:
            os.kill(pid, pending_signal)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            try:
                ended, _ = os.waitpid(pid, os.WNOHANG)
                if ended:
                    return
            except ChildProcessError:
                return
            time.sleep(0.01)


def existing_account(args, existing):
    try:
        return pwd.getpwnam(args.user)
    except KeyError:
        if existing.get("phase") == "prepared":
            return None
        fail("installation_conflict", "The server account is missing.", "Restore the original server account settings.")


def check_ownership(args, existing):
    unit = args.systemd_dir / (args.service_name + ".service")
    protected_system_path(unit)
    protected_system_path(args.service_home.parent)
    if existing:
        if not unit.exists() and existing.get("phase") != "prepared":
            fail("installation_conflict", "The server service file is missing.", "Restore the original service file before retrying.")
        account = existing_account(args, existing)
        if account is None:
            return
        if account.pw_dir != str(args.service_home) or account.pw_uid == 0:
            fail("installation_conflict", "The server account does not match this installation.", "Restore the original server account settings.")
        def inspect_private_directories():
            for path in (args.install_root, args.data_dir, args.service_home):
                if not path.exists() and existing.get("phase") == "prepared":
                    continue
                if path.is_symlink() or not path.is_dir() or path.stat().st_uid != account.pw_uid or path.stat().st_mode & 0o077:
                    fail("untrusted_installation", "The server's private directories have unexpected permissions.",
                         "Restore service account ownership and mode 700 before retrying.")
        account_operation(account, inspect_private_directories)
        return
    for path in (args.install_root, args.data_dir, args.service_home):
        for parent in path.parents:
            protected_system_path(parent)
        if path.exists() and (path.stat().st_uid != 0 or not path.is_dir() or any(path.iterdir())):
            fail("installation_conflict", "An installation directory already contains unrelated files.",
                 "Choose a fresh account and empty directories. Existing files will not be replaced.")
    if unit.exists() or unit.is_symlink():
        fail("installation_conflict", "A system service already uses this name.", "Choose a different service name.")
    try:
        pwd.getpwnam(args.user)
    except KeyError:
        return
    fail("service_account_exists",
         f"The Linux account '{args.user}' already exists, but no matching managed Bloom installation metadata was found.",
         "If this account runs Bloom, connect through Advanced Settings using its existing installation. "
         "If it belongs to a retired setup, ask an administrator to inspect its files and processes, back up anything needed, "
         "and remove the account only after confirming it is unused. Then choose Check Again. Otherwise, use a fresh server.")


def active_work(data_directory, include_commands=False):
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
            if include_commands and "settings" in tables:
                for (raw,) in connection.execute("SELECT value FROM settings WHERE key GLOB 'server.command.*'"):
                    record = json.loads(raw)
                    if not isinstance(record, dict) or not isinstance(record.get("request"), dict):
                        raise ValueError("unknown command journal")
                    if record.get("reply") is None:
                        fail("command_outcome_unknown", "A recorded server command has no confirmed outcome.",
                             "This may be an interrupted historical command. Bloom cannot safely confirm an idle stop. "
                             "Ask an administrator to inspect the server and stop its managed service manually if safe. No service was stopped.")
                    if not isinstance(record["reply"], dict):
                        raise ValueError("unknown command reply")
            return False
    except (sqlite3.Error, ValueError, OSError, TypeError):
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


def check_existing_activity(args, account):
    if account_operation(account, lambda: active_work(args.data_dir)):
        fail("server_busy", "Agents, queued messages or workspace setup still need this server.",
             "Finish that work in Bloom, then click Check Again. Stop the service only after all work is idle.")
    if service_running(args) or account_operation(account, lambda: daemon_locked(args)):
        service = args.service_name + ".service"
        fail("server_running", "Bloom Server is running. Stop it before updating.",
             "Wait until agents and workspace setup have finished. In an SSH terminal on the server, run "
             "`sudo systemctl stop " + service + "`, then `systemctl is-active " + service + "` to confirm it is inactive. "
             "If Bloom was started manually, stop it in the terminal or process manager that started it. "
             "Click Check Again in Bloom. To use the current server without updating, choose Connect to Existing Server.")


def managed_service_state(args):
    unit = args.systemd_dir / (args.service_name + ".service")
    protected_system_path(unit)
    if unit.read_text().strip() != unit_contents(args).strip():
        fail("unmanaged_server", "The service configuration no longer matches Bloom's managed installation.",
             "Inspect the changed service in an SSH terminal. Bloom will not stop a different service.")
    fields = ["LoadState", "ActiveState", "SubState", "MainPID", "User", "Group", "FragmentPath", "DropInPaths", "NeedDaemonReload", "ControlGroup"]
    result = command(["systemctl", "show", args.service_name + ".service", "--property=" + ",".join(fields)], timeout=8, required=False)
    if result is None or result.returncode:
        fail("service_state_unknown", "The managed service state could not be checked.", "Check systemd in an SSH terminal before stopping anything.")
    values = dict(line.split("=", 1) for line in result.stdout.decode("utf-8").splitlines() if "=" in line)
    if (not set(fields).issubset(values) or values["LoadState"] != "loaded" or values["FragmentPath"] != str(unit)
            or values["User"] != args.user or values["Group"] != args.user or values["DropInPaths"]
            or values["NeedDaemonReload"] != "no"):
        fail("unmanaged_server", "The running service does not match the verified Bloom service.",
             "Inspect its unit, account and drop-in configuration in an SSH terminal. No service was stopped.")
    return values


def verify_managed_process(args, account, state, proc=pathlib.Path("/proc")):
    try:
        pid = int(state["MainPID"])
        if pid <= 1 or not state["ControlGroup"]:
            raise ValueError("missing main process")
        root = proc / str(pid)
        expected = str(args.install_root / "current/bin/bloom-server")
        if os.readlink(root / "exe") != os.path.realpath(expected):
            raise ValueError("different executable")
        with (root / "cmdline").open("rb") as source:
            argv = source.read(65537).split(b"\0")
        if argv != [os.fsencode(expected), b"serve", b"--data-dir", os.fsencode(args.data_dir), b""]:
            raise ValueError("different service arguments")
        fields = dict(line.split(":", 1) for line in (root / "status").read_text().splitlines() if ":" in line)
        if [int(value) for value in fields["Uid"].split()] != [account.pw_uid] * 4:
            raise ValueError("different process account")
        groups = [line.split(":", 2)[-1] for line in (root / "cgroup").read_text().splitlines()]
        if state["ControlGroup"] not in groups:
            raise ValueError("different process group")
    except (OSError, ValueError, KeyError):
        fail("unmanaged_server", "Bloom could not identify the running process as its managed server.",
             "If the server was started manually, stop it in the terminal or process manager that started it. No process was signalled.")


def stop_server(args):
    if os.geteuid() != 0:
        fail("administrator_required", "Stopping the managed service needs administrator access.", "Connect as root or use passwordless sudo.")
    existing = marker(args)
    if not existing or existing.get("phase") != "installed":
        fail("unmanaged_server", "There is no completed managed Bloom installation to stop.", "Use the server's original terminal or process manager.")
    check_ownership(args, existing)
    account = existing_account(args, existing)
    state = managed_service_state(args)
    if account_operation(account, lambda: active_work(args.data_dir, include_commands=True)):
        fail("server_busy", "Agents, queued prompts or workspace setup still need this server.",
             "Finish or cancel that work in Bloom, then choose Check Again. No service was stopped.")
    if state["ActiveState"] in ("inactive", "failed") and state["MainPID"] == "0":
        if account_operation(account, lambda: daemon_locked(args)):
            fail("unmanaged_server", "A manually started process still owns the server data.", "Stop it using its original terminal or process manager.")
        return probe(args)
    if state["ActiveState"] != "active" or state["SubState"] != "running":
        fail("server_running", "The service is changing state. Wait before stopping it.", "Let startup or shutdown finish, then choose Check Again.")
    verify_managed_process(args, account, state)
    # This is a confirmed administrative stop, not an atomic idle-maintenance protocol.
    # The installer lock excludes other installers, but new client work can arrive after this
    # last database check. A future daemon admission barrier would be needed to remove that race.
    if account_operation(account, lambda: active_work(args.data_dir, include_commands=True)):
        fail("server_busy", "New work arrived before the server could be stopped.", "Finish that work in Bloom, then choose Check Again. No service was stopped.")
    latest = managed_service_state(args)
    if latest != state:
        fail("server_running", "The managed service changed while its activity was checked.", "Choose Check Again. No service was stopped.")
    verify_managed_process(args, account, latest)
    emit("progress", step="stop-server", message="Stopping the managed Bloom Server service")
    command(["systemctl", "stop", args.service_name + ".service"], timeout=40)
    stopped = managed_service_state(args)
    if stopped["ActiveState"] not in ("inactive", "failed") or stopped["MainPID"] != "0":
        fail("stop_failed", "The service has not stopped.", "Check the service in an SSH terminal, then choose Check Again.")
    if account_operation(account, lambda: daemon_locked(args)):
        fail("stop_failed", "A process still owns the server data after the service stopped.", "Inspect manually started processes before continuing. Bloom will not stop unrelated processes.")
    return probe(args)


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
        account = existing_account(args, existing) if existing and privilege == "root" else None
        if account is not None:
            check_existing_activity(args, account)
    except InstallError as error:
        blockers.append({"code": error.code, "message": error.message, "recovery": error.recovery})
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
    details = "The service did not become ready within 20 seconds."
    try:
        journal = command(["journalctl", "-u", args.service_name + ".service", "-n", "40", "--no-pager", "--output=cat"],
                          timeout=5, required=False)
        if journal is not None:
            output = getattr(journal, "details", None)
            if output is None:
                output = (journal.stdout or b"").decode("utf-8", errors="replace")
            output = redact_install_text(output)
            if output:
                for line in output.splitlines():
                    emit("output", message=line, step="service")
                details += ("\nRecent service journal:\n" if journal.returncode == 0 else "\nJournal diagnostics could not be read:\n") + output
        else:
            details += "\nThe service journal could not be retrieved."
    except InstallError as error:
        if error.code == "cancelled":
            raise
        details += "\nJournal diagnostics unavailable: " + error.message
    except (OSError, ValueError) as error:
        details += "\nJournal diagnostics unavailable: " + install_exception_details(error)
    fail("startup_failed", "Bloom Server did not start successfully.",
         "Review the service output below. Check the Bloom service status and correct the startup error before retrying.",
         command="systemctl start " + args.service_name + ".service", exitStatus=None, details=redact_install_text(details))


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
    except InstallError as error:
        fail("database_backup_failed", "The existing server database could not be backed up.",
             "Check free disk space and the service account's database access. The previous release and database were not replaced.", **error.metadata)
    return backup


def prepare_account_files(args, key, bundle, checksum, account):
    for path in (args.install_root, args.data_dir):
        valid_path(str(path))
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
    install_key(args, key, account)
    releases = args.install_root / "releases"
    valid_path(str(releases))
    releases.mkdir(mode=0o700, exist_ok=True)
    release = releases / checksum
    valid_path(str(release))
    # The service account owns runtime files. Always repair from the verified archive,
    # even if a directory already has the expected release name.
    temporary = pathlib.Path(tempfile.mkdtemp(prefix=".release-", dir=releases))
    try:
        shutil.copytree(bundle, temporary / "bundle")
        if release.exists():
            os.replace(release, temporary / "previous")
        try:
            os.replace(temporary / "bundle", release)
        except OSError:
            if (temporary / "previous").exists():
                os.replace(temporary / "previous", release)
            raise
    finally:
        shutil.rmtree(temporary)
    current = args.install_root / "current"
    if current.exists() and not current.is_symlink():
        fail("installation_conflict", "The server's current release path is not managed by Bloom.", "Restore the managed installation before retrying.")
    return os.readlink(current) if current.is_symlink() else None


def set_current_release(args, target):
    current = args.install_root / "current"
    if target is None:
        current.unlink(missing_ok=True)
        return
    temporary = args.install_root / (".current-new-" + os.urandom(8).hex())
    temporary.symlink_to(target)
    os.replace(temporary, current)


def install(args):
    if os.geteuid() != 0:
        fail("administrator_required", "Installation needs administrator access.", "Run the installer through sudo -n or connect as root.")
    if not args.package or not args.sha256:
        fail("package_required", "Select a server package and its checksum.", "Choose the packaged Ubuntu server build in Bloom.")
    key = public_key(args.client_public_key_file)
    result = probe(args)
    emit("check", **result)
    if not result["ok"]:
        blocker = result["blockers"][0]
        fail(blocker["code"], blocker["message"], blocker.get("recovery", "Resolve the reported checks and retry."))
    existing = marker(args)
    account = existing_account(args, existing) if existing else None
    if account is not None:
        check_existing_activity(args, account)
    protected_system_path(pathlib.Path("/var/tmp"), allow_sticky=True)
    with tempfile.TemporaryDirectory(prefix="bloom-server-install-", dir="/var/tmp") as temporary:
        staging = pathlib.Path(temporary)
        emit("progress", step="verify", message="Verifying the uploaded package")
        bundle = extract_package(args.package, staging, args.sha256)
        emit("progress", step="dependencies", message="Checking Git, tmux, GitHub CLI and Node.js")
        install_dependencies(args)
        if not existing:
            save_marker(args, {**configuration(args), "sha256": args.sha256.lower(), "phase": "prepared"})
        emit("progress", step="account", message="Preparing the dedicated server account")
        try:
            pwd.getpwnam(args.user)
        except KeyError:
            command(["useradd", "--system", "--user-group", "--create-home", "--home-dir", str(args.service_home),
                     "--shell", "/bin/bash", args.user])
        account = pwd.getpwnam(args.user)
        protected_system_path(args.service_home.parent)
        args.service_home.mkdir(exist_ok=True, mode=0o700)
        home_fd = os.open(args.service_home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchmod(home_fd, 0o700)
            os.fchown(home_fd, account.pw_uid, account.pw_gid)
        finally:
            os.close(home_fd)
        verify_node_tools(account)
        staging.chmod(0o711)
        previous = account_operation(account, lambda: prepare_account_files(args, key, bundle, args.sha256.lower(), account))
        unit = args.systemd_dir / (args.service_name + ".service")
        previous_unit = unit.read_text() if unit.exists() else None
        database = args.data_dir / "server.sqlite"
        backup = None
        if account_operation(account, lambda: database.exists()):
            backup = backup_database(database, staging, account)
        details = {**configuration(args), "sha256": args.sha256.lower(), "phase": "prepared"}
        save_marker(args, details)
        emit("progress", step="service", message="Starting Bloom Server")
        release = args.install_root / "releases" / args.sha256.lower()
        account_operation(account, lambda: set_current_release(args, str(release)))
        try:
            protected_system_path(unit)
            atomic_text(unit, unit_contents(args))
            command(["systemctl", "daemon-reload"])
            command(["systemctl", "enable", args.service_name + ".service"])
            command(["systemctl", "start", args.service_name + ".service"])
            wait_ready(args, account.pw_uid)
        except (InstallError, OSError):
            stopped = command(["systemctl", "stop", args.service_name + ".service"], required=False)
            if stopped is None or stopped.returncode != 0:
                fail("rollback_blocked", "The failed service could not be stopped safely.", "Stop the service before restoring its previous release or database.")
            account_operation(account, lambda: set_current_release(args, previous))
            if previous_unit is not None:
                atomic_text(unit, previous_unit)
            else:
                command(["systemctl", "disable", args.service_name + ".service"], required=False)
            if backup is not None:
                command([sys.executable, "-c", DATABASE_RESTORE, str(backup), str(database)], account=account)
            if existing:
                save_marker(args, existing)
            command(["systemctl", "daemon-reload"], required=False)
            raise
    details["phase"] = "installed"
    save_marker(args, details)
    emit("complete", unchanged=False, **metadata(args))


def open_installation_lock(service_name, directory=pathlib.Path("/run/bloom-installers")):
    protected_system_path(directory)
    directory.mkdir(mode=0o755, exist_ok=True)
    path = directory / (service_name + ".lock")
    protected_system_path(path)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != 0 or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            fail("untrusted_lock", "The installer lock is not a protected root-owned file.", "Restore the private installer lock permissions before retrying.")
        return os.fdopen(fd, "w")
    except BaseException:
        os.close(fd)
        raise


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
        with open_installation_lock(args.service_name) as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail("installation_busy", "Another installation is already running.", "Wait for it to finish, then retry.")
            if args.stop_server:
                emit("check", **stop_server(args))
            else:
                install(args)
        return 0
    except InstallError as error:
        emit("error", code=error.code, message=error.message, recovery=error.recovery, **error.metadata)
    except (OSError, ValueError, argparse.ArgumentTypeError) as error:
        emit("error", code="installation_failed", message="Server preparation could not complete.",
             recovery="Check the server's permissions and available disk space, then retry.",
             details=install_exception_details(error))
    return 1


if __name__ == "__main__":
    sys.exit(main())
