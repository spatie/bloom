#!/usr/bin/env python3
"""Deterministic agent protocol fixture. No network access or model calls."""

import json
import pathlib
import sys
import uuid


def emit(message):
    print(json.dumps(message), flush=True)


def finish():
    emit({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1,
          "duration_api_ms": 1, "duration_ms": 1, "result": "Fixture completed", "session_id": "fixture"})


assert pathlib.Path("bloom-validation.txt").read_text() == "Bloom remote protocol fixture\n"
emit({"type": "system", "subtype": "init", "session_id": "fixture", "model": "fixture"})
for line in sys.stdin:
    message = json.loads(line)
    if message["type"] == "control_response":
        assert message["response"]["response"]["behavior"] == "allow"
        pathlib.Path("hello.txt").write_text("Changed by the remote fixture\n")
        finish()
    elif message["type"] == "user":
        prompt = "".join(block["text"] for block in message["message"]["content"])
        if prompt == "approval":
            emit({"type": "control_request", "request_id": str(uuid.uuid4()),
                  "request": {"subtype": "can_use_tool", "tool_name": "Write",
                              "input": {"file_path": "hello.txt", "content": "Changed by the remote fixture\n"}}})
        elif prompt == "wait":
            # Remain alive, waiting on stdin, until the server sends SIGTERM.
            pass
        elif prompt == "finish":
            finish()
        else:
            raise ValueError("Unexpected fixture prompt")
