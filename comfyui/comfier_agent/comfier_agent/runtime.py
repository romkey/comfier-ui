"""Agent asyncio runtime."""

from __future__ import annotations

import asyncio
import logging
import platform
import sys
import time
from typing import Any

from comfier_agent import __version__
from comfier_agent.comfy_client import ComfyClient
from comfier_agent.config import AgentConfig
from comfier_agent.connection import FrontendConnection
from comfier_agent.inventory import inventory_message, scan_inventory
from comfier_agent.jobs import JobManager, sweep_stale_inputs
from comfier_agent.models import ModelDownloadManager
from comfier_agent.protocol import PROTOCOL_VERSION, encode_object_info
from comfier_agent.resources import build_resources
from comfier_agent.status import StatusTracker

LOG = logging.getLogger("comfier_agent")
# Well under Comfier's 30 s offline window, so a slow ComfyUI never holds up the heartbeat.
STATUS_REFRESH_TIMEOUT_S = 5


class AgentRuntime:
    def __init__(self, config: AgentConfig):
        self.config = config
        self.started_at = time.time()
        self.comfy = ComfyClient(config.comfyui_url)
        self.connection = FrontendConnection(config)
        self.status = StatusTracker(config, self.started_at)
        self.inventory = None
        self.jobs: JobManager | None = None
        self.models: ModelDownloadManager | None = None
        self._tasks: list[asyncio.Task] = []
        self._comfy_ok = False
        self.loop: asyncio.AbstractEventLoop | None = None

    async def run(self, *, sidecar: bool = False) -> None:
        self.loop = asyncio.get_running_loop()
        await self.comfy.start()
        if sidecar:
            await self._wait_comfy_forever()
        else:
            try:
                await asyncio.wait_for(self.comfy.wait_ready(), timeout=120)
                self._comfy_ok = True
            except asyncio.TimeoutError:
                LOG.warning("ComfyUI not ready after 120s; continuing in error state")

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
        )
        self.models = ModelDownloadManager(self.config, self.comfy.session, send, self._rescan_inventory)

        from comfier_agent.models import sweep_stale_part_files

        sweep_stale_part_files(self.config)

        await self.connection.start(self._on_frontend_message)
        self._tasks = [
            asyncio.create_task(self._heartbeat_loop()),
            asyncio.create_task(self._inventory_loop()),
            asyncio.create_task(self._sweep_loop()),
        ]
        await self.comfy.ensure_ws()
        while True:
            await asyncio.sleep(3600)

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        await self.connection.close()
        await self.comfy.close()

    async def _wait_comfy_forever(self) -> None:
        while True:
            try:
                await self.comfy.wait_ready(timeout=3600)
                self._comfy_ok = True
                return
            except asyncio.TimeoutError:
                self._comfy_ok = False

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
                "devices": stats.get("devices") or [],
            },
            "active_jobs": self.jobs.active_jobs_for_hello() if self.jobs else [],
            "active_downloads": self.models.active_for_hello() if self.models else [],
            "model_downloads_enabled": self.config.allow_model_downloads,
            "max_concurrent_downloads": self.config.max_concurrent_downloads,
            "use_hf_cli": self.config.use_hf_cli,
            "engines": {name: engine.info() for name, engine in self.jobs.engines.items()} if self.jobs else {},
        }
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
            snap = await scan_inventory(self.comfy, self.jobs.engines if self.jobs else None)
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
            self._comfy_ok = True
            await asyncio.wait_for(
                self.status.refresh(
                    self.comfy,
                    comfier_prompt_ids=self.jobs.prompt_ids if self.jobs else set(),
                    active_job=active_job,
                    downloads=self.models.status_entries() if self.models else [],
                    comfy_reachable=self._comfy_ok,
                ),
                timeout=STATUS_REFRESH_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            # ComfyUI can take minutes to answer mid-step. Comfier drops a server that goes ~30 s
            # without a status, so report what we know rather than wait.
            LOG.info("ComfyUI took over %ss to report its status", STATUS_REFRESH_TIMEOUT_S)
            self.status.mark_unresponsive(active_job)
        except Exception:
            self._comfy_ok = False
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
            await asyncio.sleep(3600)


async def run_agent(config: AgentConfig, *, sidecar: bool = False) -> None:
    runtime = AgentRuntime(config)
    await runtime.run(sidecar=sidecar)
