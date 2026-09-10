"""Bounded subprocess output shared by the standalone, embedded Bloom installers."""
import collections
import os
import pathlib
import re
import selectors
import signal
import subprocess
import threading
import time
import urllib.parse


class InstallProcessFailure(Exception):
    def __init__(self, code, command, exit_status, details):
        super().__init__(command)
        self.code, self.command = code, command
        self.exit_status, self.details = exit_status, details


class InstallProcessCancelled(Exception):
    pass


class InstallOutputRedactor:
    def __init__(self):
        self.private_key = False

    @staticmethod
    def safe_url(match):
        try:
            value = urllib.parse.urlsplit(match.group(0))
            host = value.hostname
            if not host:
                return "[URL redacted]"
            if ":" in host:
                host = "[" + host + "]"
            if value.port is not None:
                host += ":" + str(value.port)
            return urllib.parse.urlunsplit((value.scheme, host, value.path, "", ""))
        except ValueError:
            return "[URL redacted]"

    def redact(self, text):
        text = re.sub(r"\x1b\][^\x07]*(?:\x07|\x1b\\)", "", text)
        text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
        text = "".join(c for c in text if c == "\t" or ord(c) >= 32)
        if re.search(r"-----BEGIN .*PRIVATE KEY-----", text):
            self.private_key = True
        if self.private_key:
            if re.search(r"-----END .*PRIVATE KEY-----", text):
                self.private_key = False
            return "[private key redacted]"
        if re.search(r"\b(?:ssh-(?:rsa|ed25519)|ecdsa-sha2-\S+)\s+[A-Za-z0-9+/=]+", text):
            return "[SSH key redacted]"
        text = re.sub(r"(?i)\b(?:https?|ssh|ftp)://[^\s<>\"']+", self.safe_url, text)
        text = re.sub(r"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie|[\w-]*(?:token|password|passwd|secret|credential|api[_-]?key)[\w-]*)\b[\"\']?\s*(?:[=:]\s*|\s+).*", "[credential redacted]", text)
        text = re.sub(r"(?i)\b(?:bearer|basic)\s+\S+", "[credential redacted]", text)
        text = re.sub(r"\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+", "[token redacted]", text)
        text = re.sub(r"\b[A-Za-z0-9_+/=-]{40,}\b", "[long value redacted]", text)
        return text[:3000]


def install_command_label(arguments):
    # Include exact package/service arguments only for maintained commands. Never show Python
    # -c scripts, public keys, browser payloads or arbitrary authentication arguments.
    name = pathlib.Path(str(arguments[0])).name
    verbs = {"apt-get": {"update", "install"}, "systemctl": {"show", "start", "stop", "enable", "disable", "daemon-reload", "is-active"},
             "node": {"--version"}, "nodejs": {"--version"}, "npm": {"--version"}, "git": {"--version"}}
    verb = str(arguments[1]) if len(arguments) > 1 else ""
    if verb not in verbs.get(name, set()):
        return name
    safe = [name, verb]
    for argument in map(str, arguments[2:]):
        allowed = False
        if name == "apt-get":
            allowed = argument in {"-y", "-qq", "--simulate", "--no-remove", "--no-install-recommends"} or bool(re.fullmatch(r"[a-z0-9][a-z0-9+.-]*(?::[a-z0-9]+)?", argument))
        elif name == "systemctl":
            allowed = argument in {"--value", "--quiet", "--property=ActiveState"} or bool(re.fullmatch(r"[A-Za-z0-9_@.+-]+\.service", argument))
        safe.append(argument if allowed else "[argument omitted]")
    return " ".join(safe)[:2000]


