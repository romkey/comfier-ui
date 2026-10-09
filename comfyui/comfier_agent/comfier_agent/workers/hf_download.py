"""Downloads a Hugging Face model repo into the cache, for the mlx-video engine, reporting JSON events
on stdout like the mflux worker's --download: {"event": "repo"}, then "done" or "error"."""

from __future__ import annotations

import json
import re
import sys

REPO = re.compile(r"^[A-Za-z0-9][\w.-]*/[\w.-]+$")
# What mlx-video itself fetches (weights and configs), plus the tokenizer files a text encoder repo needs.
PATTERNS = ["*.safetensors", "*.json", "*.model", "*.txt", "*.jinja"]


def emit(event: dict) -> None:
    print(json.dumps(event), flush=True)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    repo = argv[0] if argv else ""
    if not REPO.match(repo):
        emit({"event": "error", "message": f"{repo!r} isn't a Hugging Face repo (owner/name)"})
        return 1
    try:
        from huggingface_hub import snapshot_download

        emit({"event": "repo", "repo": repo})
        snapshot_download(repo_id=repo, allow_patterns=PATTERNS)
    except Exception as exc:  # noqa: BLE001 - every failure has to reach the agent
        emit({"event": "error", "message": f"{type(exc).__name__}: {exc}"})
        return 1
    emit({"event": "done"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
