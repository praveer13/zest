"""CLI entry point — delegates to the bundled Zig binary."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> None:
    """Find and exec the bundled zest binary with all CLI args."""
    binary = _find_binary()
    if binary is None:
        print("error: zest binary not found", file=sys.stderr)
        print("Looked in: package _bin/, PATH, ~/.local/bin/", file=sys.stderr)
        sys.exit(1)

    os.execv(binary, [binary] + sys.argv[1:])


def _find_binary() -> str | None:
    # 1. Bundled binary in _bin/
    pkg_bin = Path(__file__).parent / "_bin" / "zest"
    if pkg_bin.is_file() and os.access(pkg_bin, os.X_OK):
        return str(pkg_bin)

    # 2. PATH lookup (in case installed separately)
    from shutil import which

    path_bin = which("zest")
    if path_bin is not None and Path(path_bin).resolve() != Path(sys.argv[0]).resolve():
        return path_bin

    # 3. ~/.local/bin
    local_bin = Path.home() / ".local" / "bin" / "zest"
    if local_bin.is_file() and os.access(local_bin, os.X_OK):
        return str(local_bin)

    return None


if __name__ == "__main__":
    main()
