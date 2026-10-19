"""fp8 safetensors to fp16, for Apple Silicon: PyTorch's MPS device can't hold fp8 tensors.

Handles ComfyUI's two scaled-fp8 layouts (``scale_weight`` with a ``scaled_fp8`` marker, and comfy_quant's
``weight_scale``) and unscaled fp8. Each fp8 weight is multiplied by its scale and stored as fp16; the scales and
quantization markers are dropped, so ComfyUI loads the result as a plain fp16 model. Tensors are read through a
memory map and written one at a time, so memory use stays near the largest tensor, not the model.
"""

from __future__ import annotations

import contextlib
import json
import os
from collections.abc import Callable

FP8_DTYPES = {"F8_E4M3", "F8_E5M2"}
SCALE_SUFFIXES = ("scale_weight", "weight_scale")
DROPPED_SUFFIXES = ("scale_input", "input_scale", "comfy_quant")
MARKERS = {"scaled_fp8"}
DROPPED_METADATA = {"_quantization_metadata"}
FP16_MAX = 65504.0
ITEM_SIZE = {"F64": 8, "F32": 4, "F16": 2, "BF16": 2, "I64": 8, "I32": 4, "I16": 2, "I8": 1, "U8": 1, "BOOL": 1,
             "F8_E4M3": 1, "F8_E5M2": 1}
CHUNK_ELEMENTS = 1 << 24


class ConversionError(Exception):
    pass


class ConversionCancelled(Exception):
    pass


def convert_fp8_to_fp16(src: str, dst: str, cancelled: Callable[[], bool] = lambda: False) -> int:
    """Writes src (fp8 safetensors) to dst as fp16 and returns dst's size. dst is removed on failure."""
    try:
        import numpy as np
    except ImportError as exc:
        raise ConversionError("numpy isn't installed") from exc

    header, data_start = _read_header(src)
    metadata = {k: v for k, v in (header.pop("__metadata__", None) or {}).items() if k not in DROPPED_METADATA}
    raw = np.memmap(src, dtype=np.uint8, mode="r", offset=data_start)
    plan = _plan(header, raw)
    try:
        with open(dst, "wb") as out:
            _write_header(out, plan, metadata)
            for name, info, scale_key in plan:
                if cancelled():
                    raise ConversionCancelled()
                _write_tensor(out, np, raw, header, name, info, scale_key, cancelled)
        return os.path.getsize(dst)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.remove(dst)
        raise


def _read_header(path: str) -> tuple[dict, int]:
    with open(path, "rb") as f:
        length = int.from_bytes(f.read(8), "little")
        if length <= 0 or length > 100 * 1024 * 1024:
            raise ConversionError("not a safetensors file")
        try:
            header = json.loads(f.read(length).decode("utf-8"))
        except ValueError as exc:
            raise ConversionError("not a safetensors file") from exc
    return header, 8 + length


def _prefix(name: str, suffix: str) -> str | None:
    if name == suffix:
        return ""
    return name[: -len(suffix) - 1] if name.endswith("." + suffix) else None


def _plan(header: dict, raw) -> list[tuple[str, dict, str | None]]:
    """(name, header entry, scale tensor name) for every tensor kept, in file order."""
    used_scales: set[str] = set()
    plan = []
    for name, info in sorted(header.items(), key=lambda kv: kv[1]["data_offsets"][0]):
        if name in MARKERS or any(_prefix(name, s) is not None for s in DROPPED_SUFFIXES + SCALE_SUFFIXES):
            _check_quant(name, info, header, raw)
            continue
        if info["dtype"] not in ITEM_SIZE:
            raise ConversionError(f"{name} is {info['dtype']}, which can't be converted")
        scale_key = None
        if info["dtype"] in FP8_DTYPES:
            prefix = _prefix(name, "weight")
            candidates = [f"{prefix}{s}" if prefix == "" else f"{prefix}.{s}" for s in SCALE_SUFFIXES] \
                if prefix is not None else []
            scale_key = next((c for c in candidates if c in header), None)
            if scale_key:
                used_scales.add(scale_key)
        plan.append((name, info, scale_key))
    if not any(info["dtype"] in FP8_DTYPES for _, info, _ in plan):
        raise ConversionError("no fp8 tensors to convert")
    orphans = [n for n in header if any(_prefix(n, s) is not None for s in SCALE_SUFFIXES) and n not in used_scales]
    if orphans:
        raise ConversionError(f"{orphans[0]} scales a tensor that isn't fp8")
    return plan


