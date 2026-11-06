"""Runs image jobs with mflux in a worker process that keeps the last model loaded."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import sys
import time
from typing import Any

from comfier_agent.engines.base import JobCancelled, JobContext, JobError, ProgressFn
from comfier_agent.engines.mlx import ChildProcess, recipe_argv
from comfier_agent.engines.persistent import PersistentWorkerEngine

LOG = logging.getLogger("comfier_agent")

WORKER_MODULE = "comfier_agent.workers.mflux_worker"
INVENTORY_TIMEOUT_S = 120
# Reading the inventory means importing mflux in a new process, so it's not done every inventory poll.
INVENTORY_MAX_AGE_S = 600
POLL_S = 0.5


def default_worker_argv() -> list[str]:
    return [sys.executable, "-m", WORKER_MODULE]


class MfluxEngine(PersistentWorkerEngine):
    name = "mflux"
    command = re.compile(r"^mflux-generate[a-z0-9.-]*$")

    def __init__(self, config, worker_argv: list[str] | None = None):
        super().__init__(config, worker_argv or default_worker_argv())
        # Model alias -> the Hugging Face repo holding its weights, from the inventory.
        self.repos: dict[str, str] = {}

    async def refresh(self) -> None:
        """Version and the models already downloaded, from a short-lived process so a running job and
        the loaded model are left alone. At most every INVENTORY_MAX_AGE_S, or after a job."""
        if self._refreshed_at and time.monotonic() - self._refreshed_at < INVENTORY_MAX_AGE_S:
            return
        probe = ChildProcess("mflux inventory")
        try:
            await probe.start([*self.worker_argv, "--inventory"], stdout=True)
            out = await asyncio.wait_for(probe.proc.stdout.read(), INVENTORY_TIMEOUT_S)
            await probe.wait()
            data = json.loads(out.decode().strip().splitlines()[-1])
        except Exception as exc:
            await probe.stop()
            LOG.warning("couldn't read mflux's models: %s %s", exc, probe.tail(3))
            return
        finally:
            # Inventory scans can be cancelled during shutdown while the probe is still importing.
            await probe.stop()
            if probe.proc is not None:
                await probe.wait()
        self.version = data.get("version") or self.version
        self.models = sorted(data.get("models") or [])
        self.extra_info = {"catalog": sorted(data.get("catalog") or [])}
        self.repos = dict(data.get("repos") or {})
        self._refreshed_at = time.monotonic()

    async def repos_for(self, model: str) -> list[str]:
        if model not in self.repos:
            self._refreshed_at = None
            await self.refresh()
        repo = self.repos.get(model)
        return [repo] if repo else []

    async def execute(self, ctx: JobContext, workflow: Any, *, timeout_s: int, progress: ProgressFn) -> list[dict]:
        self._cancel_idle_unload()
        out = self.job_dir(ctx) / f"mflux_{ctx.job_id}.png"
        request = {"op": "generate", "id": ctx.job_id, "command": workflow["command"],
                   "argv": recipe_argv(workflow), "output": str(out)}
        try:
            async with self._lock:
                await self._ensure_worker()
                await self._send(request)
                ctx.timings.mark_prompt()
                ctx.phase = "loading_model"
                await progress(ctx, "loading_model", 0.0)
                await self._follow(ctx, timeout_s=timeout_s, progress=progress)
        finally:
            # After a failure too: an errored worker keeps its model until something unloads it.
            self._schedule_idle_unload()
            self._refreshed_at = None  # the job may have downloaded a model
        return self.outputs(ctx, out)

    async def _follow(self, ctx: JobContext, *, timeout_s: int, progress: ProgressFn) -> None:
        # Loading may include downloading the model, so the job's time limit starts once it's loaded.
        deadline = time.monotonic() + self.config.mlx_load_timeout_s
        while True:
            if ctx.cancel_requested:
                await self._stop_worker()
                raise JobCancelled()
            if time.monotonic() >= deadline:
                await self._stop_worker()
                stage = "timeout" if ctx.phase == "running" else "loading the model took too long"
                raise JobError("execute", stage)
            try:
                generation, event = await asyncio.wait_for(self.events.get(), POLL_S)
            except asyncio.TimeoutError:
                continue
            if generation != self._generation:
                continue
            kind = event.get("event")
            if kind == "loading" and event.get("includes_generation"):
                # main() loads and generates in one go, so allow for both.
                deadline += timeout_s
            elif kind == "loaded":
                ctx.phase = "running"
                ctx.timings.mark_execution_start()
                deadline = time.monotonic() + timeout_s
                await progress(ctx, "running", 0.0)
            elif kind == "progress":
                total = event.get("total") or 0
                fraction = min(0.99, event["step"] / total) if total else 0.5
                await progress(ctx, "running", fraction)
            elif kind == "done":
                ctx.timings.mark_execution_end()
                return
            elif kind == "error":
                message = event.get("message") or "mflux failed"
                if event.get("type") == "InvalidOptions":
                    await asyncio.sleep(0.2)  # argparse's reason is on stderr, a moment behind
                    reason = next((line for line in reversed(self.worker.stderr_tail) if "error:" in line), None)
                    message = f"{message}: {reason.split('error:', 1)[1].strip()}" if reason else message
                raise JobError("execute", message, exception_type=event.get("type"),
                               traceback_tail=event.get("traceback"))
            elif kind == "exit":
                if ctx.cancel_requested:
                    raise JobCancelled()
                detail = self.worker.tail() or f"exit code {event.get('code')}"
                raise JobError("execute", f"mflux stopped unexpectedly: {detail}")

    def download_argv(self, model: str) -> list[str]:
        return [*self.worker_argv, "--download", model]
