"""Client for interacting with zest — uses CLI for pull, HTTP for status."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from shutil import which

import requests

DEFAULT_HTTP_PORT = 9847


class ZestClient:
    """Communicates with zest via CLI (pull) and HTTP API (status)."""

    def __init__(self, http_port: int = DEFAULT_HTTP_PORT) -> None:
        self.http_port = http_port
        self._base_url = f"http://127.0.0.1:{http_port}"

    def pull(self, repo: str, revision: str = "main") -> str:
        """Download a model via the zest CLI, return the cache path.

        Args:
            repo: HuggingFace repo ID (e.g. "meta-llama/Llama-3.1-8B").
            revision: Git revision (default "main").

        Returns:
            Path to the downloaded model snapshot directory.
        """
        binary = _find_zest_binary()
        cmd = [binary, "pull", repo, "--revision", revision]
        result = subprocess.run(cmd)
        if result.returncode != 0:
            raise RuntimeError(f"zest pull failed (exit code {result.returncode})")

        # Return the HF cache snapshot path
        safe_name = repo.replace("/", "--")
        snapshots = Path.home() / ".cache" / "huggingface" / "hub" / f"models--{safe_name}" / "snapshots"
        if snapshots.is_dir():
            # Return the most recent snapshot
            dirs = sorted(snapshots.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
            if dirs:
                return str(dirs[0])
        return ""

    def status(self) -> dict:
        """Get server status."""
        resp = requests.get(
            f"{self._base_url}/v1/status", timeout=5.0
        )
        resp.raise_for_status()
        return resp.json()


def _find_zest_binary() -> str:
    """Find the zest binary."""
    # 1. Bundled in package
    pkg_bin = Path(__file__).parent / "_bin" / "zest"
    if pkg_bin.is_file():
        return str(pkg_bin)

    # 2. On PATH
    on_path = which("zest")
    if on_path:
        return on_path

    raise FileNotFoundError(
        "zest binary not found. Install with: pip install zest-transfer"
    )
