"""Runs an installed console script by name in this Python, e.g.
`python -m comfier_agent.workers.entry_point mlx_video.ltx_2.generate --prompt ...`.

A uv tool install keeps its dependencies' scripts off PATH, and some script names (like
mlx_video.ltx_2.generate) aren't importable module paths, so the agent goes through the entry point."""

from __future__ import annotations

import importlib
import importlib.metadata
import sys


def find(command: str):
    for entry in importlib.metadata.entry_points(group="console_scripts"):
        if entry.name == command:
            module, _, attr = entry.value.partition(":")
            target = importlib.import_module(module)
            for part in (attr or "main").split("."):
                target = getattr(target, part)
            return target
    raise SystemExit(f"{command} isn't installed in {sys.executable}")


def fix_ltx_text_encoder_mask() -> None:
    """mlx-video's Gemma text encoder masks padding with an additive bf16 finfo.min, which on some Macs makes
    MLX's attention return NaN for the padded rows at its 1024-token length, so every LTX video decodes
    black (Blaizzy/mlx-video#55). A boolean mask, which mx.fast.scaled_dot_product_attention takes as is,
    doesn't. Drop this once mlx-video ships the fix."""
    try:
        import mlx.core as mx
        from mlx_video.models.ltx_2.text_encoder import LanguageModel
    except ImportError:
        return
    if not hasattr(LanguageModel, "_create_causal_mask_with_padding"):
        return

    def boolean_mask(self, seq_len, attention_mask, dtype):
        causal = mx.tril(mx.ones((seq_len, seq_len), dtype=mx.bool_))
        if attention_mask is None:
            return causal[None, None, :, :]
        combined = causal[None, :, :] & attention_mask.astype(mx.bool_)[:, None, :]
        return combined[:, None, :, :]

    LanguageModel._create_causal_mask_with_padding = boolean_mask


# Fixes applied before running a command, by command prefix.
FIXES = {"mlx_video.ltx_2.": fix_ltx_text_encoder_mask}


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: python -m comfier_agent.workers.entry_point COMMAND [ARGS...]")
    command = sys.argv[1]
    func = find(command)
    for prefix, fix in FIXES.items():
        if command.startswith(prefix):
            fix()
    sys.argv = [command, *sys.argv[2:]]
    result = func()
    sys.exit(result if isinstance(result, int) else 0)


if __name__ == "__main__":
    main()
