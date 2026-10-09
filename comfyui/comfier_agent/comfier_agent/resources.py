"""Host and ComfyUI resource reporting."""

from __future__ import annotations

import os
import platform
import shutil
import socket
import sys
from typing import Any

from comfier_agent.config import AgentConfig


def _int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _host_ram_bytes() -> tuple[int | None, int | None]:
    """Return (total, available) using OS APIs when ComfyUI stats omit RAM."""
    try:
        if sys.platform == "darwin":
            import subprocess

            total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
            return total, None
        if sys.platform == "linux":
            meminfo: dict[str, int] = {}
            with open("/proc/meminfo", encoding="utf-8") as handle:
                for line in handle:
                    key, rest = line.split(":", 1)
                    meminfo[key] = int(rest.strip().split()[0]) * 1024
            return meminfo.get("MemTotal"), meminfo.get("MemAvailable") or meminfo.get("MemFree")
    except OSError:
        pass
    return None, None


def _cpu_info() -> dict[str, int | None]:
    logical = os.cpu_count()
    physical = logical
    try:
        if sys.platform == "linux":
            with open("/proc/cpuinfo", encoding="utf-8") as handle:
                physical = len({line.split(":")[1].strip() for line in handle if line.startswith("core id")}) or logical
    except OSError:
        pass
    return {"logical_cores": logical, "physical_cores": physical}


def _normalize_devices(raw: list[Any] | None) -> list[dict[str, Any]]:
    devices: list[dict[str, Any]] = []
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        devices.append({
            "name": item.get("name"),
            "type": item.get("type"),
            "index": item.get("index"),
            "vram_total_bytes": _int(item.get("vram_total") or item.get("vram_total_bytes")),
            "vram_free_bytes": _int(item.get("vram_free") or item.get("vram_free_bytes")),
        })
    return devices


def apple_silicon_devices(ram_total: int | None) -> list[dict[str, Any]]:
    """Without ComfyUI to describe the GPU, an Apple Silicon Mac reports its chip, which shares the RAM."""
    if sys.platform != "darwin" or platform.machine() != "arm64":
        return []
    try:
        import subprocess

        name = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    except (OSError, subprocess.SubprocessError):
        name = "Apple Silicon"
    return [{"name": name or "Apple Silicon", "type": "mps", "index": 0, "vram_total_bytes": ram_total,
             "vram_free_bytes": None}]


def machine_type_label(devices: list[dict[str, Any]]) -> str:
    if not devices:
        return "cpu"
    types = {str(d.get("type") or "").lower() for d in devices}
    if "cuda" in types:
        return "cuda"
    if "mps" in types:
        return "apple_silicon"
    if "rocm" in types or "hip" in types:
        return "rocm"
    if "directml" in types:
        return "directml"
    if types - {"", "cpu"}:
        return sorted(types - {""})[0]
    return "cpu"


def build_resources(stats: dict[str, Any] | None, *, config: AgentConfig | None = None) -> dict[str, Any]:
    stats = stats or {}
    system = stats.get("system") if isinstance(stats.get("system"), dict) else {}
    devices = _normalize_devices(stats.get("devices"))

    ram_total = _int(system.get("ram_total") or system.get("ram_total_bytes"))
    ram_available = _int(system.get("ram_free") or system.get("ram_available") or system.get("ram_available_bytes"))
    if ram_total is None:
        host_total, host_avail = _host_ram_bytes()
        ram_total = host_total
        if ram_available is None:
            ram_available = host_avail

    comfyui_version = system.get("comfyui_version") or stats.get("comfyui_version")
    if not devices and not stats:
        devices = apple_silicon_devices(ram_total)

    platform_info = {
        "os": system.get("os") or platform.system().lower(),
        "release": platform.release(),
        "arch": platform.machine(),
        "hostname": config.backend_name if config else socket.gethostname(),
        "python": system.get("python_version") or sys.version.split()[0],
        "pytorch": system.get("pytorch_version"),
    }

    return {
        "machine_type": machine_type_label(devices),
        "platform": platform_info,
        "comfyui_version": comfyui_version,
        "cpu": _cpu_info(),
        "ram": {
            "total_bytes": ram_total,
            "available_bytes": ram_available,
        },
        "gpus": devices,
    }


def nearest_existing(path: str) -> str:
    """path, or the closest folder above it that exists."""
    current = os.path.abspath(path)
    while not os.path.isdir(current) and os.path.dirname(current) != current:
        current = os.path.dirname(current)
    return current


def _paths_for_disk_check(config: AgentConfig) -> list[tuple[str, str]]:
    paths: list[tuple[str, str]] = []

    def add(label: str, path: str | None) -> None:
        if path and os.path.isdir(path):
            paths.append((label, path))

    if config.comfyui_input_dir:
        add("input", config.comfyui_input_dir)
    if config.comfyui_output_dir:
        add("output", config.comfyui_output_dir)
    if config.comfyui_models_dir:
        add("models", config.comfyui_models_dir)

    # mflux and mlx-video keep job files in work_dir and models in the Hugging Face cache. Neither may
    # exist yet on a fresh machine; the disk they'll be created on is what counts. A ComfyUI-only server
    # uses neither, so a small home disk mustn't stop it.
    from comfier_agent.engines import MLX_PACKAGES, engine_names

    if any(name in MLX_PACKAGES for name in engine_names(config)):
        from comfier_agent.engines.mlx import hf_hub_cache

        add("work", nearest_existing(os.path.expanduser(config.work_dir)))
        add("hf_cache", nearest_existing(str(hf_hub_cache())))

    try:
        import folder_paths  # type: ignore

        add("input", folder_paths.get_input_directory())
        add("output", folder_paths.get_output_directory())
        for name in folder_paths.folder_names_and_paths:
            add(name, folder_paths.get_folder_paths(name)[0])
    except Exception:
        pass

    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for label, path in paths:
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        unique.append((label, real))
    return unique


def disk_free_by_label(config: AgentConfig) -> dict[str, int]:
    result: dict[str, int] = {}
    for label, path in _paths_for_disk_check(config):
        try:
            result[label] = shutil.disk_usage(path).free
        except OSError:
            continue
    return collapse_disk_free(result)


def collapse_disk_free(by_label: dict[str, int]) -> dict[str, int]:
    """Collapse to a single entry when every path reports the same free space (one disk)."""
    if not by_label:
        return {}
    values = set(by_label.values())
    if len(values) == 1:
        return {"disk": next(iter(values))}
    return dict(by_label)


def disk_job_headroom(config: AgentConfig) -> tuple[int | None, str | None]:
    """Minimum free bytes across job-relevant disks, and the limiting path label."""
    by_label = disk_free_by_label(config)
    if not by_label:
        return None, None
    label, free = min(by_label.items(), key=lambda item: item[1])
    return free, label


def disk_acceptance(config: AgentConfig) -> tuple[bool, str | None]:
    """Whether the backend has enough disk to accept jobs, and a human reason if not."""
    minimum = int(config.min_free_disk_gb * 1024**3)
    free, label = disk_job_headroom(config)
    if free is None:
        return True, None
    if free >= minimum:
        return True, None
    gb_free = free / 1024**3
    return False, (
        f"Less than {config.min_free_disk_gb:g} GB free disk for jobs "
        f"({gb_free:.1f} GB on {label})"
    )
