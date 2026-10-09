"""Prints mlx-video's version and the video models already in the Hugging Face cache, as JSON. Run in
its own process so the agent never imports MLX."""

from __future__ import annotations

import importlib.metadata
import json
import re

# Repos mlx-video loads with --model-repo (LTX-2 and its MLX conversions).
VIDEO_REPO = re.compile(r"ltx|wan", re.I)


def probe() -> dict:
    try:
        version = importlib.metadata.version("mlx-video")
    except importlib.metadata.PackageNotFoundError:
        version = None
    try:
        from huggingface_hub import scan_cache_dir

        repos = [r.repo_id for r in scan_cache_dir().repos if r.size_on_disk > 0 and VIDEO_REPO.search(r.repo_id)]
    except Exception:  # noqa: BLE001 - an empty or missing cache
        repos = []
    return {"version": version, "models": sorted(repos)}


if __name__ == "__main__":
    print(json.dumps(probe()))
