"""Execution engines: ComfyUI, and the native Apple Silicon tools mflux and mlx-video."""

from __future__ import annotations

import importlib.util
import logging

LOG = logging.getLogger("comfier_agent")

KNOWN = ("comfyui", "mflux", "mlx_video")
# The Python package each MLX engine needs.
MLX_PACKAGES = {"mflux": "mflux", "mlx_video": "mlx_video"}


def installed(package: str) -> bool:
    try:
        return importlib.util.find_spec(package) is not None
    except (ImportError, ValueError):
        return False


def engine_names(config) -> list[str]:
    """The configured engines, or ComfyUI plus whichever MLX tools are installed."""
    if config.engines:
        unknown = [n for n in config.engines if n not in KNOWN]
        if unknown:
            LOG.warning("ignoring unknown engines: %s", ", ".join(unknown))
        return [n for n in KNOWN if n in config.engines]
    return ["comfyui", *(name for name, pkg in MLX_PACKAGES.items() if installed(pkg))]


def build_engines(config, comfy) -> dict:
    from comfier_agent.engines.comfyui import ComfyUIEngine

    engines = {}
    for name in engine_names(config):
        if name == "comfyui":
            engines[name] = ComfyUIEngine(comfy)
        elif name == "mflux":
            from comfier_agent.engines.mflux import MfluxEngine

            engines[name] = MfluxEngine(config)
        elif name == "mlx_video":
            from comfier_agent.engines.mlx_video import MlxVideoEngine

            engines[name] = MlxVideoEngine(config)
        if name in MLX_PACKAGES and not installed(MLX_PACKAGES[name]):
            LOG.warning("%s is enabled but the %s package isn't installed; its jobs will fail", name,
                        MLX_PACKAGES[name])
    return engines
