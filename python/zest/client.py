"""HTTP client for the zest server REST API."""

from __future__ import annotations

from typing import Callable

import requests

DEFAULT_HTTP_PORT = 9847
REQUEST_TIMEOUT = 300.0  # 5 min for large model downloads


class ZestClient:
    """Communicates with the zest server over its localhost HTTP API."""

    def __init__(self, http_port: int = DEFAULT_HTTP_PORT) -> None:
        self.http_port = http_port
        self._base_url = f"http://127.0.0.1:{http_port}"

    def pull(
        self,
        repo: str,
        revision: str = "main",
        callback: Callable[[dict], None] | None = None,
    ) -> str:
        """Trigger a model download and return the cache path.

        Args:
            repo: HuggingFace repo ID (e.g. "meta-llama/Llama-3.1-8B").
            revision: Git revision (default "main").
            callback: Optional progress callback receiving event dicts.

        Returns:
            Path to the downloaded model snapshot directory.
        """
        resp = requests.post(
            f"{self._base_url}/v1/pull",
            json={"repo": repo, "revision": revision},
            timeout=REQUEST_TIMEOUT,
            stream=True,
        )
        resp.raise_for_status()

        # When SSE streaming is implemented, parse events and call callback.
        # For now, return the JSON response body.
        data = resp.json()
        if callback is not None:
            callback(data)
        return data.get("path", "")

    def status(self) -> dict:
        """Get server status."""
        resp = requests.get(
            f"{self._base_url}/v1/status", timeout=5.0
        )
        resp.raise_for_status()
        return resp.json()