def stream_install_command(arguments, *, timeout, output=None, live=True, capture_limit=1048576,
                           detail_limit=8192, event_limit=500, **options):
    """Drain both pipes without threads; cancellation and timeout terminate our whole process group."""
    label = install_command_label(arguments)
    try:
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True, **options)
    except OSError as error:
        raise InstallProcessFailure("command_failed", label, None, "The command could not start: " + str(error.strerror)) from None
    selector = selectors.DefaultSelector()
    streams = {}
    raw = bytearray()
    tail = collections.deque()
    tail_size = 0
    emitted = 0
    last_output_at = 0.0
    pending_output = None
    reduction_announced = False
    previous_handlers = {}
    deadline = time.monotonic() + timeout

    def terminate():
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        # The leader can exit while descendants keep running or hold our pipes open.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    def cancelled(_signum, _frame):
        raise InstallProcessCancelled()

    def publish(line, force=False):
        nonlocal emitted, last_output_at, pending_output, reduction_announced
        if not live or not output:
            return
        now = time.monotonic()
        if emitted < event_limit or force or now - last_output_at >= 0.1:
            if emitted >= event_limit and not reduction_announced:
                output("High output volume; showing the latest progress updates.")
                reduction_announced = True
            output(line)
            emitted += 1
            last_output_at = now
            pending_output = None
        else:
            pending_output = line

    def record(state, value):
        nonlocal tail_size
        line = state["redactor"].redact(value.decode("utf-8", errors="replace")).strip()
        if not line:
            return
        tail.append(line)
        tail_size += len(line) + 1
        while tail and tail_size > detail_limit:
            tail_size -= len(tail.popleft()) + 1
        publish(line)

    def drain(state, chunk, final=False):
        # Oversized lines are discarded as a whole. Splitting one could expose the suffix of a
        # credential or a private key whose marker was in an earlier chunk.
        for part in re.split(b"(\n|\r)", chunk):
            if part in (b"\n", b"\r"):
                if not state["discard"]:
                    record(state, bytes(state["pending"]))
                state["pending"].clear()
                state["discard"] = False
            elif not state["discard"]:
                state["pending"].extend(part)
                if len(state["pending"]) > 8192:
                    if re.search(b"-----BEGIN .*PRIVATE KEY-----", state["pending"]):
                        state["redactor"].private_key = True
                    record(state, b"[oversized output line omitted]")
                    state["pending"].clear()
                    state["discard"] = True
        if final and state["pending"] and not state["discard"]:
            record(state, bytes(state["pending"]))

    try:
        if threading.current_thread() is threading.main_thread():
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                previous_handlers[signum] = signal.signal(signum, cancelled)
        for pipe in (process.stdout, process.stderr):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ)
            streams[pipe] = {"pending": bytearray(), "discard": False, "redactor": InstallOutputRedactor()}
        while selector.get_map():
            if pending_output is not None:
                publish(pending_output)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise InstallProcessFailure("command_timeout", label, None, "\n".join(tail))
            for key, _mask in selector.select(min(remaining, 0.2)):
                try:
                    chunk = os.read(key.fd, 16384)
                except BlockingIOError:
                    continue
                state = streams[key.fileobj]
                if not chunk:
                    drain(state, b"", final=True)
                    selector.unregister(key.fileobj)
                    continue
                if key.fileobj is process.stdout and len(raw) < capture_limit:
                    raw.extend(chunk[:capture_limit - len(raw)])
                drain(state, chunk)
        if pending_output is not None:
            publish(pending_output, force=True)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise InstallProcessFailure("command_timeout", label, None, "\n".join(tail))
        try:
            status = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            raise InstallProcessFailure("command_timeout", label, None, "\n".join(tail)) from None
        result = subprocess.CompletedProcess(arguments, status, stdout=bytes(raw), stderr=b"")
        result.details = "\n".join(tail)
        result.command = label
        return result
    except InstallProcessCancelled:
        raise InstallProcessFailure("cancelled", label, None, "\n".join(tail)) from None
    except OSError as error:
        raise InstallProcessFailure("command_failed", label, process.poll(),
                                    "\n".join(tail) + "\nOutput could not be read: " + str(error.strerror)) from None
    finally:
        terminate()
        selector.close()
        process.stdout.close()
        process.stderr.close()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def standalone_installer_source(path, source=None):
    source = pathlib.Path(path).read_text() if source is None else source
    if "class InstallProcessFailure(" in source:
        return source
    helper = pathlib.Path(path).with_name("bloom_install_process.py").read_text()
    return "#!/usr/bin/env python3\n" + helper + "\n" + source


def redact_install_text(value, limit=8192):
    redactor = InstallOutputRedactor()
    lines = [redactor.redact(line) for line in str(value)[:1048576].splitlines()]
    return "\n".join(lines)[-limit:]


def install_exception_details(error):
    # subprocess exceptions include repr(argv), which can contain inline Python or credentials.
    if isinstance(error, subprocess.TimeoutExpired):
        detail = f"{install_command_label(error.cmd)} exceeded {error.timeout} seconds"
    elif isinstance(error, subprocess.CalledProcessError):
        detail = f"{install_command_label(error.cmd)} exited with status {error.returncode}"
    else:
        detail = str(error)
    return redact_install_text(type(error).__name__ + ": " + detail)
