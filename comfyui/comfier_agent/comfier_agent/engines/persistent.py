"""Lifecycle for a persistent GPU worker, including serialized idle unloading."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from typing import Any

from comfier_agent.engines.base import JobContext
from comfier_agent.engines.mlx import ChildProcess, MlxEngine

LOG = logging.getLogger("comfier_agent")


class PersistentWorkerEngine(MlxEngine):
    def __init__(self, config, worker_argv):
        super().__init__(config)
        self.worker_argv = worker_argv
        self.worker = ChildProcess(self.name)
        self.events: asyncio.Queue[tuple[int, dict[str, Any]]] = asyncio.Queue()
        self._generation = 0
        self._reader: asyncio.Task | None = None
        self._idle_task: asyncio.Task | None = None
        self._lock = asyncio.Lock()

    @property
    def idle_unload_minutes(self):
        return self.config.mlx_idle_unload_minutes

    async def cancel(self, ctx: JobContext) -> bool:
        await self._stop_worker()
        return False

    async def free_memory(self) -> None:
        self._cancel_idle_unload()
        await self._stop_worker()

    async def close(self) -> None:
        await self.free_memory()

    async def _stop_worker(self) -> None:
        await self.worker.stop()
        if self.worker.proc is not None:
            if self.worker.proc.stdin is not None:
                self.worker.proc.stdin.close()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    await self.worker.proc.stdin.wait_closed()
            await self.worker.wait()
        if self._reader is not None:
            await self._reader
            self._reader = None

    async def _ensure_worker(self, *, env: dict[str, str] | None = None) -> None:
        if self.worker.running:
            return
        await self._stop_worker()
        await self.worker.start(self.worker_argv, stdin=True, stdout=True, env=env)
        self._generation += 1
        self._reader = asyncio.create_task(self._read_events(self.worker.proc, self._generation))

    async def _read_events(self, proc, generation: int) -> None:
        async for raw in proc.stdout:
            try:
                await self.events.put((generation, json.loads(raw)))
            except json.JSONDecodeError:
                LOG.debug("%s worker: %s", self.name, raw.decode(errors="replace").rstrip())
        await self.events.put((generation, {"event": "exit", "code": await proc.wait()}))

    async def _send(self, message: dict[str, Any]) -> None:
        self.worker.proc.stdin.write((json.dumps(message) + "\n").encode())
        await self.worker.proc.stdin.drain()

    def _schedule_idle_unload(self) -> None:
        minutes = self.idle_unload_minutes
        self._cancel_idle_unload()
        if minutes <= 0:
            return

        async def unload_later() -> None:
            await asyncio.sleep(minutes * 60)
            async with self._lock:
                self._idle_task = None
                LOG.info("%s idle for %s min; unloading its models", self.name, minutes)
                await self._stop_worker()

        self._idle_task = asyncio.create_task(unload_later())

    def _cancel_idle_unload(self) -> None:
        """Called before a job takes the lock; an unload already under way finishes first."""
        if self._idle_task and not self._idle_task.done() and not self._lock.locked():
            self._idle_task.cancel()
        self._idle_task = None
