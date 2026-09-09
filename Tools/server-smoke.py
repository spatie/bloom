#!/usr/bin/env python3
"""Exercise a standalone process and its stdio relay without starting a paid agent."""

import json
import pathlib
import selectors
import subprocess
import sys
import tempfile
import uuid


def read_line(stream, timeout=10):
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        if not selector.select(timeout):
            raise TimeoutError("The server did not respond")
        return stream.readline()


def check(binary):
    with tempfile.TemporaryDirectory(prefix="bloom-server-smoke-") as directory:
        server = subprocess.Popen(
            [binary, "serve", "--data-dir", directory],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        clients = []
        try:
            ready = read_line(server.stderr)
            assert "listening" in ready, ready
            for _ in range(2):
                client = subprocess.Popen(
                    [binary, "connect", "--data-dir", directory],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                clients.append(client)
                request = {"version": 7, "id": str(uuid.uuid4()), "operation": {"hello": {}}}
                client.stdin.write(json.dumps(request) + "\n")
                client.stdin.flush()
                reply = json.loads(read_line(client.stdout))
                assert reply["id"].lower() == request["id"].lower(), reply
                assert "hello" in reply["result"], reply
                client.stdin.close()
                client.wait(timeout=5)
                assert client.returncode == 0, client.stderr.read()
                assert server.poll() is None, "Client disconnect stopped the server"
            duplicate = subprocess.run(
                [binary, "serve", "--data-dir", directory], capture_output=True, text=True, timeout=5,
            )
            assert duplicate.returncode != 0 and "already owns" in duplicate.stderr, duplicate.stderr
            print("PASS: standalone server, stdio reconnects and exclusive ownership")
        finally:
            for client in clients:
                if client.poll() is None:
                    client.terminate()
                    client.wait(timeout=5)
            server.terminate()
            server.wait(timeout=10)
            assert server.returncode == 0, server.stderr.read()
            print("PASS: graceful server shutdown")


if __name__ == "__main__":
    check(str(pathlib.Path(sys.argv[1]).resolve()))
