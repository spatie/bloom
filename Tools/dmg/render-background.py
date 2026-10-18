#!/usr/bin/env python3
"""Render one DMG background and stop Chrome after its PNG is complete."""

import os
import signal
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def complete_png(path: Path, scale: int) -> bool:
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return False

    if len(data) < 45 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return False

    dimensions = struct.unpack(">II", data[16:24])
    return (
        dimensions == (660 * scale, 400 * scale)
        and data[-12:-8] == b"\x00\x00\x00\x00"
        and data[-8:-4] == b"IEND"
    )


def stop_chrome(process: subprocess.Popen[bytes]) -> None:
    signal_chrome(process, signal.SIGTERM)

    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass

    signal_chrome(process, signal.SIGKILL)

    process.wait()


def signal_chrome(process: subprocess.Popen[bytes], sig: signal.Signals) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can reject Chrome's group signal even after rendering the PNG.
        # Fall back to the process we launched.
        if process.poll() is None:
            try:
                process.send_signal(sig)
            except ProcessLookupError:
                pass


def render(chrome: Path, html: Path, output: Path, scale: int) -> None:
    output.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="bloom-dmg-chrome-") as profile:
        with tempfile.TemporaryFile() as errors:
            command = [
                str(chrome),
                "--headless",
                "--disable-gpu",
                "--hide-scrollbars",
                "--no-first-run",
                "--disable-background-networking",
                f"--user-data-dir={profile}",
                f"--screenshot={output}",
                "--window-size=660,400",
                f"--force-device-scale-factor={scale}",
                html.resolve().as_uri(),
            ]
            process = subprocess.Popen(
                command,
                stdout=subprocess.DEVNULL,
                stderr=errors,
                start_new_session=True,
            )

            deadline = time.monotonic() + 90
            try:
                while time.monotonic() < deadline:
                    if complete_png(output, scale):
                        break
                    if process.poll() is not None:
                        break
                    time.sleep(0.1)
            finally:
                stop_chrome(process)

            if not complete_png(output, scale):
                errors.seek(0)
                details = errors.read().decode(errors="replace")[-4_000:]
                raise RuntimeError(f"Chrome did not render {output} within 90 seconds.\n{details}")

    print(f"==> rendered {output.name} ({660 * scale}x{400 * scale})")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: render-background.py <chrome> <html> <output> <scale>")

    render(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]))
