"""Zig binary lifecycle management — start, health check, stop."""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

import requests

DEFAULT_HTTP_PORT = 9847
HEALTH_TIMEOUT = 2.0
STARTUP_TIMEOUT = 5.0
STARTUP_POLL_INTERVAL = 0.2


class ZestServer:
    """Manages the lifecycle of the zest Zig server process."""

    def __init__(self, http_port: int = DEFAULT_HTTP_PORT) -> None:
        self.http_port = http_port
        self._base_url = f"http://127.0.0.1:{http_port}"
        self._process: subprocess.Popen | None = None

    def ensure_running(self) -> None:
        """Start the Zig server if not already running."""
        if self._health_check():
            return
        binary = self._find_binary()
        if binary is None:
            raise RuntimeError(
                "zest binary not found. Install it or place it in PATH."
            )
        self._process = subprocess.Popen(
            [binary, "serve", "--http-port", str(self.http_port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._wait_for_health()

    def stop(self) -> None:
        """Send a stop request to the running server."""
        try:
            requests.post(f"{self._base_url}/v1/stop", timeout=HEALTH_TIMEOUT)
        except requests.ConnectionError:
            pass
        if self._process is not None:
            self._process.wait(timeout=5)
            self._process = None

    def status(self) -> dict:
        """Get server status as a dict."""
        resp = requests.get(f"{self._base_url}/v1/status", timeout=HEALTH_TIMEOUT)
        resp.raise_for_status()
        return resp.json()

    def _health_check(self) -> bool:
        try:
            resp = requests.get(
                f"{self._base_url}/v1/health", timeout=HEALTH_TIMEOUT
            )
            return resp.status_code == 200
        except (requests.ConnectionError, requests.Timeout):
            return False

    def _wait_for_health(self) -> None:
        deadline = time.monotonic() + STARTUP_TIMEOUT
        while time.monotonic() < deadline:
            if self._health_check():
                return
            time.sleep(STARTUP_POLL_INTERVAL)
        raise RuntimeError(
            f"zest server did not start within {STARTUP_TIMEOUT}s"
        )

    @staticmethod
    def _find_binary() -> str | None:
        # 1. Bundled binary in _bin/
        pkg_bin = Path(__file__).parent / "_bin" / "zest"
        if pkg_bin.is_file() and os.access(pkg_bin, os.X_OK):
            return str(pkg_bin)

        # 2. PATH lookup
        path_bin = shutil.which("zest")
        if path_bin is not None:
            return path_bin

        # 3. ~/.local/bin
        local_bin = Path.home() / ".local" / "bin" / "zest"
        if local_bin.is_file() and os.access(local_bin, os.X_OK):
            return str(local_bin)

        return None
