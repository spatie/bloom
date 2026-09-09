#!/usr/bin/env python3
"""Read-only Bloom client. Python standard library; OpenSSH is needed only for --ssh-host."""
import argparse
import base64
import copy
import json
import os
import shlex
import selectors
import time
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

VERSION = 13
MAX_BYTES = 16_777_216
INCOMPATIBLE = {"failure": {"_0": "Incompatible Bloom server protocol. Update the client and server."}}
READS = {"hello", "catalogue", "transcript", "reviewSnapshot", "reviewPatch", "file"}


class BloomError(Exception):
    pass


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise BloomError("Refusing to forward a bearer credential through an HTTP redirect.")


class HTTPS:
    def __init__(self, origin, token):
        url = urllib.parse.urlsplit(origin)
        if (url.scheme != "https" or not url.hostname or url.username or url.password
                or url.query or url.fragment or url.path not in ("", "/")):
            raise BloomError("Use an HTTPS origin without a path or credentials.")
        if not token or "\n" in token or "\r" in token:
            raise BloomError("Set BLOOM_ACCESS_TOKEN to your access token.")
        self.endpoint = urllib.parse.urlunsplit(("https", url.netloc, "/v1/rpc", "", ""))
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirects())

    def exchange(self, body):
        request = urllib.request.Request(self.endpoint, data=body, method="POST", headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json", "Accept": "application/json"})
        try:
            with self.opener.open(request, timeout=660) as response:
                if response.status != 200:
                    raise BloomError(f"Unexpected gateway HTTP status {response.status}.")
                return bounded(response.read(MAX_BYTES + 1))
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise BloomError("Server access expired or was refused. Sign in again.") from error
            raise BloomError(f"Gateway HTTP {error.code}. Preserve the request ID before deciding whether to retry.") from error


class SSH:
    def __init__(self, host, user, port, executable, directory, identity=None):
        if (not host or host.startswith("-") or not user or user.startswith("-")
                or any(c.isspace() or c in "\x00/@" for c in host + user)
                or not 1 <= port <= 65535 or not executable.startswith("/") or not directory.startswith("/")
                or any(c in "\x00\r\n" for c in executable + directory)):
            raise BloomError("Enter a host, SSH user, valid port and absolute executable/data paths.")
        self.arguments = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                          "-o", "ConnectTimeout=15", "-p", str(port), "-l", user]
        if identity:
            self.arguments += ["-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-i", identity]
        self.arguments += ["--", host, shlex.join([executable, "connect", "--data-dir", directory])]

    def exchange(self, body):
        # Keep stdin open until the reply: `connect` exits when its input reaches EOF.
        # Nonblocking pipes bound both the request-write and reply-read lifetimes on POSIX.
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(self.arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            try:
                os.set_blocking(process.stdin.fileno(), False)
                os.set_blocking(process.stdout.fileno(), False)
                outgoing = memoryview(body + b"\n")
                received = bytearray()
                deadline = time.monotonic() + 660
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdin, selectors.EVENT_WRITE)
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise BloomError("SSH request timed out. Preserve its ID before retrying.")
                        for key, _ in selector.select(remaining):
                            if key.fileobj is process.stdin:
                                try:
                                    written = os.write(process.stdin.fileno(), outgoing[:65536])
                                    outgoing = outgoing[written:]
                                except BlockingIOError:
                                    continue
                                if not outgoing:
                                    selector.unregister(process.stdin)
                            else:
                                chunk = os.read(process.stdout.fileno(), 65536)
                                if not chunk:
                                    errors.seek(0)
                                    detail = errors.read(4096).decode("utf-8", errors="replace")
                                    raise BloomError("SSH closed before the reply. " + detail)
                                received.extend(chunk)
                                if len(received) > MAX_BYTES:
                                    raise BloomError("Oversized Bloom reply.")
                                if b"\n" in received:
                                    return bounded(bytes(received))
            finally:
                process.stdin.close()
                process.stdout.close()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def bounded(data):
    if not data or len(data) > MAX_BYTES:
        raise BloomError("Missing or oversized Bloom reply.")
    return data


