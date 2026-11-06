"""Video jobs in a persistent worker, with cached weights and an idle unload timer."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Any

from comfier_agent.engines.base import JobCancelled, JobContext, JobError, ProgressFn
from comfier_agent.engines.mlx import ChildProcess, recipe_argv
from comfier_agent.engines.persistent import PersistentWorkerEngine
from comfier_agent.workers.entry_point import QUANTIZE_ENV

LOG = logging.getLogger("comfier_agent")

PROBE_TIMEOUT_S = 120
FASTSTART_TIMEOUT_S = 300
PROBE_MAX_AGE_S = 600
POLL_S = 0.5
PERCENT = re.compile(r"(\d{1,3})%")
COUNT = re.compile(r"(\d+)\s*/\s*(\d+)")
# Lines from the denoising loop; other bars (downloads, decoding, frame streaming) don't count.
DENOISING = re.compile(r"denois|sampling|step", re.I)
LOADING = re.compile(r"load|download|fetch", re.I)


def default_runner_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.video_worker"]


def default_probe_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.mlx_video_probe"]


def default_download_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.hf_download"]


async def faststart(path: Path) -> bool:
    """Moves the MP4's index (moov) ahead of the media so browsers can start playing before the whole file has
    arrived. mlx-video writes it at the end. Only the container changes; the picture and sound are copied. The file
    is left as it was when ffmpeg is missing or fails, and Comfier fixes it on arrival instead."""
    ffmpeg = shutil.which(os.environ.get("FFMPEG", "ffmpeg"))
    if not ffmpeg or not path.is_file():
        return False
    tmp = path.with_name(f"{path.stem}.faststart{path.suffix}")
    try:
        proc = await asyncio.create_subprocess_exec(
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(path), "-map", "0", "-c", "copy",
            "-movflags", "+faststart", str(tmp),
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        _out, err = await asyncio.wait_for(proc.communicate(), FASTSTART_TIMEOUT_S)
    except (OSError, asyncio.TimeoutError) as exc:
        LOG.warning("couldn't move %s's index to the front: %s", path.name, exc)
        tmp.unlink(missing_ok=True)
        return False
    if proc.returncode != 0 or not tmp.is_file() or tmp.stat().st_size == 0:
        LOG.warning("couldn't move %s's index to the front: %s", path.name,
                    (err or b"").decode(errors="replace").strip().splitlines()[-1:] or "ffmpeg failed")
        tmp.unlink(missing_ok=True)
        return False
    tmp.replace(path)
    return True


def quantize_bits(value: Any) -> str:
    """A recipe's "quantize" as the entry point reads it: "8" for 8 or 8.0, "" for none."""
    try:
        return str(int(float(value))) if value else ""
    except (TypeError, ValueError):
        return ""


def denoising_fraction(line: str) -> float | None:
    if not DENOISING.search(line):
        return None
    if match := PERCENT.search(line):
        return min(int(match.group(1)), 100) / 100
    if (match := COUNT.search(line)) and int(match.group(2)):
        return min(int(match.group(1)) / int(match.group(2)), 1.0)
    return None


