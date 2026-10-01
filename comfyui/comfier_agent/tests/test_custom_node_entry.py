"""Ensure the ComfyUI custom_nodes entry loads like ComfyUI does (no package on sys.path yet)."""

from __future__ import annotations

import importlib.util
import os
import sys


def test_entry_module_loads_like_comfyui():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    init_path = os.path.join(root, "__init__.py")
    name = "comfier_agent_custom_node_entry_test"
    spec = importlib.util.spec_from_file_location(name, init_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(name, None)

    assert module.WEB_DIRECTORY == "./web"
    assert module.NODE_CLASS_MAPPINGS == {}
