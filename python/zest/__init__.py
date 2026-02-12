"""zest — P2P acceleration for ML model distribution.

Usage:
    import zest
    zest.enable()  # Monkey-patches huggingface_hub for P2P downloads

    # Or use directly:
    path = zest.pull("meta-llama/Llama-3.1-8B")
    print(zest.status())
    zest.stop()
"""

from __future__ import annotations

import os

__version__ = "0.3.3"

_server = None
_client = None


def _init():
    global _server, _client
    if _server is None:
        from .server import ZestServer
        from .client import ZestClient

        _server = ZestServer()
        _client = ZestClient()


def enable() -> None:
    """Start the zest server and monkey-patch huggingface_hub."""
    _init()
    _server.ensure_running()
    from .hf_backend import patch_hf_hub

    patch_hf_hub(_client)


def disable() -> None:
    """Restore original huggingface_hub behavior."""
    from .hf_backend import unpatch_hf_hub

    unpatch_hf_hub()


def pull(repo: str, revision: str = "main") -> str:
    """Download a model via zest, return the cache path."""
    _init()
    _server.ensure_running()
    return _client.pull(repo, revision)


def status() -> dict:
    """Get zest server status."""
    _init()
    _server.ensure_running()
    return _client.status()


def stop() -> None:
    """Stop the zest server."""
    _init()
    _server.stop()


# Auto-enable when ZEST=1 is set
if os.environ.get("ZEST", "").strip() in ("1", "true", "yes"):
    try:
        enable()
    except Exception:
        pass