def _check_quant(name: str, info: dict, header: dict, raw) -> None:
    """comfy_quant layers other than fp8 (nvfp4, mxfp8 and so on) pack their weights differently."""
    prefix = _prefix(name, "comfy_quant")
    if prefix is None:
        return
    start, end = info["data_offsets"]
    try:
        fmt = json.loads(bytes(raw[start:end]).decode("utf-8")).get("format", "")
    except (ValueError, AttributeError):
        fmt = ""
    weight = header.get(f"{prefix}.weight" if prefix else "weight", {})
    if not str(fmt).startswith("float8") or weight.get("dtype") not in FP8_DTYPES:
        raise ConversionError(f"{prefix or name} uses {fmt or 'an unknown'} quantization, not fp8")


def _out_info(info: dict) -> tuple[str, int]:
    numel = 1
    for dim in info["shape"]:
        numel *= dim
    if info["dtype"] in FP8_DTYPES:
        return "F16", numel * 2
    start, end = info["data_offsets"]
    return info["dtype"], end - start


def _write_header(out, plan, metadata: dict) -> None:
    entries: dict = {"__metadata__": metadata} if metadata else {}
    offset = 0
    for name, info, _scale in plan:
        dtype, size = _out_info(info)
        entries[name] = {"dtype": dtype, "shape": info["shape"], "data_offsets": [offset, offset + size]}
        offset += size
    data = json.dumps(entries, separators=(",", ":")).encode("utf-8")
    data += b" " * (-len(data) % 8)
    out.write(len(data).to_bytes(8, "little"))
    out.write(data)


def _lut(np, dtype: str):
    codes = np.arange(256, dtype=np.uint16)
    if dtype == "F8_E5M2":
        with np.errstate(invalid="ignore"):  # its NaN codes stay NaN
            return (codes << 8).view(np.float16).astype(np.float32)
    sign = np.where(codes & 0x80, -1.0, 1.0)
    exp = (codes >> 3) & 0xF
    mant = (codes & 0x7).astype(np.float64)
    values = np.where(exp == 0, mant / 8 * 2.0**-6, (1 + mant / 8) * 2.0 ** (exp.astype(np.float64) - 7))
    values = np.where((exp == 0xF) & ((codes & 0x7) == 0x7), np.nan, values)
    return (sign * values).astype(np.float32)


def _as_float32(np, data, dtype: str):
    if dtype == "F32":
        return data.view(np.float32)
    if dtype == "F16":
        return data.view(np.float16).astype(np.float32)
    if dtype == "BF16":
        return (data.view(np.uint16).astype(np.uint32) << 16).view(np.float32)
    raise ConversionError(f"scale stored as {dtype}")


def _write_tensor(out, np, raw, header, name, info, scale_key, cancelled) -> None:
    start, end = info["data_offsets"]
    data = raw[start:end]
    if info["dtype"] not in FP8_DTYPES:
        out.write(data.tobytes())
        return
    lut = _lut(np, info["dtype"])
    scale = np.float32(1.0)
    if scale_key:
        s_info = header[scale_key]
        s_start, s_end = s_info["data_offsets"]
        scale = _as_float32(np, np.array(raw[s_start:s_end]), s_info["dtype"])
        shape = info["shape"]
        if scale.size == 1:
            scale = scale.reshape(())
        elif shape and scale.size == shape[0]:
            scale = scale.reshape((shape[0],) + (1,) * (len(shape) - 1))
        else:
            raise ConversionError(f"{name} has block-wise scales, which can't be converted")
    if scale.ndim == 0:
        for i in range(0, data.size, CHUNK_ELEMENTS):
            if cancelled():
                raise ConversionCancelled()
            chunk = lut[data[i : i + CHUNK_ELEMENTS]] * scale
            out.write(np.clip(chunk, -FP16_MAX, FP16_MAX).astype(np.float16).tobytes())
        return
    values = lut[data].reshape(info["shape"]) * scale
    out.write(np.clip(values, -FP16_MAX, FP16_MAX).astype(np.float16).tobytes())
