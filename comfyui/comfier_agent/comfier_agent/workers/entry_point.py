"""Runs an installed console script by name in this Python, e.g.
`python -m comfier_agent.workers.entry_point mlx_video.ltx_2.generate --prompt ...`.

A uv tool install keeps its dependencies' scripts off PATH, and some script names (like
mlx_video.ltx_2.generate) aren't importable module paths, so the agent goes through the entry point."""

from __future__ import annotations

import importlib
import importlib.metadata
import json
import os
import sys
from pathlib import Path

# Set by the mlx_video engine from a recipe's "quantize" (bits): LTX-2.5's weights are quantized as they load.
QUANTIZE_ENV = "COMFIER_MLX_QUANTIZE"
QUANTIZE_GROUP = 64
# MLX keeps freed buffers for reuse. While LTX decodes video they pile up to about 56 GB (with 6 GB in use),
# which macOS counts against the job. Capping the cache gives them back; the output is the same.
MLX_CACHE_LIMIT = 4 * 2**30


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
    doesn't. LTX-2.5's Gemma 4 encoder builds its mask the same way. Drop this once mlx-video ships the fix."""
    try:
        import mlx.core as mx
        from mlx_video.models.ltx_2 import text_encoder
    except ImportError:
        return

    def boolean_mask(seq_len, attention_mask):
        causal = mx.tril(mx.ones((seq_len, seq_len), dtype=mx.bool_))
        if attention_mask is None:
            return causal[None, None, :, :]
        combined = causal[None, :, :] & attention_mask.astype(mx.bool_)[:, None, :]
        return combined[:, None, :, :]

    gemma3 = getattr(text_encoder, "LanguageModel", None)
    if gemma3 is not None and hasattr(gemma3, "_create_causal_mask_with_padding"):
        gemma3._create_causal_mask_with_padding = lambda self, seq_len, attention_mask, dtype: boolean_mask(
            seq_len, attention_mask)
    gemma4 = getattr(text_encoder, "Gemma4LanguageModel", None)
    if gemma4 is not None and hasattr(gemma4, "_attention_mask"):
        # Without a mask there's no length to build one from; None lets Gemma 4 make its own causal masks.
        gemma4._attention_mask = lambda self, attention_mask, dtype: (
            None if attention_mask is None else boolean_mask(attention_mask.shape[1], attention_mask))


def limit_mlx_cache() -> None:
    try:
        import mlx.core as mx
    except ImportError:
        return
    mx.set_cache_limit(MLX_CACHE_LIMIT)


def quantize_ltx_weights() -> None:
    """With COMFIER_MLX_QUANTIZE set, quantizes LTX-2.5's transformer blocks and its Gemma 4 text encoder's layers
    (the Linear layers, in groups of 64) as they load, one piece at a time, so the bf16 weights are never all in
    memory. At 8 bits an LTX-2.5 job peaks at about 29 GB instead of 46, and looks the same. Other models (LTX-2.3,
    whose transformer is a folder, and Wan) load as they would have."""
    bits = os.environ.get(QUANTIZE_ENV)
    if not bits:
        return
    try:
        import mlx.core as mx
        import mlx.nn as nn
        from mlx_video.models.ltx_2 import ltx_2, text_encoder
    except ImportError:
        return
    bits = int(bits)

    def quantize(model, scope: str) -> None:
        nn.quantize(model, group_size=QUANTIZE_GROUP, bits=bits, class_predicate=lambda path, module: (
            scope in path and isinstance(module, nn.Linear) and module.weight.shape[-1] % QUANTIZE_GROUP == 0))
        evaluate_in_pieces(model.parameters())

    def evaluate_in_pieces(params) -> None:
        if isinstance(params, dict):
            params = list(params.values())
        if isinstance(params, list):
            for value in params:
                evaluate_in_pieces(value)
        else:
            mx.eval(params)

    model_class = getattr(ltx_2, "LTXModel", None)
    if model_class is not None and hasattr(model_class, "sanitize") and hasattr(ltx_2, "LTXModelConfig"):
        original_ltx = model_class.from_pretrained.__func__

        def ltx_from_pretrained(cls, model_path, strict=True):
            # LTX-2.5 ships its transformer as one file; this mirrors mlx-video's loader for it, quantizing before
            # anything is evaluated (its own evaluates every bf16 weight at once).
            model_path = Path(model_path)
            if not model_path.is_file():
                return original_ltx(cls, model_path, strict)
            from safetensors import safe_open

            with safe_open(model_path, framework="numpy") as f:
                metadata = f.metadata() or {}
            config = json.loads(metadata["config"])["transformer"]
            config["model_version"] = metadata.get("model_version")
            config["has_prompt_adaln"] = config.get("cross_attention_adaln", False)
            config["audio_ff_bias"] = config.get("audio_ff_bias", True)
            model = cls(ltx_2.LTXModelConfig.from_dict(config))
            weights = model.sanitize(mx.load(str(model_path)))
            model.load_weights([(k, v.astype(mx.bfloat16) if v.dtype == mx.float32 else v)
                                for k, v in weights.items()], strict=strict)
            del weights
            quantize(model, "transformer_blocks")
            model.eval()
            return model

        model_class.from_pretrained = classmethod(ltx_from_pretrained)

    gemma4 = getattr(text_encoder, "Gemma4LanguageModel", None)
    if gemma4 is not None and hasattr(gemma4, "from_pretrained"):
        original_gemma4 = gemma4.from_pretrained.__func__

        def gemma4_from_pretrained(cls, checkpoint_path):
            model = original_gemma4(cls, checkpoint_path)  # loaded but not yet evaluated
            quantize(model, "layers.")
            return model

        gemma4.from_pretrained = classmethod(gemma4_from_pretrained)


# Fixes applied before running a command, by command prefix.
FIXES = {
    "mlx_video.": [limit_mlx_cache],
    "mlx_video.ltx_2.": [fix_ltx_text_encoder_mask, quantize_ltx_weights],
}


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: python -m comfier_agent.workers.entry_point COMMAND [ARGS...]")
    command = sys.argv[1]
    func = find(command)
    for prefix, fixes in FIXES.items():
        if command.startswith(prefix):
            for fix in fixes:
                fix()
    sys.argv = [command, *sys.argv[2:]]
    result = func()
    sys.exit(result if isinstance(result, int) else 0)


if __name__ == "__main__":
    main()
