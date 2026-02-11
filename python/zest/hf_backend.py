"""HuggingFace Hub integration — monkey-patch snapshot_download."""

from __future__ import annotations

_original_snapshot_download = None
_patched = False


def patch_hf_hub(client) -> None:
    """Replace huggingface_hub.snapshot_download with zest-accelerated version."""
    global _original_snapshot_download, _patched
    if _patched:
        return

    try:
        import huggingface_hub
    except ImportError:
        return

    _original_snapshot_download = huggingface_hub.snapshot_download

    def zest_snapshot_download(repo_id, revision=None, **kwargs):
        try:
            path = client.pull(repo_id, revision or "main")
            if path:
                return path
        except Exception:
            pass
        # Fallback to original on any failure
        return _original_snapshot_download(repo_id, revision=revision, **kwargs)

    huggingface_hub.snapshot_download = zest_snapshot_download
    _patched = True


def unpatch_hf_hub() -> None:
    """Restore the original snapshot_download function."""
    global _original_snapshot_download, _patched
    if not _patched or _original_snapshot_download is None:
        return

    try:
        import huggingface_hub

        huggingface_hub.snapshot_download = _original_snapshot_download
    except ImportError:
        pass

    _patched = False
    _original_snapshot_download = None