class MlxVideoEngine(PersistentWorkerEngine):
    name = "mlx_video"
    command = re.compile(r"^mlx_video(\.[a-z0-9_]+)+$")

    def __init__(self, config, runner_argv: list[str] | None = None, probe_argv: list[str] | None = None,
                 download_argv: list[str] | None = None):
        super().__init__(config, worker_argv=runner_argv or default_runner_argv())
        self.runner_argv = runner_argv or default_runner_argv()
        self.probe_argv = probe_argv or default_probe_argv()
        self._download_argv = download_argv or default_download_argv()
        self.process = self.worker
        self.worker.name = "mlx-video"
        self._model_key = None
        self._refreshed_at: float | None = None

    async def refresh(self) -> None:
        if self._refreshed_at and time.monotonic() - self._refreshed_at < PROBE_MAX_AGE_S:
            return
        probe = ChildProcess("mlx-video inventory")
        try:
            await probe.start(self.probe_argv, stdout=True)
            out = await asyncio.wait_for(probe.proc.stdout.read(), PROBE_TIMEOUT_S)
            await probe.wait()
            data = json.loads(out.decode().strip().splitlines()[-1])
        except Exception as exc:
            await probe.stop()
            LOG.warning("couldn't read mlx-video's models: %s %s", exc, probe.tail(3))
            return
        finally:
            # Inventory scans can be cancelled during shutdown while the probe is still importing.
            await probe.stop()
            if probe.proc is not None:
                await probe.wait()
        self.version = data.get("version") or self.version
        self.models = sorted(data.get("models") or [])
        self._refreshed_at = time.monotonic()

    async def execute(self, ctx: JobContext, workflow: Any, *, timeout_s: int, progress: ProgressFn) -> list[dict]:
        out = self.job_dir(ctx) / f"mlx_video_{ctx.job_id}.mp4"
        state = {"fraction": None, "denoising": False}

        def on_line(line: str) -> None:
            fraction = denoising_fraction(line)
            if fraction is not None:
                state["fraction"], state["denoising"] = fraction, True

        self._cancel_idle_unload()
        # Unknown options conservatively invalidate the worker too. Only job inputs and sampling
        # options known not to select or mutate weights may change while keeping a warm model.
        transient = {"prompt", "negative_prompt", "seed", "width", "height", "num_frames", "fps",
                     "image", "end_image", "audio_file", "audio_start_time", "steps", "min_memory_gb"}
        key = json.dumps({k: v for k, v in workflow.items() if k not in transient}, sort_keys=True)
        options = {k: v for k, v in workflow.items() if k != "quantize"}
        ctx.timings.mark_prompt()
        try:
            async with self._lock:
                if self._model_key != key:
                    await self._stop_worker()
                    self._model_key = key
                self.worker.on_line = on_line
                # Always override a parent's quantization setting, including for full precision.
                await self._ensure_worker(env={QUANTIZE_ENV: quantize_bits(workflow.get("quantize"))})
                await self._send({"op": "generate", "id": ctx.job_id, "command": workflow["command"],
                                  "argv": recipe_argv(options), "output": str(out)})
                ctx.phase = "loading_model"
                await progress(ctx, "loading_model", 0.0)
                await self._follow(ctx, state, timeout_s=timeout_s, progress=progress)
        except BaseException:
            # A failed or cancelled pipeline may have partially mutated weights.
            await self._stop_worker()
            raise
        finally:
            self.worker.on_line = None
            if self.worker.running:
                self._schedule_idle_unload()
            self._refreshed_at = None
        ctx.timings.mark_execution_end()
        await faststart(out)
        return self.outputs(ctx, out)

    async def _follow(self, ctx: JobContext, state: dict, *, timeout_s: int, progress: ProgressFn) -> None:
        # Loading (and a first download) has its own limit; the job's starts at the first denoising step.
        deadline = time.monotonic() + self.config.mlx_load_timeout_s
        while True:
            if ctx.cancel_requested:
                raise JobCancelled()
            if time.monotonic() >= deadline:
                reason = "timeout" if ctx.phase == "running" else "loading the model took too long"
                raise JobError("execute", reason)
            if state["denoising"] and ctx.phase != "running":
                ctx.phase = "running"
                ctx.timings.mark_execution_start()
                deadline = time.monotonic() + timeout_s
            if ctx.phase == "running":
                await progress(ctx, "running", min(0.99, state["fraction"] or 0.0))
            try:
                generation, event = await asyncio.wait_for(self.events.get(), POLL_S)
            except asyncio.TimeoutError:
                continue
            if generation != self._generation:
                continue
            if ctx.cancel_requested:
                raise JobCancelled()
            if event.get("id") not in (None, ctx.job_id):
                continue
            if event.get("event") == "done":
                return
            if event.get("event") in ("error", "exit"):
                raise JobError("execute", f"mlx-video failed: {event.get('message') or ''}: {self.worker.tail()}",
                               traceback_tail=event.get("traceback"))

    def download_argv(self, model: str) -> list[str]:
        # mlx-video recipes name a Hugging Face repo (model_repo); it's fetched whole, as mlx-video would.
        return [*self._download_argv, model]

    async def repos_for(self, model: str) -> list[str]:
        return [model]

    @property
    def idle_unload_minutes(self):
        return self.config.mlx_video_idle_unload_minutes
