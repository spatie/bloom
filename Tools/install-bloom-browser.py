#!/usr/bin/env python3
"""Optional, pinned host browser tooling. Does not modify or restart Bloom Server.

Install: --user bloom --service-home /var/lib/bloom-home
Read-only readiness: --check (last sandbox smoke, not a live browser launch).
A nonzero exit means only browser testing is unavailable. Core setup may continue.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile

if "stream_install_command" not in globals():
    from bloom_install_process import InstallProcessFailure, install_exception_details, redact_install_text, standalone_installer_source, stream_install_command

CURRENT_STEP = None

AGENT_VERSION = "0.37.1"
CHROME_VERSION = "153.0.8010.36"
ROOT = Path("/opt/bloom-browser")
CHROME_EXECUTABLE_HASHES = {
    "x86_64": "79a4ebf6da53e4ceab11844257aabc5166f17b595dc694d6382cbee8ff50565f",
    "aarch64": "78f540d00badb8ffb5f017adacd8fb786522c572808fd1cd54965b42334c66ae",
}
# Release checksums from GitHub's asset digest; CfT archives downloaded from Google's
# versioned endpoint and hashed 2026-09-10. Both upstream URLs are recorded in manifest.
PINS = {
    "x86_64": ("x64", "linux64", "f8e5f9294bd0da70dda61854f12004fd61c668cd682bfb600cdf6d0df73dea69",
               "167a098c4fdec156b58a9f678c90a84f9072d789f9c6e7b35496a6987b8b7ef8"),
    "aarch64": ("arm64", "linux-arm64", "d54d3e1262dc1aa0906e0677adc6d0cbb40d1274631f4cf77136bf23a0bc20e9",
                "dfc4955719c5d494c8507990506d2d5bed174c31bf89266aa2dc5593c6607e8b"),
}


class BrowserError(Exception):
    def __init__(self, code, message, recovery, **metadata):
        super().__init__(message)
        self.code, self.recovery = code, recovery
        self.metadata = metadata


def fail(code, message, recovery, **metadata):
    raise BrowserError(code, redact_install_text(message), redact_install_text(recovery),
        **{key: redact_install_text(value) if isinstance(value, str) else value for key, value in metadata.items()})


def emit(event, **fields):
    global CURRENT_STEP
    if event == "progress" and fields.get("step"):
        CURRENT_STEP = fields["step"]
    print(json.dumps(dict(event=event, **fields)), flush=True)


def container_environment():
    if Path("/.dockerenv").exists() or Path("/run/.containerenv").exists():
        return True
    try:
        return any(word in Path("/proc/1/cgroup").read_text() for word in ("docker", "kubepods", "lxc"))
    except OSError:
        return False


def protected(path):
    """Every existing ancestor must be root-owned, not writable by other accounts."""
    for item in [path, *path.parents]:
        if not item.exists() and not item.is_symlink():
            continue
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            fail("unsafe_path", f"Unsafe browser installation path: {item}", "Use root-owned paths without symlinks or group/world write access.")


def command(args, *, account=None, env=None, timeout=300, cwd=None):
    options = {}
    if account:
        options.update(user=account.pw_uid, group=account.pw_gid, extra_groups=[])
    # Machine-readable browser smoke responses are parsed privately, never copied to the log.
    live = Path(args[0]).name in ("apt-get", "apparmor_parser")
    try:
        result = stream_install_command(args, timeout=timeout, live=live, cwd=cwd,
            output=lambda line: emit("output", message=line, step=CURRENT_STEP),
            env=env or {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8", "DEBIAN_FRONTEND": "noninteractive"}, **options)
    except InstallProcessFailure as error:
        fail(error.code, f"{error.command} " + ("timed out." if error.code == "command_timeout" else "could not complete."),
             "Review browser setup output, check the server's package manager and network, then retry. Bloom Server remains available.",
             command=error.command, exitStatus=error.exit_status, details=error.details)
    if result.returncode:
        fail("command_failed", f"{result.command} exited with status {result.returncode}.",
             "Review browser setup output and resolve the reported problem, then retry. Bloom Server remains available.",
             command=result.command, exitStatus=result.returncode, details=result.details)
    return result.stdout.decode("utf-8", errors="replace")


def download(url, destination, expected):
    digest, count = hashlib.sha256(), 0
    reported = 0
    request = urllib.request.Request(url, headers={"User-Agent": "Bloom-Browser-Installer/1"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("xb") as target:
        if not response.url.startswith("https://"):
            fail("insecure_download", "Browser download redirected away from HTTPS.", "Retry from a trusted network.")
        while chunk := response.read(1024 * 1024):
            count += len(chunk)
            if count > 400 * 1024 * 1024:
                fail("download_too_large", "Browser download exceeded its size limit.", "Check the pinned release.")
            target.write(chunk)
            digest.update(chunk)
            if count - reported >= 16 * 1024 * 1024:
                reported = count
                emit("output", message=f"Downloaded {count // (1024 * 1024)} MiB of browser files", step=CURRENT_STEP)
    if digest.hexdigest() != expected:
        fail("checksum_mismatch", "Browser release checksum did not match the pinned version.", "Do not execute this download. Retry or update the reviewed release pins.")


def extract_chrome(archive, destination):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > 10000 or sum(item.file_size for item in entries) > 1024 * 1024 * 1024:
            fail("unsafe_archive", "Browser archive exceeds extraction limits.", "Check the pinned archive.")
        for item in entries:
            relative = Path(item.filename)
            mode = item.external_attr >> 16
            if relative.is_absolute() or ".." in relative.parts or stat.S_ISLNK(mode) or "\\" in item.filename:
                fail("unsafe_archive", "Browser archive contains an unsafe path.", "Check the pinned archive.")
        for item in entries:
            target = destination / item.filename
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True, mode=0o755)
                target.chmod(0o755)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                ancestor = target.parent
                while ancestor != destination:
                    ancestor.chmod(0o755)
                    ancestor = ancestor.parent
                with source.open(item) as reader, target.open("xb") as writer:
                    shutil.copyfileobj(reader, writer)
                # Never install a setuid sandbox helper. Chrome uses unprivileged user namespaces.
                target.chmod(0o755 if (item.external_attr >> 16) & 0o111 else 0o644)


def atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    with temporary.open("x") as target:
        target.write(json.dumps(value, indent=2) + "\n")
    temporary.chmod(0o644)
    temporary.replace(path)


def dependencies():
    command(["apt-get", "update"], timeout=600)
    fixed = "libxcb-shm0 libx11-xcb1 libx11-6 libxcb1 libxext6 libxrandr2 libxcomposite1 libxcursor1 libxdamage1 libxfixes3 libxi6 libxrender1 libfreetype6 libfontconfig1 libnss3 libnspr4 libdrm2 libxkbcommon0 libxshmfence1 libgbm1 fonts-liberation fonts-noto-color-emoji".split()
    variants = "libgtk-3-0 libpangocairo-1.0-0 libpango-1.0-0 libatk1.0-0 libcairo-gobject2 libcairo2 libgdk-pixbuf-2.0-0 libasound2 libdbus-1-3 libatk-bridge2.0-0 libatspi2.0-0 libcups2".split()
    for name in variants:
        for candidate in [name + "t64", name]:
            check = subprocess.run(["apt-cache", "show", candidate], capture_output=True, text=True)
            if check.returncode == 0 and "Package: " in check.stdout:
                fixed.append(candidate)
                break
        else:
            fail("missing_dependency", f"No supported package for {name}.", "Use Ubuntu 24.04 or 26.04 with standard repositories enabled.")
    command(["apt-get", "install", "--simulate", "--no-remove", "--no-install-recommends", *fixed])
    command(["apt-get", "install", "-y", "--no-remove", "--no-install-recommends", *fixed], timeout=900)


def apparmor(chrome):
    restriction = Path("/proc/sys/kernel/apparmor_restrict_unprivileged_userns")
    if not restriction.exists() or restriction.read_text().strip() != "1":
        return "not_required"
    if not shutil.which("apparmor_parser"):
        fail("apparmor_missing", "AppArmor restricts browser namespaces, but its parser is missing.", "Install apparmor, then retry browser setup.")
    path = Path("/etc/apparmor.d/bloom-browser")
    protected(path)
    text = f'# Bloom managed browser user namespaces\nabi <abi/4.0>,\ninclude <tunables/global>\nprofile bloom-browser "{chrome}" flags=(unconfined) {{\n  userns,\n}}\n'
    if path.exists() and not path.read_text().startswith("# Bloom managed browser user namespaces\n"):
        fail("apparmor_conflict", "An unrelated bloom-browser AppArmor profile already exists.", "Review that profile before retrying.")
    path.write_text(text)
    path.chmod(0o644)
    command(["apparmor_parser", "-r", str(path)])
    return "scoped_user_namespace_profile"


def checked_runtime_config():
    root = Path(__file__).resolve().parent.parent
    protected(Path(__file__).resolve())
    config_path = root / "configuration.json"
    protected(config_path)
    config = json.loads(config_path.read_text())
    for key in ("chrome", "agentBrowser", "emptyConfig", "chromeGuard"):
        protected(Path(config[key]))
    if os.geteuid() == 0 or os.geteuid() != config["uid"]:
        fail("wrong_user", "Run browser testing as the configured Bloom service user, never root.", f"Use the {config['user']} account.")
    if container_environment():
        fail("container_unsupported", "This browser installation supports host processes only.", "Use a reviewed non-root browser image with sandbox support for Docker workspaces.")
    return config


def private_directory(path):
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            fail("unsafe_profile", f"Browser state is not a private directory: {path}", "Restore service-user ownership and mode 0700, then retry.")
    else:
        path.mkdir(mode=0o700)


def chrome_arguments(arguments):
    unsafe = {"--no-sandbox", "--disable-setuid-sandbox", "--disable-namespace-sandbox", "--disable-seccomp-filter-sandbox",
              "--disable-gpu-sandbox", "--single-process", "--no-zygote", "--in-process-gpu"}
    for argument in arguments:
        flag = argument.split("=", 1)[0]
        if flag in unsafe or (flag == "--remote-debugging-address" and argument != "--remote-debugging-address=127.0.0.1"):
            fail("unsafe_browser_flags", f"Refusing unsafe Chrome option: {flag}", "Run on a non-root Ubuntu host with user namespaces enabled. Do not disable the sandbox.")
        if flag == "--remote-debugging-port" and argument != "--remote-debugging-port=0":
            fail("unsafe_browser_flags", "Chrome debugging must use an ephemeral loopback port.", "Remove custom debugging port options.")
    return [*arguments, "--remote-debugging-address=127.0.0.1"]


def runtime():
    config = checked_runtime_config()
    args = sys.argv[1:]
    if Path(sys.argv[0]).name == "bloom-chrome":
        args = chrome_arguments(args)
        os.execv(config["chrome"], [config["chrome"], *args])
    forbidden = {"--config", "--profile", "--session", "--namespace", "--executable-path", "--args", "--cdp", "--auto-connect", "--provider", "-p", "--engine", "--stream-port", "--extension", "--extensions"}
    if any(arg.split("=", 1)[0] in forbidden for arg in args) or ("connect" in args):
        fail("managed_browser_options", "Bloom manages the browser profile, session, executable and local connection.", "Use ordinary agent-browser commands inside the workspace without connection overrides.")
    # Isolates accidental state mixing, not a security boundary against shell-capable agents
    # sharing the same Unix account. Explicit config avoids untrusted repository auto-config.
    workspace = os.environ.get("BLOOM_WORKSPACE_ID") or os.environ.get("BLOOM_WORKSPACE_PATH") or str(Path.cwd().resolve())
    key = hashlib.sha256(workspace.encode()).hexdigest()[:24]
    home = Path(config["serviceHome"])
    state = home / ".bloom-browser"
    private_directory(state)
    private_directory(state / "workspaces")
    base = state / "workspaces" / key
    private_directory(base)
    private_directory(base / "profile")
    private_directory(base / "run")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_BROWSER_") and key != "CI"}
    environment.update(HOME=str(home), AGENT_BROWSER_SOCKET_DIR=str(base / "run"), AGENT_BROWSER_IDLE_TIMEOUT_MS="120000")
    binary = config["agentBrowser"]
    managed = ["--config", config["emptyConfig"], "--session", "bloom", "--profile", str(base / "profile"),
               "--executable-path", config["chromeGuard"], "--content-boundaries", "--max-output", "50000"]
    os.execve(binary, [binary, *managed, *args], environment)


def sandbox_status(text):
    # Chrome's own status page reports renderer sandbox capabilities. A successful
    # screenshot or absence of --no-sandbox alone is insufficient evidence.
    return {"namespace": bool(re.search(r"Layer 1 Sandbox\s+Namespace", text, re.I)),
            "pidNamespace": bool(re.search(r"PID namespaces\s+Yes", text, re.I)),
            "networkNamespace": bool(re.search(r"Network namespaces\s+Yes", text, re.I)),
            "seccomp": bool(re.search(r"Seccomp-BPF sandbox\s+Yes", text, re.I))}


def loopback_evidence(profile):
    port = int((profile / "DevToolsActivePort").read_text().splitlines()[0])
    if not 0 < port < 65536:
        fail("debugging_unverified", "Chrome reported an invalid debugging port.", "Retry browser setup.")
    listeners = []
    for table in ("tcp", "tcp6"):
        path = Path("/proc/net") / table
        if not path.exists():
            continue
        for line in path.read_text().splitlines()[1:]:
            fields = line.split()
            address, local_port = fields[1].split(":")
            if int(local_port, 16) == port and fields[3] == "0A":
                listeners.append(address)
    if not listeners or any(address not in ("0100007F", "00000000000000000000000001000000") for address in listeners):
        fail("debugging_not_private", "Chrome debugging listener is not exclusively loopback.", "Remove public CDP configuration and retry browser setup.")
    return {"port": port, "loopbackOnly": True}


def process_evidence(chrome, uid, profile, proc_root=Path("/proc")):
    processes = []
    for directory in proc_root.iterdir():
        if not directory.name.isdigit():
            continue
        try:
            if directory.stat().st_uid != uid:
                continue
            if os.readlink(directory / "exe") != chrome:
                continue
            arguments = [part for part in (directory / "cmdline").read_bytes().decode().split("\0") if part]
            # Chrome rewrites renderer process titles into one space-separated argv entry.
            # The kernel executable link above establishes identity, not that mutable title.
            if len(arguments) == 1 and arguments[0].startswith(chrome + " "):
                arguments = [chrome, *arguments[0][len(chrome) + 1:].split()]
            if not arguments or arguments[0] != chrome or f"--user-data-dir={profile}" not in arguments:
                continue
            chrome_arguments(arguments[1:])
            status = (directory / "status").read_text()
            processes.append({"pid": int(directory.name), "renderer": "--type=renderer" in arguments,
                              "seccomp": bool(re.search(r"^Seccomp:\s+2$", status, re.M)),
                              "noNewPrivileges": bool(re.search(r"^NoNewPrivs:\s+1$", status, re.M)),
                              "arguments": arguments})
        except (OSError, UnicodeError):
            continue
    if not processes or not any(item["renderer"] and item["seccomp"] and item["noNewPrivileges"] for item in processes):
        fail("sandbox_unverified", "Chrome renderer sandbox could not be verified from /proc.", "Check kernel namespace and seccomp support, then retry. Sandbox bypasses are not supported.")
    return processes


def smoke(config, account):
    environment = {"PATH": "/usr/bin:/bin", "HOME": config["serviceHome"], "LANG": "C.UTF-8",
                   "BLOOM_WORKSPACE_ID": "bloom-browser-smoke-" + uuid.uuid4().hex}
    def invoke(*args):
        raw = command([str(ROOT / "bin/agent-browser"), "--json", *args], account=account,
                      env=environment, cwd=config["serviceHome"], timeout=90)
        try:
            value = json.loads(raw)
        except ValueError:
            fail("invalid_browser_response", "Browser smoke returned an invalid response.", "Review the pinned agent-browser release and retry.")
        if not value.get("success"):
            fail("browser_smoke_failed", str(value.get("error", "Browser smoke failed"))[:2000], "Review sandbox and dependency diagnostics, then retry.")
        return value.get("data", {})
    state = Path(config["serviceHome"]) / ".bloom-browser"
    screenshot = state / "smoke.png"
    try:
        invoke("open", "chrome://sandbox")
        result = invoke("eval", "document.body.innerText")
        status = sandbox_status(str(result.get("result", "")))
        if not all(status.values()):
            fail("sandbox_disabled", "Chrome does not report both namespace and seccomp sandbox protection.", "Check the scoped AppArmor profile and kernel user namespaces. Do not use --no-sandbox.")
        profile_key = hashlib.sha256(environment["BLOOM_WORKSPACE_ID"].encode()).hexdigest()[:24]
        profile = state / "workspaces" / profile_key / "profile"
        processes = process_evidence(config["chrome"], account.pw_uid, profile)
        debugging = loopback_evidence(profile)
        invoke("open", "data:text/html,<html><title>Bloom browser ready</title><body style='font:24px sans-serif;padding:48px'><h1>Bloom browser ready</h1><p>Sandboxed Chrome rendered this page on your server.</p></body></html>")
        invoke("screenshot", str(screenshot))
        with screenshot.open("rb") as image:
            signature = image.read(8)
        if signature != b"\x89PNG\r\n\x1a\n":
            fail("screenshot_missing", "Browser did not produce a valid PNG.", "Retry the browser smoke test.")
        return dict(sandbox=status, debugging=debugging, processes=processes, screenshot=str(screenshot), verifiedAt=int(time.time()))
    finally:
        try:
            invoke("close")
        except (BrowserError, subprocess.TimeoutExpired):
            pass


def launcher_source():
    # The wizard compiles stdin with __bloom_browser_source and deliberately has no file.
    # Avoid even evaluating __file__ on that path; copied launchers already include the helper.
    source = globals().get("__bloom_browser_source")
    if source is not None:
        return source
    return standalone_installer_source(__file__)


def install(options):
    if platform.system() != "Linux" or platform.machine() not in PINS:
        fail("unsupported_platform", "Browser provisioning requires Ubuntu Linux x64 or arm64.", "Use a supported Ubuntu server.")
    if os.geteuid() != 0:
        fail("root_required", "Installing browser dependencies requires root.", "Run this optional installer using sudo.")
    if container_environment():
        fail("container_unsupported", "Host browser provisioning is unavailable inside containers.", "Provision the Ubuntu host. Docker workspace browsers need a separately reviewed image with working sandbox support.")
    release_info = dict(line.strip().split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release_info.get("ID", "").strip('"') != "ubuntu" or release_info.get("VERSION_ID", "").strip('"') not in ("24.04", "26.04"):
        fail("unsupported_distribution", "Browser dependencies are tested for Ubuntu 24.04 and 26.04.", "Install on a supported Ubuntu host.")
    account = pwd.getpwnam(options.user)
    home = Path(options.service_home)
    if account.pw_uid == 0 or not home.is_absolute() or home.is_symlink() or not home.is_dir() or home.stat().st_uid != account.pw_uid:
        fail("invalid_service_user", "Browser testing needs a non-root service user with its own home directory.", "Complete Bloom Server setup first and pass its user and service home.")
    protected(ROOT)
    marker = ROOT / "configuration.json"
    protected(marker)
    if marker.exists():
        previous = json.loads(marker.read_text())
        if previous.get("uid") != account.pw_uid or previous.get("serviceHome") != str(home):
            fail("different_service_user", "Browser tools are already configured for another service account.",
                 "Keep the existing browser installation with its Bloom Server account. A separate account needs its own browser installation prefix.")
    protected(ROOT / "readiness.json")
    (ROOT / "readiness.json").unlink(missing_ok=True)
    emit("progress", step="browser_dependencies", message="Installing optional Chrome system libraries")
    dependencies()
    arch, chrome_arch, agent_hash, chrome_hash = PINS[platform.machine()]
    release = ROOT / "releases" / f"{AGENT_VERSION}-{CHROME_VERSION}-{arch}"
    agent_url = f"https://github.com/vercel-labs/agent-browser/releases/download/v{AGENT_VERSION}/agent-browser-linux-{arch}"
    chrome_url = f"https://storage.googleapis.com/chrome-for-testing-public/{CHROME_VERSION}/{chrome_arch}/chrome-{chrome_arch}.zip"
    protected(release.parent)
    release.parent.mkdir(exist_ok=True, mode=0o755)
    release.parent.chmod(0o755)
    protected(release)
    if not release.exists():
        emit("progress", step="browser_download", message="Downloading verified browser releases")
        with tempfile.TemporaryDirectory(prefix=".download-", dir=ROOT) as temporary:
            staging = Path(temporary)
            download(agent_url, staging / "agent-browser", agent_hash)
            download(chrome_url, staging / "chrome.zip", chrome_hash)
            extract_chrome(staging / "chrome.zip", staging)
            (staging / "chrome.zip").unlink()
            (staging / "agent-browser").chmod(0o755)
            staging.chmod(0o755)
            staging.rename(release)
    chrome = release / f"chrome-{chrome_arch}" / "chrome"
    for executable, checksum in [(release / "agent-browser", agent_hash), (chrome, CHROME_EXECUTABLE_HASHES[platform.machine()])]:
        protected(executable)
        with executable.open("rb") as binary:
            if hashlib.file_digest(binary, "sha256").hexdigest() != checksum:
                fail("checksum_mismatch", "Installed browser executable does not match the reviewed release.", "Review or remove the damaged browser release, then retry browser setup.")
    policy = apparmor(chrome)
    binary_dir = ROOT / "bin"
    protected(binary_dir)
    binary_dir.mkdir(exist_ok=True, mode=0o755)
    binary_dir.chmod(0o755)
    for name in ("agent-browser", "bloom-chrome"):
        path = binary_dir / name
        protected(path)
        path.write_text(launcher_source())
        path.chmod(0o755)
    empty = ROOT / "empty-config.json"
    protected(empty)
    atomic_json(empty, {})
    config = dict(user=options.user, uid=account.pw_uid, serviceHome=str(home), chrome=str(chrome),
                  chromeGuard=str(binary_dir / "bloom-chrome"), agentBrowser=str(release / "agent-browser"), emptyConfig=str(empty),
                  agentVersion=AGENT_VERSION, chromeVersion=CHROME_VERSION, agentURL=agent_url, chromeURL=chrome_url,
                  agentSHA256=agent_hash, chromeSHA256=chrome_hash, chromeExecutableSHA256=CHROME_EXECUTABLE_HASHES[platform.machine()], apparmor=policy, hostOnly=True)
    atomic_json(marker, config)
    emit("progress", step="browser_smoke", message="Verifying Chrome sandbox and rendering a test page")
    evidence = smoke(config, account)
    readiness = dict(ready=True, **config, **evidence, executable=str(binary_dir / "agent-browser"),
                     containerSupport=False, concurrencyGuidance="Keep one workspace browser open at a time on small servers; run agent-browser close when finished.")
    atomic_json(ROOT / "readiness.json", readiness)
    return readiness


def main():
    if Path(sys.argv[0]).name in ("agent-browser", "bloom-chrome"):
        runtime()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="bloom")
    parser.add_argument("--service-home", default="/var/lib/bloom-home")
    parser.add_argument("--check", action="store_true", help="Read the last successful sandbox verification without starting a browser")
    options = parser.parse_args()
    if options.check:
        protected(ROOT / "readiness.json")
        if not (ROOT / "readiness.json").is_file():
            fail("not_installed", "Browser testing has not completed setup.", "Run optional browser setup on the server.")
        result = json.loads((ROOT / "readiness.json").read_text())
        config = json.loads((ROOT / "configuration.json").read_text())
        if any(config.get(key) != result.get(key) for key in ("uid", "chrome", "agentBrowser", "agentVersion", "chromeVersion")):
            fail("stale_readiness", "Browser configuration changed since sandbox verification.", "Run browser setup again to verify the current installation.")
        for key, checksum_key in (("agentBrowser", "agentSHA256"), ("chrome", "chromeExecutableSHA256")):
            executable = Path(result[key])
            protected(executable)
            with executable.open("rb") as binary:
                if hashlib.file_digest(binary, "sha256").hexdigest() != result[checksum_key]:
                    fail("checksum_mismatch", "Installed browser executable changed since verification.", "Repair the protected browser installation, then retry setup.")
        result["liveCheck"] = False
    else:
        if os.geteuid() != 0:
            fail("root_required", "Installing browser dependencies requires root.", "Run this optional installer using sudo.")
        protected(ROOT)
        ROOT.mkdir(mode=0o755, exist_ok=True)
        ROOT.chmod(0o755)
        owner = ROOT / ".bloom-managed"
        protected(owner)
        if not owner.exists():
            if any(ROOT.iterdir()):
                fail("unmanaged_installation", "The browser installation directory contains unmanaged files.", "Review /opt/bloom-browser before retrying.")
            owner.write_text("Bloom optional browser installer v1\n")
            owner.chmod(0o644)
        elif owner.read_text() != "Bloom optional browser installer v1\n":
            fail("unmanaged_installation", "Browser installation ownership could not be verified.", "Review /opt/bloom-browser before retrying.")
        lock_path = ROOT / ".install.lock"
        protected(lock_path)
        # O_NOFOLLOW stops a pre-existing symlink from redirecting root's lock file.
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = install(options)
    emit("complete", **result)


def entrypoint():
    try:
        main()
        return 0
    except BrowserError as error:
        emit("error", ready=False, code=error.code, message=str(error), recovery=error.recovery, **error.metadata)
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, zipfile.BadZipFile) as error:
        emit("error", ready=False, code="browser_setup_failed", message="Optional browser setup could not complete.",
             recovery="Review the diagnostic below and retry optional browser setup. Bloom Server remains available.",
             details=install_exception_details(error))
    return 1


if __name__ == "__main__":
    sys.exit(entrypoint())
