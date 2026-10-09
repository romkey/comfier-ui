"""Outbound WebSocket connection to the Comfier frontend."""

from __future__ import annotations

import asyncio
import json
import logging
import random
import time
from typing import Any, Awaitable, Callable

import aiohttp

from comfier_agent.config import AgentConfig

LOG = logging.getLogger("comfier_agent")

MessageHandler = Callable[[dict[str, Any]], Awaitable[None]]


INITIAL_RETRY_S = 1.0
TERMINAL_TYPES = frozenset({
    "job.completed",
    "job.failed",
    "job.cancelled",
    "model.download.completed",
    "model.download.failed",
    "model.download.cancelled",
})
# Terminal events are re-sent after every hello (the frontend ignores duplicates); keep the recent ones.
TERMINAL_BUFFER_MAX = 50

# What each close code means for the person running the server, shown in the ComfyUI panel.
CLOSE_REASONS = {
    1008: "The frontend closed the connection because the agent broke a protocol rule "
          "(no hello in time, or too many messages). Reconnecting.",
    1009: "The frontend closed the connection because a message was too large. Reconnecting.",
    4401: "The API key was revoked or has expired. Create a new key on this server's page in Comfier "
          "and paste it here.",
    4409: "Another agent connected with this API key, so this one was disconnected. Each server needs its own key.",
    4426: "This agent's protocol version isn't supported by the frontend. Update the Comfier agent.",
}


def close_code_backoff_seconds(code: int | None) -> float:
    """Extra delay before reconnecting after specific WebSocket close codes."""
    if code == 4401:
        return 300.0
    if code == 4426:
        return 1800.0
    return 0.0


def log_close_code(code: int | None) -> None:
    if code == 4401:
        LOG.warning("frontend auth failed; backing off 5 minutes")
    elif code == 4426:
        LOG.warning("protocol version mismatch; update the agent")
    elif code == 4409:
        LOG.warning(
            "frontend closed connection (replaced); "
            "this API key may be in use on another machine"
        )
    elif code in (1008, 1009):
        LOG.warning("frontend closed connection: %s", CLOSE_REASONS[code])


