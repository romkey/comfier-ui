"""Runs an installed console script by name in this Python, e.g.
`python -m comfier_agent.workers.entry_point mlx_video.ltx_2.generate --prompt ...`.

A uv tool install keeps its dependencies' scripts off PATH, and some script names (like
mlx_video.ltx_2.generate) aren't importable module paths, so the agent goes through the entry point."""

from __future__ import annotations

import contextlib
import importlib
import importlib.metadata
import json
import os
import sys
from pathlib import Path

# Set by the mlx_video engine from a recipe's "quantize" (bits): LTX-2.5's weights are quantized as they load.
QUANTIZE_ENV = "COMFIER_MLX_QUANTIZE"
QUANTIZE_GROUP = 64
# Quantized copies are kept here (about 34 GB at 8 bits) and loaded instead of re-quantizing: an LTX-2.5 job starts
# about 6 s sooner (20 s instead of 26 on an M3 Ultra).
QUANTIZED_DIR_ENV = "COMFIER_MLX_QUANTIZED_DIR"
QUANTIZED_DIR = "~/.comfier/quantized"
# Bump when what gets quantized changes, so older copies aren't used.
QUANTIZE_FORMAT = 1
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


def quantized_copy_path(source: Path, bits: int) -> Path:
    """Where a checkpoint's quantized copy lives. The name carries the source's size and modification time, so a
    re-downloaded checkpoint gets a fresh copy."""
    stat = source.stat()
    root = Path(os.path.expanduser(os.environ.get(QUANTIZED_DIR_ENV) or QUANTIZED_DIR))
    version = f"q{bits}g{QUANTIZE_GROUP}v{QUANTIZE_FORMAT}.{stat.st_size}-{int(stat.st_mtime)}"
    return root / f"{source.stem}.{version}.safetensors"


def quantize_ltx_weights() -> None:
    """With COMFIER_MLX_QUANTIZE set, quantizes LTX-2.5's transformer blocks and its Gemma 4 text encoder's layers
    (the Linear layers, in groups of 64) as they load, one piece at a time, so the bf16 weights are never all in
    memory. At 8 bits an LTX-2.5 job peaks at about 29 GB instead of 46, and looks the same. The first run saves the
    quantized weights (QUANTIZED_DIR) and later runs load those. Other models (LTX-2.3, whose transformer is a
    folder, and Wan) load as they would have."""
    try:
        bits = int(float(os.environ.get(QUANTIZE_ENV) or 0))
    except ValueError:
        bits = 0
    if not bits:
        return
    try:
        import mlx.core as mx
        import mlx.nn as nn
        from mlx.utils import tree_flatten
        from mlx_video.models.ltx_2 import ltx_2, text_encoder
        from safetensors import safe_open
    except ImportError:
        return

    def metadata(path: Path) -> dict:
        with safe_open(path, framework="numpy") as f:
            return f.metadata() or {}

    def quantize(model, scope: str) -> None:
        nn.quantize(model, group_size=QUANTIZE_GROUP, bits=bits, class_predicate=lambda path, module: (
            scope in path and isinstance(module, nn.Linear) and module.weight.shape[-1] % QUANTIZE_GROUP == 0))

    def evaluate_in_pieces(params) -> None:
        if isinstance(params, dict):
            params = list(params.values())
        if isinstance(params, list):
            for value in params:
                evaluate_in_pieces(value)
        else:
            mx.eval(params)

    def save(model, source: Path, copy: Path) -> None:
        partial = copy.with_name(f"{copy.stem}.partial.safetensors")
        try:
            copy.parent.mkdir(parents=True, exist_ok=True)
            for stale in copy.parent.glob(f"{source.stem}.q{bits}g*.safetensors"):
                stale.unlink()
            mx.save_safetensors(str(partial), dict(tree_flatten(model.parameters())))
            partial.replace(copy)
        except Exception as exc:  # noqa: BLE001 - a full disk only costs the next run its head start
            print(f"comfier: couldn't save quantized weights to {copy}: {exc}", file=sys.stderr, flush=True)
            with contextlib.suppress(OSError):
                partial.unlink(missing_ok=True)

    def load(source: Path, skeleton, load_bf16, scope: str):
        """skeleton() builds the model without weights; load_bf16(model) loads the checkpoint into it, lazily."""
        copy = quantized_copy_path(source, bits)
        if copy.is_file():
            try:
                model = skeleton()
                quantize(model, scope)
                model.load_weights(str(copy), strict=True)
                evaluate_in_pieces(model.parameters())
                return model
            except Exception as exc:  # noqa: BLE001 - an unreadable copy is rebuilt from the checkpoint
                print(f"comfier: couldn't load {copy.name} ({exc}); quantizing again", file=sys.stderr, flush=True)
                with contextlib.suppress(OSError):
                    copy.unlink(missing_ok=True)
        model = skeleton()
        load_bf16(model)
        quantize(model, scope)
        evaluate_in_pieces(model.parameters())
        save(model, source, copy)
        return model

    model_class = getattr(ltx_2, "LTXModel", None)
    if model_class is not None and hasattr(model_class, "sanitize") and hasattr(ltx_2, "LTXModelConfig"):
        original_ltx = model_class.from_pretrained.__func__

        def ltx_from_pretrained(cls, model_path, strict=True):
            # LTX-2.5 ships its transformer as one file; this mirrors mlx-video's loader for it, quantizing before
            # anything is evaluated (its own evaluates every bf16 weight at once).
            model_path = Path(model_path)
            if not model_path.is_file():
                return original_ltx(cls, model_path, strict)

            def skeleton():
                info = metadata(model_path)
                config = json.loads(info["config"])["transformer"]
                config["model_version"] = info.get("model_version")
                config["has_prompt_adaln"] = config.get("cross_attention_adaln", False)
                config["audio_ff_bias"] = config.get("audio_ff_bias", True)
                return cls(ltx_2.LTXModelConfig.from_dict(config))

            def load_bf16(model):
                weights = model.sanitize(mx.load(str(model_path)))
                model.load_weights([(k, v.astype(mx.bfloat16) if v.dtype == mx.float32 else v)
                                    for k, v in weights.items()], strict=strict)

            model = load(model_path, skeleton, load_bf16, "transformer_blocks")
            model.eval()
            return model

        model_class.from_pretrained = classmethod(ltx_from_pretrained)

    gemma4 = getattr(text_encoder, "Gemma4LanguageModel", None)
    if gemma4 is not None and hasattr(gemma4, "from_pretrained"):

        def gemma4_from_pretrained(cls, checkpoint_path):
            # Mirrors mlx-video's loader: the Gemma config is in the checkpoint's metadata, its weights under "model.".
            checkpoint_path = Path(checkpoint_path)

            def skeleton():
                return cls(json.loads(metadata(checkpoint_path)["gemma_config"]))

            def load_bf16(model):
                weights = mx.load(str(checkpoint_path))
                model.model.load_weights([(k, v) for k, v in weights.items() if k.startswith("model.")], strict=True)

            return load(checkpoint_path, skeleton, load_bf16, "layers.")

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
