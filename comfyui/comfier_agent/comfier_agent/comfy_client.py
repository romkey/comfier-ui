"""Local ComfyUI HTTP + WebSocket client."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from typing import Any, Callable

import aiohttp

LOG = logging.getLogger("comfier_agent")


class ComfyClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.client_id = str(uuid.uuid4())
        self._session: aiohttp.ClientSession | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._ws_handlers: list[Callable[[dict], None]] = []
        self._ws_task: asyncio.Task | None = None

    async def start(self) -> None:
        if self._session is None:
            self._session = aiohttp.ClientSession()

    async def close(self) -> None:
        if self._ws_task:
            self._ws_task.cancel()
            try:
                await self._ws_task
            except asyncio.CancelledError:
                pass
        if self._ws and not self._ws.closed:
            await self._ws.close()
        if self._session:
            await self._session.close()
        self._session = None

    @property
    def session(self) -> aiohttp.ClientSession:
        assert self._session is not None
        return self._session

    async def wait_ready(self, timeout: float = 120) -> None:
        delay = 1.0
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            try:
                async with self.session.get(f"{self.base_url}/system_stats") as resp:
                    if resp.status == 200:
                        return
            except aiohttp.ClientError:
                pass
            await asyncio.sleep(delay)
            delay = min(delay * 2, 10)

    async def system_stats(self) -> dict[str, Any]:
        async with self.session.get(f"{self.base_url}/system_stats") as resp:
            resp.raise_for_status()
            return await resp.json()

    async def queue(self) -> dict[str, Any]:
        async with self.session.get(f"{self.base_url}/queue") as resp:
            resp.raise_for_status()
            return await resp.json()

    async def history(self, prompt_id: str) -> dict[str, Any]:
        async with self.session.get(f"{self.base_url}/history/{prompt_id}") as resp:
            resp.raise_for_status()
            return await resp.json()

    async def object_info(self) -> dict[str, Any]:
        async with self.session.get(f"{self.base_url}/object_info") as resp:
            resp.raise_for_status()
            return await resp.json()

    async def models_folders(self) -> list[str]:
        async with self.session.get(f"{self.base_url}/models") as resp:
            if resp.status == 404:
                return []
            resp.raise_for_status()
            data = await resp.json()
            return list(data) if isinstance(data, list) else []

    async def models_in_folder(self, folder: str) -> list[str]:
        async with self.session.get(f"{self.base_url}/models/{folder}") as resp:
            if resp.status == 404:
                return []
            resp.raise_for_status()
            data = await resp.json()
            return list(data) if isinstance(data, list) else []

    async def upload_image(self, path: str, filename: str) -> dict[str, Any]:
        from aiohttp import FormData

        data = FormData()
        data.add_field(
            "image",
            open(path, "rb"),
            filename=os.path.basename(filename),
            content_type="application/octet-stream",
        )
        data.add_field("subfolder", "comfier")
        data.add_field("type", "input")
        data.add_field("overwrite", "true")
        async with self.session.post(f"{self.base_url}/upload/image", data=data) as resp:
            resp.raise_for_status()
            return await resp.json()

    async def submit_prompt(self, workflow: dict[str, Any], *, job_id: str) -> dict[str, Any]:
        body = {
            "prompt": workflow,
            "client_id": self.client_id,
            "extra_data": {"comfier_job_id": job_id},
        }
        async with self.session.post(f"{self.base_url}/prompt", json=body) as resp:
            data = await resp.json()
            if resp.status == 400:
                return {"error": True, "status": 400, **data}
            resp.raise_for_status()
            return data

    async def delete_queue(self, prompt_ids: list[str]) -> None:
        async with self.session.post(f"{self.base_url}/queue", json={"delete": prompt_ids}) as resp:
            resp.raise_for_status()

    async def interrupt(self, prompt_id: str | None = None) -> None:
        payload: dict[str, Any] = {}
        if prompt_id:
            payload["prompt_id"] = prompt_id
        async with self.session.post(f"{self.base_url}/interrupt", json=payload or None) as resp:
            resp.raise_for_status()

    async def free_memory(self) -> None:
        """Unload every model so another engine on this machine has the (unified) memory."""
        async with self.session.post(
            f"{self.base_url}/free", json={"unload_models": True, "free_memory": True}
        ) as resp:
            resp.raise_for_status()

    def add_ws_handler(self, handler: Callable[[dict], None]) -> None:
        self._ws_handlers.append(handler)

    def remove_ws_handler(self, handler: Callable[[dict], None]) -> None:
        if handler in self._ws_handlers:
            self._ws_handlers.remove(handler)

    async def ensure_ws(self) -> None:
        if self._ws_task and not self._ws_task.done():
            return
        self._ws_task = asyncio.create_task(self._ws_loop())

    async def _ws_loop(self) -> None:
        assert self._session is not None
        ws_url = self.base_url.replace("https://", "wss://").replace("http://", "ws://")
        url = f"{ws_url}/ws?clientId={self.client_id}"
        while True:
            try:
                async with self.session.ws_connect(url, heartbeat=20) as ws:
                    self._ws = ws
                    async for msg in ws:
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            try:
                                data = json.loads(msg.data)
                            except json.JSONDecodeError:
                                continue
                            event = flatten_ws_event(data)
                            for handler in list(self._ws_handlers):
                                handler(event)
                        elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                            break
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOG.debug("ComfyUI ws reconnect: %s", exc)
            await asyncio.sleep(2)

    async def view_url(self, filename: str, subfolder: str, file_type: str) -> str:
        from urllib.parse import urlencode

        q = urlencode({"filename": filename, "subfolder": subfolder, "type": file_type})
        return f"{self.base_url}/view?{q}"

    async def stream_view(self, filename: str, subfolder: str, file_type: str):
        url = await self.view_url(filename, subfolder, file_type)
        return self.session.get(url)


def flatten_ws_event(message: Any) -> dict:
    """ComfyUI sends {"type": ..., "data": {"prompt_id": ..., "node": ...}}; handlers read one flat dict."""
    if not isinstance(message, dict):
        return {}
    data = message.get("data")
    if isinstance(data, dict):
        return {**data, "type": message.get("type")}
    return message
