"""Availability and load snapshot."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from comfier_agent.config import AgentConfig
from comfier_agent.resources import build_resources, disk_acceptance, disk_free_by_label


@dataclass
class ComfierJobStatus:
    job_id: str
    state: str
    progress: float = 0.0
    node: str | None = None


@dataclass
class StatusSnapshot:
    state: str = "starting"
    accepting: bool = False
    comfier_jobs: list[ComfierJobStatus] = field(default_factory=list)
    local_queue: dict[str, int] = field(default_factory=lambda: {
        "running": 0,
        "pending": 0,
        "foreign_running": 0,
        "foreign_pending": 0,
    })
    vram_free: int | None = None
    disk_free: dict[str, int] = field(default_factory=dict)
    downloads: list[dict[str, Any]] = field(default_factory=list)
    uptime_s: int = 0
    paused: bool = False
    accepting_reason: str | None = None
    resources: dict[str, Any] = field(default_factory=dict)
    comfyui_version: str | None = None


class StatusTracker:
    def __init__(self, config: AgentConfig, started_at: float):
        self.config = config
        self.started_at = started_at
        self.snapshot = StatusSnapshot()
        self._last_fingerprint: tuple[Any, ...] | None = None

    def fingerprint(self) -> tuple[Any, ...]:
        s = self.snapshot
        jobs = tuple((j.job_id, j.state, round(j.progress, 2), j.node) for j in s.comfier_jobs)
        return (s.state, s.accepting, s.accepting_reason, jobs, s.paused)

    def changed(self) -> bool:
        fp = self.fingerprint()
        if fp != self._last_fingerprint:
            self._last_fingerprint = fp
            return True
        return False

    async def refresh(
        self,
        comfy,
        *,
        comfier_prompt_ids: set[str],
        active_job: ComfierJobStatus | None,
        downloads: list[dict[str, Any]],
        comfy_reachable: bool,
        gpu_busy_elsewhere: bool = False,
    ) -> None:
        """`comfy` is None when this server doesn't run ComfyUI (only mflux or mlx-video)."""
        snap = self.snapshot
        snap.downloads = downloads
        snap.uptime_s = int(time.time() - self.started_at)
        snap.disk_free = disk_free_by_label(self.config)
        snap.accepting_reason = None
        snap.comfier_jobs = [active_job] if active_job else []

        if not comfy_reachable:
            snap.state = "error"
            snap.accepting = False
            snap.accepting_reason = f"ComfyUI is unreachable at {self.config.comfyui_url}"
            return

        if self.config.enabled is False or snap.paused:
            snap.state = "paused"
            snap.accepting = False
            snap.accepting_reason = "Agent is paused"
            return

        stats: dict[str, Any] = {}
        try:
            stats = await comfy.system_stats() if comfy else {}
            snap.resources = build_resources(stats, config=self.config)
            snap.comfyui_version = snap.resources.get("comfyui_version")
            devices = stats.get("devices") or []
            if devices:
                snap.vram_free = _int(devices[0].get("vram_free"))
        except Exception:
            snap.state = "error"
            snap.accepting = False
            snap.accepting_reason = "Could not read ComfyUI system stats"
            return

        disk_ok, disk_reason = disk_acceptance(self.config)

        queue = await comfy.queue() if comfy else {}
        running = queue.get("queue_running") or []
        pending = queue.get("queue_pending") or []

        def classify(items):
            comfier = 0
            foreign = 0
            for item in items:
                pid = item[1] if isinstance(item, (list, tuple)) and len(item) > 1 else None
                if pid and pid in comfier_prompt_ids:
                    comfier += 1
                else:
                    foreign += 1
            return comfier, foreign

        cr, fr = classify(running)
        cp, fp = classify(pending)
        snap.local_queue = {
            "running": cr + fr,
            "pending": cp + fp,
            "foreign_running": fr,
            "foreign_pending": fp,
        }

        if not disk_ok:
            snap.state = "disk_low"
        elif active_job:
            snap.state = "busy"
        elif gpu_busy_elsewhere:
            snap.state = "busy_local"
        elif fr > 0 or fp > 0:
            if not self.config.accept_when_local_busy:
                snap.state = "busy_local"
            else:
                snap.state = "idle"
        else:
            snap.state = "idle"

        snap.accepting = (
            disk_ok
            and self.config.enabled
            and not snap.paused
            and comfy_reachable
            and active_job is None
            and not gpu_busy_elsewhere
            and (self.config.accept_when_local_busy or (fr == 0 and fp == 0))
        )
        if not disk_ok:
            snap.accepting_reason = disk_reason
        elif snap.state == "busy_local" and gpu_busy_elsewhere:
            snap.accepting_reason = "Another program on this machine holds the GPU lock"
        elif snap.state == "busy_local":
            snap.accepting_reason = "Local ComfyUI queue has work (share queue is off)"
        elif snap.state == "busy":
            snap.accepting_reason = "Running a Comfier job"

    def mark_unresponsive(self, active_job: ComfierJobStatus | None) -> None:
        """ComfyUI didn't answer in time. While our job runs that's expected, so stay busy and keep
        the last resource figures; otherwise it's an error."""
        snap = self.snapshot
        snap.comfier_jobs = [active_job] if active_job else []
        snap.accepting = False
        if active_job:
            snap.state = "busy"
            snap.accepting_reason = "Running a Comfier job"
        else:
            snap.state = "error"
            snap.accepting_reason = "ComfyUI isn't responding"

    def to_message(self) -> dict[str, Any]:
        s = self.snapshot
        msg = {
            "type": "status",
            "state": s.state,
            "accepting": s.accepting,
            "comfier_jobs": [
                {"job_id": j.job_id, "state": j.state, "progress": j.progress, "node": j.node}
                for j in s.comfier_jobs
            ],
            "local_queue": dict(s.local_queue),
            "vram_free": s.vram_free,
            "disk_free": s.disk_free,
            "downloads": s.downloads,
            "uptime_s": s.uptime_s,
            "resources": s.resources,
            "comfyui_version": s.comfyui_version,
        }
        if s.accepting_reason:
            msg["accepting_reason"] = s.accepting_reason
        # Without ComfyUI there's no ComfyUI version or VRAM reading to send.
        return {k: v for k, v in msg.items() if not (k in ("comfyui_version", "vram_free") and v is None)}


def _int(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None