def decode(data, command):
    reply = json.loads(data)
    if not isinstance(reply, dict) or type(reply.get("version")) is not int:
        raise BloomError("Invalid reply version.")
    try:
        matches = uuid.UUID(reply["id"]) == uuid.UUID(command["id"])
    except (KeyError, ValueError, TypeError) as error:
        raise BloomError("Invalid reply ID.") from error
    if not matches:
        raise BloomError("Reply belongs to another request. Reconnect before retrying.")
    result = reply.get("result")
    if not isinstance(result, dict) or len(result) != 1:
        raise BloomError("Invalid result envelope.")
    return reply


class Client:
    def __init__(self, transport):
        self.transport = transport
        self.version = None

    def _exchange(self, command):
        body = json.dumps(command, separators=(",", ":")).encode()
        if len(body) > MAX_BYTES:
            raise BloomError("Request exceeds 16 MiB.")
        return decode(self.transport.exchange(body), command)

    def connect(self):
        hello = {"version": VERSION, "id": str(uuid.uuid4()), "operation": {"hello": {}}}
        reply = self._exchange(hello)
        if reply["version"] == 12 and reply["result"] == INCOMPATIBLE:
            hello["version"] = 12
            reply = self._exchange(hello)
        if reply["version"] != hello["version"] or not isinstance(reply["result"].get("hello", {}).get("name"), str):
            raise BloomError("Endpoint did not identify a supported Bloom server.")
        self.version = reply["version"]
        return reply["result"]

    def command(self, name, arguments):
        if name not in READS:
            raise BloomError("This example intentionally exposes read-only operations.")
        if self.version is None:
            self.connect()
        return {"version": self.version, "id": str(uuid.uuid4()), "operation": {name: copy.deepcopy(arguments)}}

    def perform(self, command):
        if command["version"] != self.version or len(command["operation"]) != 1 or next(iter(command["operation"])) not in READS:
            raise BloomError("Use a negotiated, unchanged read-only command.")
        # No automatic retry. The caller can reuse this exact command after a transport failure.
        reply = self._exchange(command)
        if reply["version"] != self.version:
            raise BloomError("Protocol changed. Reconnect before sending another request.")
        if "failure" in reply["result"]:
            raise BloomError(reply["result"]["failure"]["_0"])
        return reply["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument("--https", metavar="ORIGIN")
    transport.add_argument("--ssh-host")
    parser.add_argument("--ssh-user", default="bloom")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--identity", help="OpenSSH private-key file; host trust still uses known_hosts")
    parser.add_argument("--executable", default="/opt/bloom-server/current/bin/bloom-server")
    parser.add_argument("--data-directory", default="/var/lib/bloom")
    parser.add_argument("operation", choices=sorted(READS))
    parser.add_argument("--session")
    parser.add_argument("--workspace")
    parser.add_argument("--path")
    parser.add_argument("--after", type=int, default=0)
    parser.add_argument("--scope", choices=["branch", "uncommitted"], default="branch")
    parser.add_argument("--known-revision")
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--decode-payloads", action="store_true")
    args = parser.parse_args()
    if args.operation == "transcript" and not args.session:
        parser.error("transcript requires --session")
    if args.operation in ("reviewSnapshot", "reviewPatch", "file") and not args.workspace:
        parser.error("this operation requires --workspace")
    if args.operation in ("reviewPatch", "file") and not args.path:
        parser.error("this operation requires --path")
    link = HTTPS(args.https, os.environ.get("BLOOM_ACCESS_TOKEN")) if args.https else SSH(
        args.ssh_host, args.ssh_user, args.ssh_port, args.executable, args.data_directory, args.identity)
    client = Client(link)
    hello = client.connect()
    arguments = {}
    if args.operation == "transcript":
        arguments = {"sessionID": args.session, "afterSeq": args.after}
    elif args.operation in ("reviewSnapshot", "reviewPatch", "file"):
        arguments = {"workspaceID": args.workspace}
        if args.operation != "file":
            arguments.update(scope=args.scope, knownRevision=args.known_revision)
        if args.operation == "reviewSnapshot":
            arguments["wait"] = args.wait
        else:
            arguments["path"] = args.path
    result = hello if args.operation == "hello" else client.perform(client.command(args.operation, arguments))
    if args.decode_payloads and "transcript" in result:
        for message in result["transcript"]["_0"]["messages"]:
            data = base64.b64decode(message["payload"], validate=True)
            try:
                message["decodedPayload"] = json.loads(data)
            except (ValueError, UnicodeDecodeError):
                message["decodedPayload"] = data.decode("utf-8", errors="replace")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (BloomError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
