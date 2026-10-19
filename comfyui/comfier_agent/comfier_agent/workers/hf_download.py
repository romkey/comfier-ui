"""Downloads a Hugging Face model repo into the cache, for the mlx-video engine, reporting JSON events
on stdout like the mflux worker's --download: {"event": "repo"}, then "done" or "error"."""

from __future__ import annotations

import json
import re
import sys

REPO = re.compile(r"^[A-Za-z0-9][\w.-]*/[\w.-]+$")
# What mlx-video itself fetches (weights and configs), plus the tokenizer files a text encoder repo needs.
PATTERNS = ["*.safetensors", "*.json", "*.model", "*.txt", "*.jinja"]
# Lightricks/LTX-2.5 holds every variant (about 200 GB: dev, int8, nvfp4, LoRAs). mlx-video's distilled
# pipeline reads only these, about 73 GB (LTX25_REQUIRED_FILES in mlx_video/models/ltx_2/generate.py).
REPO_PATTERNS = {
    "lightricks/ltx-2.5": [
        "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors",
        "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors",
        "vae/ltx-2.5-video-vae-conv-bf16.safetensors",
        "vae/ltx-2.5-audio-vae-bf16.safetensors",
        "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors",
        "model_patches/ltx-2.5-duration-head-bf16.safetensors",
    ],
    # SceneWorks' Wan2.2 T2V A14B conversions: bf16, q4 and q8 (about 209 GB). The 8-bit style loads q8/, about 43 GB.
    "sceneworks/wan2.2-t2v-a14b-mlx": ["q8/*"],
}


def emit(event: dict) -> None:
    print(json.dumps(event), flush=True)


def patterns_for(repo: str) -> list[str]:
    return REPO_PATTERNS.get(repo.lower(), PATTERNS)


def failure_message(repo: str, exc: Exception) -> str:
    message = f"{type(exc).__name__}: {exc}"
    if type(exc).__name__ == "GatedRepoError" or "401" in message or "gated" in message.lower():
        return (f"{repo} is gated: accept its terms at https://huggingface.co/{repo}, then sign in on this Mac "
                f"with `hf auth login` ({message.splitlines()[0]})")
    return message


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    repo = argv[0] if argv else ""
    if not REPO.match(repo):
        emit({"event": "error", "message": f"{repo!r} isn't a Hugging Face repo (owner/name)"})
        return 1
    try:
        from huggingface_hub import snapshot_download

        emit({"event": "repo", "repo": repo})
        snapshot_download(repo_id=repo, allow_patterns=patterns_for(repo))
    except Exception as exc:  # noqa: BLE001 - every failure has to reach the agent
        emit({"event": "error", "message": failure_message(repo, exc)})
        return 1
    emit({"event": "done"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
