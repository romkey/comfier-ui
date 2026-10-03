"""Optional local HTTP routes for ComfyUI settings UI."""

from __future__ import annotations

import asyncio
import logging

LOG = logging.getLogger("comfier_agent")

_runtime = None


def set_runtime(runtime) -> None:
    global _runtime
    _runtime = runtime


CONFIG_KEYS = (
    "frontend_url",
    "api_key",
    "backend_name",
    "accept_when_local_busy",
    "enabled",
    "max_concurrent_downloads",
    "use_hf_cli",
)
# Changing these means reconnecting with the new values; the rest apply on the next status update.
RECONNECT_KEYS = frozenset({"frontend_url", "api_key", "backend_name"})


def status_payload(runtime) -> dict:
    if runtime is None:
        from comfier_agent.config import load_config

        cfg = load_config()
        return {
            "state": "not_running",
            "idle_reason": cfg.idle_reason,
            "connection": {"state": "disabled", "connected": False},
            "backend_name": cfg.backend_name,
            "frontend_url": cfg.frontend_url,
            "config": cfg.public_dict(),
        }
    snap = runtime.status.snapshot
    payload = {
        "state": snap.state,
        "accepting": snap.accepting,
        "connected": runtime.connection.connected,
        "connection": runtime.connection.status_dict(),
        "backend_name": runtime.config.backend_name,
        "frontend_url": runtime.config.frontend_url,
        "resources": snap.resources,
        "comfyui_version": snap.comfyui_version,
        "disk_free": snap.disk_free,
        "config": runtime.config.public_dict(),
    }
    if snap.accepting_reason:
        payload["accepting_reason"] = snap.accepting_reason
    return payload


async def apply_config(runtime, updates: dict) -> bool:
    """Apply saved settings to the running agent. Returns True when ComfyUI must restart instead."""
    if runtime is None:
        return True
    changed = {k: v for k, v in updates.items() if not (k == "api_key" and not v)}
    for key, value in changed.items():
        if key != "enabled":
            setattr(runtime.config, key, value)
    if RECONNECT_KEYS & changed.keys():
        await run_on_agent_loop(runtime, runtime.connection.reconnect())
    return "enabled" in changed and changed["enabled"] != runtime.config.enabled


async def run_on_agent_loop(runtime, coro):
    """The agent runs on its own thread's loop inside ComfyUI; routes run on ComfyUI's."""
    loop = getattr(runtime, "loop", None)
    if loop is None or loop is asyncio.get_running_loop():
        return await coro
    return await asyncio.wrap_future(asyncio.run_coroutine_threadsafe(coro, loop))


def register_routes() -> None:
    try:
        from aiohttp import web
        from server import PromptServer
    except ImportError:
        return

    server = PromptServer.instance
    routes = server.routes

    @routes.get("/comfier-agent/status")
    async def status(_request):
        return web.json_response(status_payload(_runtime))

    @routes.post("/comfier-agent/config")
    async def save_config_route(request):
        from comfier_agent.config import load_config, save_config

        data = await request.json()
        cfg = load_config()
        updates = {k: data[k] for k in CONFIG_KEYS if k in data}
        save_config(cfg, updates)
        restart_needed = await apply_config(_runtime, updates)
        return web.json_response({
            "ok": True,
            "config": load_config().public_dict(),
            "restart_needed": restart_needed,
        })

    if not getattr(server, "comfier_cleanup_route", False):

        @routes.post("/comfier/cleanup")
        async def comfier_cleanup(request):
            from comfier_agent.cleanup import delete_file, delete_input_image

            data = await request.json()
            deleted = []
            skipped = []
            for file_desc in data.get("files") or []:
                if not isinstance(file_desc, dict):
                    continue
                filename = file_desc.get("filename")
                if not filename:
                    continue
                if delete_file(filename, file_desc.get("subfolder", ""), file_desc.get("type", "output")):
                    deleted.append(filename)
                else:
                    skipped.append(filename)
            input_image = data.get("input_image")
            if input_image:
                (deleted if delete_input_image(input_image) else skipped).append(input_image)
            prompt_id = data.get("prompt_id")
            if prompt_id:
                server.prompt_queue.delete_history_item(prompt_id)
            return web.json_response({"deleted": deleted, "skipped": skipped})

        server.comfier_cleanup_route = True
