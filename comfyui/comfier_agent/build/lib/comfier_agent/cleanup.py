"""Legacy cleanup helpers (Comfier frontend POST /comfier/cleanup)."""

from __future__ import annotations

import os

ALLOWED_TYPES = frozenset({"input", "output", "temp"})


def delete_file(filename, subfolder="", file_type="output"):
    import folder_paths  # type: ignore

    file_type = file_type if file_type in ALLOWED_TYPES else "output"
    base = folder_paths.get_directory_by_type(file_type)
    if not base:
        raise ValueError(f"ComfyUI has no {file_type!r} folder")

    name = os.path.basename(str(filename).replace("\\", "/"))
    if not name or name in {".", ".."}:
        raise ValueError(f"{filename!r} isn't a valid file name")

    directory = base
    subfolder = str(subfolder or "").replace("\\", "/").strip("/")
    if subfolder:
        directory = os.path.join(base, subfolder)
        if os.path.commonpath([os.path.abspath(directory), os.path.abspath(base)]) != os.path.abspath(base):
            raise ValueError(f"{subfolder!r} points outside the {file_type} folder")

    path = os.path.join(directory, name)
    if os.path.isfile(path):
        os.remove(path)
        return True
    return False


def delete_input_image(name):
    cleaned = str(name).strip().replace("\\", "/")
    if not cleaned:
        return False
    subfolder, filename = cleaned.rsplit("/", 1) if "/" in cleaned else ("", cleaned)
    return delete_file(filename, subfolder=subfolder, file_type="input")
