"""Fake ComfyUI HTTP + WebSocket server for tests."""

from __future__ import annotations

import asyncio
import json
from typing import Any

from aiohttp import web


class FakeComfy:
    def __init__(self):
        self.app = web.Application()
        self.app.router.add_get("/system_stats", self.system_stats)
        self.app.router.add_get("/queue", self.queue)
        self.app.router.add_get("/object_info", self.object_info)
        self.app.router.add_get("/models", self.models)
        self.app.router.add_get("/models/{folder}", self.models_folder)
        self.app.router.add_post("/upload/image", self.upload_image)
        self.app.router.add_post("/prompt", self.prompt)
        self.app.router.add_post("/queue", self.queue_post)
        self.app.router.add_post("/interrupt", self.interrupt)
        self.app.router.add_get("/history/{prompt_id}", self.history)
        self.app.router.add_get("/view", self.view)
        self.app.router.add_get("/ws", self.ws)
        self.runner: web.AppRunner | None = None
        self.site: web.TCPSite | None = None
        self.base_url = ""
        self.queue_running: list = []
        self.queue_pending: list = []
        self.prompt_counter = 0
        self.history: dict[str, Any] = {}
        self.last_prompt: dict | None = None
        self.interrupts: list[str | None] = []
        self.ws_clients: list[web.WebSocketResponse] = []
        self.object_info_data = {
            "KSampler": {"input": {"required": {"ckpt_name": (["sd.safetensors"],)}}},
            "LoadImage": {"input": {"required": {}}},
        }
        self.models_data = {"checkpoints": ["sd.safetensors"], "loras": []}
        self.uploads: list[dict] = []
        self.output_files: dict[str, bytes] = {}
        self.reject_prompt: dict | None = None
        self.stats_delay_s = 0.0

    async def start(self) -> str:
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await self.site.start()
        port = self.site._server.sockets[0].getsockname()[1]  # noqa: SLF001
        self.base_url = f"http://127.0.0.1:{port}"
        return self.base_url

    async def stop(self) -> None:
        for ws in list(self.ws_clients):
            await ws.close()
        if self.runner:
            await self.runner.cleanup()

    async def system_stats(self, _request):
        if self.stats_delay_s:
            await asyncio.sleep(self.stats_delay_s)
        return web.json_response({
            "system": {
                "os": "posix",
                "comfyui_version": "0.3.test",
                "ram_total": 32 * 1024**3,
                "ram_free": 16 * 1024**3,
                "python_version": "3.12.0",
                "pytorch_version": "2.4.0",
            },
            "devices": [{
                "name": "cuda:0 Test GPU",
                "type": "cuda",
                "index": 0,
                "vram_total": 24 * 1024**3,
                "vram_free": 20 * 1024**3,
            }],
        })

    async def queue(self, _request):
        return web.json_response({"queue_running": self.queue_running, "queue_pending": self.queue_pending})

    async def object_info(self, _request):
        return web.json_response(self.object_info_data)

    async def models(self, _request):
        return web.json_response(list(self.models_data.keys()))

    async def models_folder(self, request):
        return web.json_response(self.models_data.get(request.match_info["folder"], []))

    async def upload_image(self, request):
        reader = await request.multipart()
        fields = {}
        file_bytes = b""
        uploaded_name = "upload.png"
        while part := await reader.next():
            if part.name == "image":
                file_bytes = await part.read()
                if part.filename:
                    uploaded_name = part.filename
            else:
                fields[part.name] = (await part.text()).strip('"')
        self.uploads.append({"name": uploaded_name, "bytes": file_bytes, "fields": fields})
        sub = fields.get("subfolder", "comfier")
        return web.json_response({"name": uploaded_name, "subfolder": sub})

    async def prompt(self, request):
        body = await request.json()
        self.last_prompt = body
        if body.get("fail") or self.reject_prompt:
            body = self.reject_prompt or {"error": "bad", "node_errors": {"3": {"errors": []}}}
            return web.json_response(body, status=400)
        self.prompt_counter += 1
        prompt_id = f"p_{self.prompt_counter}"
        return web.json_response({"prompt_id": prompt_id, "number": 0})

    async def queue_post(self, request):
        body = await request.json()
        for pid in body.get("delete") or []:
            self.queue_pending = [q for q in self.queue_pending if q[1] != pid]
        return web.json_response({"ok": True})

    async def interrupt(self, request):
        body = await request.json() if request.can_read_body else {}
        self.interrupts.append(body.get("prompt_id"))
        return web.json_response({"ok": True})

    async def history(self, request):
        pid = request.match_info["prompt_id"]
        return web.json_response({pid: self.history.get(pid, {})})

    async def view(self, request):
        fn = request.rel_url.query.get("filename")
        data = self.output_files.get(fn, b"output-bytes")
        return web.Response(body=data)

    async def ws(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.ws_clients.append(ws)
        try:
            async for _msg in ws:
                pass
        finally:
            self.ws_clients.remove(ws)
        return ws

    async def push_ws(self, payload: dict) -> None:
        """Send an event the way ComfyUI does: {"type": ..., "data": {...}}."""
        body = dict(payload)
        raw = json.dumps({"type": body.pop("type"), "data": body})
        dead = []
        for ws in self.ws_clients:
            try:
                await ws.send_str(raw)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.ws_clients.remove(ws)
