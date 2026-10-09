"""Model and node type inventory."""

from __future__ import annotations

import re
from typing import Any

from comfier_agent.protocol import canonical_hash

MODEL_EXT = re.compile(r"\.(safetensors|ckpt|pt|pth|bin|gguf|sft)$", re.I)

INPUT_FOLDER_MAP = {
    "ckpt_name": "checkpoints",
    "lora_name": "loras",
    "vae_name": "vae",
    "clip_name": "text_encoders",
    "clip_vision": "clip_vision",
    "control_net_name": "controlnet",
    "model_name": "checkpoints",
    "unet_name": "diffusion_models",
}


class InventorySnapshot:
    def __init__(self) -> None:
        self.models: dict[str, list[str]] = {}
        self.node_types: list[str] = []
        # What each engine reports: {"comfyui": {...}, "mflux": {"version": ..., "models": [...]}}.
        self.engines: dict[str, dict[str, Any]] = {}
        self.hash: str = ""
        self.object_info_hash: str = ""
        self._object_info: dict[str, Any] | None = None

    @property
    def object_info(self) -> dict[str, Any] | None:
        return self._object_info


async def scan_inventory(comfy, engines: dict[str, Any] | None = None) -> InventorySnapshot:
    snap = InventorySnapshot()
    snap.engines = {name: engine.info() for name, engine in (engines or {}).items()}
    if comfy is None:
        snap.hash = canonical_hash({"models": {}, "node_types": [], "engines": snap.engines})
        return snap
    folders = await comfy.models_folders()
    if folders:
        for folder in folders:
            snap.models[folder] = sorted(await comfy.models_in_folder(folder))
    obj = await comfy.object_info()
    snap._object_info = obj
    snap.node_types = sorted(obj.keys())
    snap.object_info_hash = canonical_hash(obj)
    if not folders:
        snap.models = models_from_object_info(obj)
    snap.hash = canonical_hash({
        "models": {k: sorted(v) for k, v in sorted(snap.models.items())},
        "node_types": sorted(snap.node_types),
        "engines": snap.engines,
    })
    return snap


def models_from_object_info(obj: dict[str, Any]) -> dict[str, list[str]]:
    grouped: dict[str, set[str]] = {}
    other: set[str] = set()
    for _node, spec in obj.items():
        inputs = spec.get("input", {}) if isinstance(spec, dict) else {}
        for section in inputs.values():
            if not isinstance(section, dict):
                continue
            for input_name, input_spec in section.items():
                options = None
                if isinstance(input_spec, (list, tuple)) and input_spec:
                    if isinstance(input_spec[0], str):
                        options = input_spec
                    elif isinstance(input_spec[0], (list, tuple)):
                        options = input_spec[0]
                elif isinstance(input_spec, dict) and isinstance(input_spec.get("options"), list):
                    options = input_spec["options"]
                if not options:
                    continue
                model_names = [o for o in options if isinstance(o, str) and MODEL_EXT.search(o)]
                if not model_names:
                    continue
                folder = INPUT_FOLDER_MAP.get(input_name, "other")
                target = grouped.setdefault(folder, set()) if folder != "other" else other
                if folder == "other":
                    target.update(model_names)
                else:
                    grouped.setdefault(folder, set()).update(model_names)
    result = {k: sorted(v) for k, v in grouped.items()}
    if other:
        result["other"] = sorted(other)
    return result


def inventory_message(snap: InventorySnapshot) -> dict[str, Any]:
    return {
        "type": "inventory",
        "hash": snap.hash,
        "models": snap.models,
        "node_types": snap.node_types,
        "object_info_hash": snap.object_info_hash,
        "engines": snap.engines,
    }
