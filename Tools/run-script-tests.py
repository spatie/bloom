#!/usr/bin/env python3
"""Run every script regression suite; keep platform skips in the tests that own them."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    suites = [[sys.executable, str(path.relative_to(root))] for path in sorted((root / "Tools").glob("test-*.py"))]
    # The release fixtures inspect real Mach-O files and exercise macOS packaging tools.
    if sys.platform == "darwin":
        suites.append(["zsh", "Tools/release/tests/run.sh"])
    for command in suites:
        print("Running " + command[-1], flush=True)
        result = subprocess.run(command, cwd=root, env=environment)
        if result.returncode:
            return result.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
