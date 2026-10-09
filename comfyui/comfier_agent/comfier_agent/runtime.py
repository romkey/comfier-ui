"""Agent asyncio runtime."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import platform
import sys
import time
from typing import Any

from comfier_agent import __version__
from comfier_agent.comfy_client import ComfyClient
from comfier_agent.config import AgentConfig
from comfier_agent.connection import FrontendConnection
from comfier_agent.engines import build_engines
from comfier_agent.gpu_lock import GpuLock
from comfier_agent.inventory import inventory_message, scan_inventory
from comfier_agent.jobs import JobManager, sweep_stale_inputs, sweep_stale_work
from comfier_agent.models import ModelDownloadManager
from comfier_agent.protocol import PROTOCOL_VERSION, encode_object_info
from comfier_agent.resources import build_resources
from comfier_agent.status import StatusTracker

LOG = logging.getLogger("comfier_agent")
# Well under Comfier's 30 s offline window, so a slow ComfyUI never holds up the heartbeat.
STATUS_REFRESH_TIMEOUT_S = 5
# How often the agent checks on ComfyUI while it's down, and while it's up.
COMFY_RETRY_S = 5
COMFY_CHECK_S = 15
# ComfyUI is only taken as gone after this many refused connections in a row; a busy ComfyUI that's
# slow to answer mid-step isn't gone.
COMFY_DOWN_AFTER = 3


class AgentRuntime:
    def __init__(self, config: AgentConfig):
        self.config = config
        self.started_at = time.time()
        self.comfy = ComfyClient(config.comfyui_url or "")
        self.engines = build_engines(config, self.comfy)
        # Without ComfyUI (an mflux/mlx-video-only Mac) there's nothing to wait for or poll.
        self.uses_comfy = "comfyui" in self.engines
        self.gpu_lock = GpuLock(config.gpu_lock_path, enabled=config.gpu_lock)
        self.connection = FrontendConnection(config)
        self.status = StatusTracker(config, self.started_at)
        self.inventory = None
        self.jobs: JobManager | None = None
        self.models: ModelDownloadManager | None = None
        self._tasks: list[asyncio.Task] = []
        self._comfy_ok = False
        self._comfy_failures = 0
        self.loop: asyncio.AbstractEventLoop | None = None

    @property
    def comfy_ready(self) -> bool:
        return self.uses_comfy and self._comfy_ok

    def engine_available(self, name: str) -> bool:
        return name in self.engines and (name != "comfyui" or self.comfy_ready)

    def available_engines(self) -> dict:
        """What this server can run right now: ComfyUI drops out while it's unreachable."""
        return {name: engine for name, engine in self.engines.items() if self.engine_available(name)}

    async def run(self, *, sidecar: bool = False) -> None:
        self.loop = asyncio.get_running_loop()
        await self.comfy.start()
        if self.uses_comfy and not sidecar:
            # Inside ComfyUI it's still starting up in this same process; give it a moment.
            try:
                await asyncio.wait_for(self.comfy.wait_ready(), timeout=120)
                self._comfy_ok = True
            except asyncio.TimeoutError:
                LOG.warning("ComfyUI not ready after 120s; connecting anyway")
        elif self.uses_comfy:
            # A standalone agent asks once but never waits for ComfyUI before connecting: it would look
            # offline, and mflux and mlx-video jobs don't need it. The watch loop picks it up later.
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.comfy.system_stats(), STATUS_REFRESH_TIMEOUT_S)
                self._comfy_ok = True
            if not self._comfy_ok:
                LOG.warning("ComfyUI isn't answering at %s; connecting without it", self.config.comfyui_url)

        async def send(msg: dict) -> None:
            await self.connection.send(msg)

        async def after_job_terminal() -> None:
            await self._publish_status(force=True)
            await self._rescan_inventory(force=False)
            if self.jobs and self.status.snapshot.accepting:
                await self.jobs.maybe_job_request(True)

        self.jobs = JobManager(
            self.config,
            self.comfy,
            send,
            lambda: self.inventory,
            on_terminal=after_job_terminal,
            engines=self.engines,
            gpu_lock=self.gpu_lock,
            engine_available=self.engine_available,
        )
        self.models = ModelDownloadManager(self.config, self.comfy.session, send, self._rescan_inventory,
                                           engines=self.engines)

        from comfier_agent.models import sweep_stale_part_files

        sweep_stale_part_files(self.config)
        # So the first hello already carries each engine's version.
        for engine in self.engines.values():
            await engine.refresh()

        await self.connection.start(self._on_frontend_message)
        self._tasks = [
            asyncio.create_task(self._heartbeat_loop()),
            asyncio.create_task(self._inventory_loop()),
            asyncio.create_task(self._sweep_loop()),
        ]
        if self.uses_comfy:
            self._tasks.append(asyncio.create_task(self._comfy_watch_loop()))
        if self.comfy_ready:
            await self.comfy.ensure_ws()
        while True:
            await asyncio.sleep(3600)

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        await self.connection.close()
        for engine in self.engines.values():
            await engine.close()
        self.gpu_lock.release()
        await self.comfy.close()

    async def _comfy_watch_loop(self) -> None:
        while True:
            await asyncio.sleep(COMFY_CHECK_S if self._comfy_ok else COMFY_RETRY_S)
            await self._check_comfy()

    async def _check_comfy(self) -> None:
        try:
            await asyncio.wait_for(self.comfy.system_stats(), STATUS_REFRESH_TIMEOUT_S)
            reachable = True
        except asyncio.TimeoutError:
            return  # busy, not gone
        except Exception:
            reachable = False
        self._comfy_failures = 0 if reachable else self._comfy_failures + 1
        if reachable and not self._comfy_ok:
            LOG.info("ComfyUI is reachable at %s", self.config.comfyui_url)
            await self._set_comfy_ok(True)
        elif self._comfy_ok and self._comfy_failures >= COMFY_DOWN_AFTER:
            LOG.warning("ComfyUI stopped answering at %s; taking only %s jobs", self.config.comfyui_url,
                        ", ".join(n for n in self.engines if n != "comfyui") or "no")
            await self._set_comfy_ok(False)

    async def _set_comfy_ok(self, ok: bool) -> None:
        self._comfy_ok = ok
        if ok:
            with contextlib.suppress(Exception):
                await self.comfy.ensure_ws()
        # The engines this server reports changed, so Comfier routes ComfyUI jobs accordingly.
        await self._rescan_inventory(force=True)
        await self._publish_status(force=True)

    async def _on_frontend_message(self, msg: dict[str, Any]) -> None:
        typ = msg.get("type")
        if typ == "_connected":
            if self.jobs:
                # The frontend forgets open requests on every hello.
                self.jobs.void_request()
            await self._send_hello()
            await self._rescan_inventory(force=True)
            await self._publish_status(force=True)
            if self.jobs and self.status.snapshot.accepting:
                await self.jobs.maybe_job_request(True)
            return
        if typ == "job.assign" and self.jobs:
            await self.jobs.handle_assign(
                msg,
                accepting=self.status.snapshot.accepting,
                inventory=self.inventory,
                accepting_reason=self.status.snapshot.accepting_reason,
            )
            await self._publish_status(force=True)
            if self.status.snapshot.accepting:
                await self.jobs.maybe_job_request(True)
        elif typ == "job.cancel" and self.jobs:
            await self.jobs.handle_cancel(msg["job_id"])
            await self._publish_status(force=True)
        elif typ == "object_info.request":
            await self._send_object_info()
        elif typ == "inventory.refresh":
            await self._rescan_inventory(force=True)
        elif typ == "model.download" and self.models:
            await self.models.handle(msg)
        elif typ == "model.download.cancel" and self.models:
            await self.models.cancel(msg["download_id"])
        elif typ == "config.pause":
            self.status.snapshot.paused = True
            await self._publish_status(force=True)
        elif typ == "config.resume":
            self.status.snapshot.paused = False
            await self._publish_status(force=True)
        else:
            if typ not in (None,):
                LOG.info("ignored message type %s", typ)

    async def _send_hello(self) -> None:
        stats = {}
        try:
            if self.comfy_ready:
                stats = await self.comfy.system_stats()
        except Exception:
            pass
        resources = self.status.snapshot.resources or build_resources(stats, config=self.config)
        msg = {
            "type": "hello",
            "protocol": PROTOCOL_VERSION,
            "agent_version": __version__,
            "backend_name": self.config.backend_name,
            "comfyui_version": resources.get("comfyui_version"),
            "resources": resources,
            "system": {
                "os": platform.platform(),
                "python": sys.version.split()[0],
                "devices": stats.get("devices") or resources.get("gpus") or [],
            },
            "active_jobs": self.jobs.active_jobs_for_hello() if self.jobs else [],
            "active_downloads": self.models.active_for_hello() if self.models else [],
            "model_downloads_enabled": self.config.allow_model_downloads,
            "max_concurrent_downloads": self.config.max_concurrent_downloads,
            "use_hf_cli": self.config.use_hf_cli,
            "engines": {name: engine.info() for name, engine in self.available_engines().items()},
        }
        if msg["comfyui_version"] is None:
            del msg["comfyui_version"]
        await self.connection.send(msg)

    async def _send_object_info(self) -> None:
        if not (self.inventory and self.inventory.object_info):
            return
        try:
            chunks = encode_object_info(self.inventory.object_info, self.inventory.object_info_hash)
        except ValueError as exc:
            LOG.warning("not sending object_info: %s", exc)
            return
        for chunk in chunks:
            await self.connection.send(chunk)

    async def _rescan_inventory(self, force: bool = False) -> None:
        try:
            for engine in self.engines.values():
                await engine.refresh()
            # While ComfyUI is down its last models and nodes stay reported; only the engines change.
            previous = self.inventory if self.uses_comfy and not self.comfy_ready else None
            snap = await scan_inventory(self.comfy if self.comfy_ready else None, self.available_engines(), previous)
        except Exception as exc:
            LOG.warning("inventory scan failed: %s", exc)
            return
        if self.inventory and not force and snap.hash == self.inventory.hash:
            self.inventory = snap
            return
        self.inventory = snap
        inv = inventory_message(snap)
        self.connection.set_latest_inventory(inv)
        await self.connection.send(inv)

    async def _publish_status(self, force: bool = False) -> None:
        accepting_before = self.status.snapshot.accepting
        active_job = self.jobs.active_job_status() if self.jobs else None
        try:
            await asyncio.wait_for(
                self.status.refresh(
                    self.comfy if self.comfy_ready else None,
                    comfier_prompt_ids=self.jobs.prompt_ids if self.jobs else set(),
                    active_job=active_job,
                    downloads=self.models.status_entries() if self.models else [],
                    # Only an error when ComfyUI is all this server runs.
                    comfy_reachable=bool(self.available_engines()),
                    gpu_busy_elsewhere=self.gpu_lock.held_elsewhere(),
                ),
                timeout=STATUS_REFRESH_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            # ComfyUI can take minutes to answer mid-step. Comfier drops a server that goes ~30 s
            # without a status, so report what we know rather than wait.
            LOG.info("ComfyUI took over %ss to report its status", STATUS_REFRESH_TIMEOUT_S)
            self.status.mark_unresponsive(active_job)
        except Exception:
            LOG.warning("couldn't refresh status", exc_info=True)
            self.status.snapshot.state = "error"
            self.status.snapshot.accepting = False

        if force or self.status.changed():
            msg = self.status.to_message()
            self.connection.set_latest_status(msg)
            await self.connection.send(msg)
            accepting_after = self.status.snapshot.accepting
            if accepting_after and not accepting_before and self.jobs:
                await self.jobs.maybe_job_request(True)
            if not accepting_after and accepting_before and self.jobs:
                self.jobs.void_request()

    async def _heartbeat_loop(self) -> None:
        while True:
            if self.connection.connected:
                # Comfier expires presence after ~30s without a status; send every heartbeat even
                # when the snapshot fingerprint is unchanged.
                await self._publish_status(force=True)
            await asyncio.sleep(self.config.heartbeat_seconds)

    async def _inventory_loop(self) -> None:
        while True:
            await asyncio.sleep(self.config.inventory_poll_seconds)
            await self._rescan_inventory(force=False)

    async def _sweep_loop(self) -> None:
        while True:
            sweep_stale_inputs(self.config)
            sweep_stale_work(self.config)
            await asyncio.sleep(3600)


async def run_agent(config: AgentConfig, *, sidecar: bool = False) -> None:
    runtime = AgentRuntime(config)
    await runtime.run(sidecar=sidecar)
