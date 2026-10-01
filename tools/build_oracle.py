#!/usr/bin/env python3
"""Compile k4o opaquely. Never display, inspect, or retain oracle source."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/drawmeanelephant/k4o.git"


def opaque(command, cwd):
    # Compiler diagnostics can include source excerpts. Discard them, too.
    result = subprocess.run(
        command, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=600, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"opaque {command[0]} step failed (exit {result.returncode}); "
                           "source and diagnostics deliberately not displayed")


def main():
    revision = (ROOT / "tools/k4o-revision.txt").read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("oracle revision must be a full commit SHA")
    destination = ROOT / ".oracle"
    destination.mkdir(exist_ok=True)
    # Only git and the compiler access the checkout. It is removed on exit.
    with tempfile.TemporaryDirectory(prefix="opaque-k4o-", dir=destination) as work:
        checkout = Path(work)
        opaque(["git", "init", "--quiet"], checkout)
        opaque(["git", "fetch", "--quiet", "--depth=1", REPOSITORY, revision], checkout)
        opaque(["git", "-c", "advice.detachedHead=false", "checkout", "--quiet", "FETCH_HEAD"], checkout)
        opaque(["zig", "build", "-Doptimize=ReleaseSafe"], checkout)
        staged = checkout / "oracle-binary"
        shutil.copy2(checkout / "zig-out/bin/k4o", staged)
        os.replace(staged, destination / "k4o")
    (destination / "revision.txt").write_text(revision + "\n")
    print(f"Built black-box oracle at {revision}: {destination / 'k4o'}")


if __name__ == "__main__":
    main()
