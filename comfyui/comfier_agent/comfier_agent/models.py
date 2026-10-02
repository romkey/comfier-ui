"""Model download manager."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import shutil
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

import aiohttp

from comfier_agent.config import AgentConfig
from comfier_agent.hf_endpoint import (
    ensure_hf_authorization,
    hf_endpoint_host_allowed,
    host_matches_allowlist,
    proxy_headers,
    rewrite_url,
)
from comfier_agent.protocol import compact
from comfier_agent.resources import _paths_for_disk_check
from comfier_agent.transfer import CHUNK, MAX_REDIRECTS, REDIRECT_STATUSES, redirect_target, same_host

LOG = logging.getLogger("comfier_agent")

SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9._ ()+-]+$")
ALLOWED_EXT = {".safetensors", ".sft", ".gguf"}
PICKLE_EXT = {".ckpt", ".pt", ".pth", ".bin"}
DEFAULT_FOLDERS = {
    "checkpoints",
    "loras",
    "vae",
    "clip_vision",
    "controlnet",
    "upscale_models",
    "embeddings",
    "diffusion_models",
    "text_encoders",
}
PART_SUFFIX = ".comfier-part"
PART_MAX_AGE_S = 7 * 86400


@dataclass
class DownloadState:
    download_id: str
    state: str = "downloading"
    bytes_done: int = 0
    bytes_total: int | None = None
    progress: float = 0.0
    task: asyncio.Task | None = None
    cancel: bool = False


class ModelDownloadManager:
    def __init__(self, config: AgentConfig, session: aiohttp.ClientSession, send, rescan_inventory):
        self.config = config
        self.session = session
        self.send = send
        self.rescan_inventory = rescan_inventory
        self.active: dict[str, DownloadState] = {}
        self.paths_in_progress: dict[str, str] = {}
        self._terminal_buffer: list[dict] = []
        self._progress_last: dict[str, float] = {}

    def drain_terminal_buffer(self) -> list[dict]:
        out = list(self._terminal_buffer)
        self._terminal_buffer.clear()
        return out

    def status_entries(self) -> list[dict]:
        return [
            {"download_id": d.download_id, "state": d.state, "progress": d.progress}
            for d in self.active.values()
        ]

    def active_for_hello(self) -> list[dict]:
        return [
            compact({
                "download_id": d.download_id,
                "state": d.state,
                "bytes_done": d.bytes_done,
                "bytes_total": d.bytes_total,
            })
            for d in self.active.values()
        ]

    async def handle(self, msg: dict[str, Any]) -> None:
        if len(self.active) >= self.config.max_concurrent_downloads:
            await self._failed(msg["download_id"], "invalid", "too many concurrent downloads")
            return
        task = asyncio.create_task(self._run(msg))
        self.active[msg["download_id"]] = DownloadState(download_id=msg["download_id"], task=task)

    async def cancel(self, download_id: str) -> None:
        """Stop a download; the running task reports the cancel once it has cleaned up."""
        state = self.active.get(download_id)
        if state and state.task and not state.task.done() and state.task is not asyncio.current_task():
            state.cancel = True
            state.task.cancel()
            return
        await self._cancelled(download_id)

    async def _cancelled(self, download_id: str) -> None:
        msg = {"type": "model.download.cancelled", "download_id": download_id}
        await self.send(msg)
        self._terminal_buffer.append(msg)

    async def _run(self, msg: dict[str, Any]) -> None:
        download_id = msg["download_id"]
        try:
            reason = await self._validate(msg)
            if reason:
                await self._failed(download_id, reason[0], reason[1])
                return
            _root, final_path = self._resolve_path(msg["folder"], msg["filename"])
            if final_path in self.paths_in_progress.values():
                await self._failed(download_id, "invalid", "already downloading")
                return
            self.paths_in_progress[download_id] = final_path

            try:
                existing = await self._check_existing(final_path, msg)
            except ExistsError:
                await self._failed(download_id, "exists", "hash differs")
                return
            if existing is not None:
                await self._complete(download_id, msg["folder"], msg["filename"], existing, msg.get("sha256"), True)
                return

            part = final_path + PART_SUFFIX
            os.makedirs(os.path.dirname(final_path), exist_ok=True)
            resume = os.path.getsize(part) if os.path.exists(part) else 0
            headers = dict(msg.get("headers") or {})
            original_url = msg["url"]
            url = original_url
            if self._is_frontend_url(url):
                headers["Authorization"] = f"Bearer {self.config.api_key}"
            ensure_hf_authorization(headers, original_url)
            url, via_proxy = rewrite_url(url, self.config.hf_endpoint)
            if via_proxy:
                headers.update(proxy_headers(self.config))

            sha = hashlib.sha256() if not resume else None
            bytes_total = msg.get("bytes")
            max_bytes = int(self.config.max_model_download_gb * 1024**3)
            done = resume
            speed_window = time.time()
            speed_bytes = 0

            attempt = 0
            redirects = 0
            while attempt < 5:
                if self.active.get(download_id) and self.active[download_id].cancel:
                    raise Cancelled()
                try:
                    req_headers = dict(headers)
                    if done:
                        req_headers["Range"] = f"bytes={done}-"
                    async with self.session.get(url, headers=req_headers, allow_redirects=False) as resp:
                        if resp.status in REDIRECT_STATUSES:
                            loc = redirect_target(url, resp.headers.get("Location"))
                            if not self._host_allowed(loc):
                                await self._failed(download_id, "host_not_allowed", urlparse(loc).hostname or loc)
                                return
                            redirects += 1
                            if redirects > MAX_REDIRECTS:
                                await self._failed(download_id, "http_error", "too many redirects")
                                return
                            if not same_host(url, loc):
                                # Tokens were chosen for the original host; a CDN gets a signed URL instead.
                                headers = {}
                            url = loc
                            continue
                        if resp.status not in (200, 206):
                            await self._failed(download_id, "http_error", f"HTTP {resp.status}")
                            return
                        if bytes_total is None:
                            cl = resp.headers.get("Content-Length")
                            if cl:
                                bytes_total = int(cl) + (done if resp.status == 206 else 0)
                        mode = "ab" if done and resp.status == 206 else "wb"
                        if mode == "wb":
                            done = 0
                        with open(part, mode) as out:
                            async for chunk in resp.content.iter_chunked(CHUNK):
                                if self.active.get(download_id) and self.active[download_id].cancel:
                                    raise Cancelled()
                                out.write(chunk)
                                done += len(chunk)
                                speed_bytes += len(chunk)
                                if sha:
                                    sha.update(chunk)
                                if done > max_bytes:
                                    out.close()
                                    os.remove(part)
                                    await self._failed(download_id, "too_large", str(done))
                                    return
                                if done % (1024**3) < len(chunk):
                                    if not self._disk_ok(final_path, 0):
                                        out.close()
                                        os.remove(part)
                                        await self._failed(download_id, "disk_full", "min free disk")
                                        return
                                await self._progress(download_id, done, bytes_total, speed_bytes, speed_window)
                    break
                except Cancelled:
                    if os.path.exists(part):
                        os.remove(part)
                    await self._cancelled(download_id)
                    return
                except aiohttp.ClientError:
                    attempt += 1
                    if attempt >= 5:
                        await self._failed(download_id, "network", "download failed")
                        return
                    await asyncio.sleep(2**attempt)
            else:
                await self._failed(download_id, "network", "download failed")
                return

            st = self.active.get(download_id)
            if st:
                st.state = "verifying"
            if bytes_total is not None and done != bytes_total:
                os.remove(part)
                await self._failed(download_id, "size_mismatch", f"{done} vs {bytes_total}")
                return
            if msg.get("sha256"):
                if sha is None:
                    digest = await asyncio.to_thread(_file_sha256, part)
                else:
                    digest = sha.hexdigest()
                if digest.lower() != msg["sha256"].lower():
                    os.remove(part)
                    await self._failed(download_id, "hash_mismatch", digest)
                    return
            else:
                digest = sha.hexdigest() if sha else await asyncio.to_thread(_file_sha256, part)

            if msg["filename"].lower().endswith(".safetensors") and not _safetensors_ok(part):
                os.remove(part)
                await self._failed(download_id, "invalid", "not a valid safetensors file (check access token)")
                return

            os.replace(part, final_path)
            await self._complete(download_id, msg["folder"], msg["filename"], done, digest, False)
        except asyncio.CancelledError:
            part_path = None
            if download_id in self.paths_in_progress:
                part_path = self.paths_in_progress[download_id] + PART_SUFFIX
            if part_path and os.path.exists(part_path):
                os.remove(part_path)
            await self._cancelled(download_id)
        finally:
            self.active.pop(download_id, None)
            self.paths_in_progress.pop(download_id, None)

    async def _validate(self, msg: dict[str, Any]) -> tuple[str, str] | None:
        if not self.config.allow_model_downloads:
            return ("disabled", "downloads disabled")
        url = msg.get("url") or ""
        parsed = urlparse(url)
        if parsed.scheme != "https" and not (self.config.allow_insecure and parsed.scheme == "http"):
            return ("host_not_allowed", "url must be https")
        if not self._host_allowed(url):
            return ("host_not_allowed", parsed.hostname or "")
        folder = msg.get("folder") or ""
        if folder not in self._known_folders():
            return ("invalid", f"unknown folder {folder}")
        if not _safe_filename(msg.get("filename") or ""):
            return ("invalid", "unsafe filename")
        ext = os.path.splitext(msg["filename"])[1].lower()
        allowed = set(ALLOWED_EXT)
        if self.config.allow_pickle_formats:
            allowed |= PICKLE_EXT
        if ext not in allowed:
            return ("extension_not_allowed", ext)
        expected = msg.get("bytes")
        if expected and expected > int(self.config.max_model_download_gb * 1024**3):
            return ("too_large", str(expected))
        _root, final = self._resolve_path(folder, msg["filename"])
        if expected and not self._disk_ok(final, expected):
            return ("disk_full", "insufficient space")
        return None

    def _known_folders(self) -> set[str]:
        try:
            import folder_paths  # type: ignore

            return set(folder_paths.folder_names_and_paths.keys())
        except Exception:
            if self.config.comfyui_models_dir:
                base = self.config.comfyui_models_dir
                return {d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))}
            return set(DEFAULT_FOLDERS)

    def _resolve_path(self, folder: str, filename: str) -> tuple[str, str]:
        try:
            import folder_paths  # type: ignore

            root = folder_paths.get_folder_paths(folder)[0]
        except Exception:
            base = self.config.comfyui_models_dir or "."
            root = os.path.join(base, folder)
        parts = filename.replace("\\", "/").split("/")
        final = os.path.realpath(os.path.join(root, *parts))
        root_real = os.path.realpath(root)
        if os.path.commonpath([root_real, final]) != root_real:
            raise ValueError("path escape")
        return root_real, final

    def _host_allowed(self, url: str) -> bool:
        if not self.config.model_download_hosts:
            scheme = urlparse(url).scheme
            if self.config.allow_insecure:
                return scheme in ("https", "http")
            return scheme == "https"
        host = (urlparse(url).hostname or "").lower()
        allowed = self.config.model_download_hosts
        if host_matches_allowlist(host, allowed):
            return True
        return hf_endpoint_host_allowed(host, allowed, self.config.hf_endpoint)

    def _is_frontend_url(self, url: str) -> bool:
        a = urlparse(url)
        b = urlparse(self.config.frontend_url)
        return a.scheme == b.scheme and (a.hostname or "").lower() == (b.hostname or "").lower()

    def _disk_ok(self, final_path: str, needed: int) -> bool:
        check_dir = os.path.dirname(final_path) or "."
        if not os.path.isdir(check_dir):
            check_dir = os.path.dirname(check_dir) or check_dir
        usage = shutil.disk_usage(check_dir)
        min_free = int(self.config.min_free_disk_gb * 1024**3)
        return (usage.free - needed) >= min_free

    async def _check_existing(self, path: str, msg: dict[str, Any]) -> int | None:
        if not os.path.isfile(path):
            return None
        if msg.get("sha256"):
            digest = await asyncio.to_thread(_file_sha256, path)
            if digest.lower() == msg["sha256"].lower():
                return os.path.getsize(path)
            if not msg.get("overwrite"):
                raise ExistsError()
            return None
        return os.path.getsize(path)

    async def _progress(
        self,
        download_id: str,
        done: int,
        total: int | None,
        speed_bytes: int,
        speed_window: float,
    ) -> None:
        now = time.time()
        last = self._progress_last.get(download_id, 0)
        if now - last < 1.0:
            return
        self._progress_last[download_id] = now
        dt = max(now - speed_window, 0.001)
        st = self.active.get(download_id)
        if st:
            st.bytes_done = done
            st.bytes_total = total
            st.progress = (done / total) if total else 0.0
        await self.send(compact({
            "type": "model.download.progress",
            "download_id": download_id,
            "state": st.state if st else "downloading",
            "bytes_done": done,
            "bytes_total": total,
            "speed_bps": int(speed_bytes / dt),
        }))

    async def _complete(
        self,
        download_id: str,
        folder: str,
        filename: str,
        size: int,
        sha256: str | None,
        already: bool,
    ) -> None:
        msg = compact({
            "type": "model.download.completed",
            "download_id": download_id,
            "folder": folder,
            "filename": filename,
            "bytes": size,
            "sha256": sha256,
            "already_present": already,
        })
        await self.send(msg)
        self._terminal_buffer.append(msg)
        await self.rescan_inventory()

    async def _failed(self, download_id: str, reason: str, detail: str) -> None:
        msg = {"type": "model.download.failed", "download_id": download_id, "reason": reason}
        msg["detail"] = str(detail)[:2000]
        await self.send(msg)
        self._terminal_buffer.append(msg)


class Cancelled(Exception):
    pass


class ExistsError(Exception):
    pass


def sweep_stale_part_files(config: AgentConfig, max_age_s: int = PART_MAX_AGE_S) -> None:
    """Remove abandoned .comfier-part files older than max_age_s from model folder roots."""
    cutoff = time.time() - max_age_s
    for _label, path in _paths_for_disk_check(config):
        if not os.path.isdir(path):
            continue
        for root, _dirs, files in os.walk(path):
            for name in files:
                if not name.endswith(PART_SUFFIX):
                    continue
                part = os.path.join(root, name)
                try:
                    if os.path.getmtime(part) < cutoff:
                        os.remove(part)
                        LOG.info("removed stale part file %s", part)
                except OSError as exc:
                    LOG.debug("could not remove %s: %s", part, exc)


def _file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def _safetensors_ok(path: str) -> bool:
    try:
        with open(path, "rb") as f:
            header_len = int.from_bytes(f.read(8), "little")
            header = f.read(header_len)
        json.loads(header.decode("utf-8"))
        return True
    except Exception:
        return False


def _safe_filename(name: str) -> bool:
    name = name.replace("\\", "/").strip()
    if not name or name.startswith("/") or ".." in name.split("/"):
        return False
    if re.match(r"^[A-Za-z]:", name):
        return False
    parts = name.split("/")
    if len(parts) > 4:
        return False
    if any(not p or p.startswith(".") for p in parts):
        return False
    if len(name) > 255:
        return False
    return all(SAFE_SEGMENT.match(p) for p in parts)