class FrontendConnection:
    def __init__(self, config: AgentConfig):
        self.config = config
        self._session: aiohttp.ClientSession | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._handler: MessageHandler | None = None
        self._send_lock = asyncio.Lock()
        self._latest_status: dict | None = None
        self._latest_inventory: dict | None = None
        self._terminal_out: list[dict] = []
        self._connected = asyncio.Event()
        self._last_connect_log = 0.0
        self._task: asyncio.Task | None = None
        self.state = "connecting"
        self.last_close_code: int | None = None
        self.last_error: str | None = None
        self.connected_at: float | None = None
        self.retry_at: float | None = None

    @property
    def connected(self) -> bool:
        return self._ws is not None and not self._ws.closed

    async def start(self, handler: MessageHandler) -> None:
        self._handler = handler
        self._session = aiohttp.ClientSession()
        self._task = asyncio.create_task(self._connect_loop())

    async def reconnect(self) -> None:
        """Drop the socket (and any backoff) so the next attempt uses the current config."""
        self.retry_at = None
        if self._task and not self._task.done():
            self._task.cancel()
        if self._ws and not self._ws.closed:
            await self._ws.close()
        self._task = asyncio.create_task(self._connect_loop())

    def status_dict(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "connected": self.connected,
            "last_close_code": self.last_close_code,
            "last_close_reason": CLOSE_REASONS.get(self.last_close_code),
            "last_error": self.last_error,
            "connected_at": self.connected_at,
            "retry_at": self.retry_at,
        }

    async def close(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
        if self._ws and not self._ws.closed:
            try:
                await asyncio.wait_for(self.send({"type": "bye", "reason": "shutdown"}), timeout=2)
            except Exception:
                pass
            await self._ws.close()
        if self._session:
            await self._session.close()

    def buffer_terminal(self, msg: dict) -> None:
        self._terminal_out.append(msg)
        del self._terminal_out[:-TERMINAL_BUFFER_MAX]

    def set_latest_status(self, msg: dict) -> None:
        self._latest_status = msg

    def set_latest_inventory(self, msg: dict) -> None:
        self._latest_inventory = msg

    async def send(self, msg: dict) -> None:
        if msg.get("type") == "status":
            self._latest_status = msg
        if msg.get("type") == "inventory":
            self._latest_inventory = msg
        if msg.get("type") in TERMINAL_TYPES:
            self.buffer_terminal(msg)
        await self._send_now(msg)

    async def _send_now(self, msg: dict) -> None:
        async with self._send_lock:
            if not self.connected:
                return
            payload = json.dumps(msg, separators=(",", ":"))
            if LOG.isEnabledFor(logging.DEBUG):
                LOG.debug("send %s", _redact_msg(msg))
            await self._ws.send_str(payload)

    async def flush_after_connect(self) -> None:
        if self._latest_inventory:
            await self.send(self._latest_inventory)
        if self._latest_status:
            await self.send(self._latest_status)
        # Each terminal event is re-sent once, after the next hello; the frontend ignores duplicates.
        # A job whose event is lost anyway is missing from hello.active_jobs, which it reconciles.
        pending, self._terminal_out = self._terminal_out, []
        for msg in pending:
            await self._send_now(msg)

    async def _connect_loop(self) -> None:
        assert self._session is not None
        delay = INITIAL_RETRY_S
        while True:
            self.state = "connecting"
            stable = False
            extra = 0.0
            try:
                headers = {"Authorization": f"Bearer {self.config.api_key}"}
                async with self._session.ws_connect(
                    self.config.ws_url(),
                    headers=headers,
                    heartbeat=20,
                    autoping=True,
                ) as ws:
                    self._ws = ws
                    connected_at = time.time()
                    self._mark_connected()
                    await self._handler({"type": "_connected"})
                    await self.flush_after_connect()
                    async for msg in ws:
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            data = json.loads(msg.data)
                            if LOG.isEnabledFor(logging.DEBUG):
                                LOG.debug("recv %s", _redact_msg(data))
                            await self._handler(data)
                        elif msg.type == aiohttp.WSMsgType.ERROR:
                            break
                    # aiohttp ends the iteration on CLOSE, so the code is read here, not in the loop.
                    stable = time.time() - connected_at >= 60
                    extra = self._closed(ws.close_code)
            except asyncio.CancelledError:
                raise
            except aiohttp.ClientResponseError as exc:
                extra = self._handshake_failed(exc.status)
            except Exception as exc:
                self.last_error = f"Can't reach {self.config.frontend_url}: {exc}"
                self._rate_log(f"connection error: {exc}")
            finally:
                self._ws = None

            delay = INITIAL_RETRY_S if stable else min(delay * 2, 60)
            wait = extra or (delay + random.uniform(0, delay * 0.25))
            self.state = "waiting"
            self.retry_at = time.time() + wait
            await asyncio.sleep(wait)

    def _mark_connected(self) -> None:
        self.state = "connected"
        self.connected_at = time.time()
        self.retry_at = None
        self.last_error = None
        LOG.info("connected to frontend")

    def _closed(self, code: int | None) -> float:
        self.last_close_code = code
        log_close_code(code)
        if code in CLOSE_REASONS:
            self.last_error = CLOSE_REASONS[code]
        return close_code_backoff_seconds(code)

    def _handshake_failed(self, status: int) -> float:
        if status in (401, 403):
            self.last_error = (
                f"The frontend rejected the API key (HTTP {status}). Check the key on this server's page in Comfier."
            )
            LOG.warning("frontend HTTP auth failed (%s); backing off 5 minutes", status)
            return 300.0
        self.last_error = f"The frontend refused the connection (HTTP {status})."
        self._rate_log(f"connection error: HTTP {status}")
        return 0.0

    def _rate_log(self, message: str) -> None:
        now = time.time()
        if now - self._last_connect_log >= 60:
            LOG.warning(message)
            self._last_connect_log = now


def _redact_msg(msg: dict) -> dict:
    out = dict(msg)
    if "workflow" in out:
        out["workflow"] = "<truncated>"
    for key in list(out.keys()):
        if "key" in key.lower() or "authorization" in key.lower():
            out[key] = "***"
    return out
