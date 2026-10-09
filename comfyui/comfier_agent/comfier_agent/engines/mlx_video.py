"""Runs video jobs with mlx-video (LTX-2, Wan2.1/2.2), one process per job.

mlx-video's Python API changes too often to drive directly, so each job runs its command-line tool,
whose flags the recipe uses. That costs a model load per job, which is small next to a video's
generation time. Progress is read from the tool's progress bars."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import sys
import time
from typing import Any

from comfier_agent.engines.base import JobCancelled, JobContext, JobError, ProgressFn
from comfier_agent.engines.mlx import ChildProcess, MlxEngine, recipe_argv

LOG = logging.getLogger("comfier_agent")

PROBE_TIMEOUT_S = 120
PROBE_MAX_AGE_S = 600
POLL_S = 0.5
PERCENT = re.compile(r"(\d{1,3})%")
COUNT = re.compile(r"(\d+)\s*/\s*(\d+)")
# Lines from the denoising loop; other bars (downloads, decoding, frame streaming) don't count.
DENOISING = re.compile(r"denois|sampling|step", re.I)
LOADING = re.compile(r"load|download|fetch", re.I)


def default_runner_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.entry_point"]


def default_probe_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.mlx_video_probe"]


def denoising_fraction(line: str) -> float | None:
    if not DENOISING.search(line):
        return None
    if match := PERCENT.search(line):
        return min(int(match.group(1)), 100) / 100
    if (match := COUNT.search(line)) and int(match.group(2)):
        return min(int(match.group(1)) / int(match.group(2)), 1.0)
    return None


class MlxVideoEngine(MlxEngine):
    name = "mlx_video"
    command = re.compile(r"^mlx_video(\.[a-z0-9_]+)+$")

    def __init__(self, config, runner_argv: list[str] | None = None, probe_argv: list[str] | None = None):
        super().__init__(config)
        self.runner_argv = runner_argv or default_runner_argv()
        self.probe_argv = probe_argv or default_probe_argv()
        self.process: ChildProcess | None = None
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

        self.process = ChildProcess("mlx-video", on_line=on_line)
        argv = [*self.runner_argv, workflow["command"], *recipe_argv(workflow), "--output-path", str(out)]
        ctx.timings.mark_prompt()
        await self.process.start(argv, merged=True)
        ctx.phase = "loading_model"
        await progress(ctx, "loading_model", 0.0)
        try:
            await self._follow(ctx, state, timeout_s=timeout_s, progress=progress)
        finally:
            await self.process.stop()
        ctx.timings.mark_execution_end()
        self._refreshed_at = None  # the job may have downloaded a model
        return self.outputs(ctx, out)

    async def _follow(self, ctx: JobContext, state: dict, *, timeout_s: int, progress: ProgressFn) -> None:
        # Loading (and a first download) has its own limit; the job's starts at the first denoising step.
        deadline = time.monotonic() + self.config.mlx_load_timeout_s
        wait = asyncio.ensure_future(self.process.wait())
        try:
            while True:
                if ctx.cancel_requested:
                    await self.process.stop()
                    raise JobCancelled()
                if time.monotonic() >= deadline:
                    await self.process.stop()
                    reason = "timeout" if ctx.phase == "running" else "loading the model took too long"
                    raise JobError("execute", reason)
                if state["denoising"] and ctx.phase != "running":
                    ctx.phase = "running"
                    ctx.timings.mark_execution_start()
                    deadline = time.monotonic() + timeout_s
                if ctx.phase == "running":
                    await progress(ctx, "running", min(0.99, state["fraction"] or 0.0))
                done, _ = await asyncio.wait({wait}, timeout=POLL_S)
                if done:
                    break
        finally:
            if not wait.done():
                wait.cancel()
        code = wait.result()
        if ctx.cancel_requested:
            raise JobCancelled()
        if code != 0:
            raise JobError("execute", f"mlx-video exited with code {code}: {self.process.tail()}",
                           traceback_tail=self.process.tail(30))

    async def cancel(self, ctx: JobContext) -> bool:
        if self.process:
            await self.process.stop()
        return False

    async def free_memory(self) -> None:
        # Nothing stays loaded between jobs.
        return None

    async def close(self) -> None:
        if self.process:
            await self.process.stop()
