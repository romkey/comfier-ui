"""Model download manager."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import re
import shutil
import threading
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

import aiohttp

from comfier_agent.config import AgentConfig
from comfier_agent.engines.mlx import DownloadFailed
from comfier_agent.fp8 import ConversionCancelled, ConversionError, convert_fp8_to_fp16
from comfier_agent.hf_cli import (
    HfCliCancelled,
    HfCliError,
    HfCliUnavailable,
    parse_hf_resolve_url,
)
from comfier_agent.hf_cli import (
    download_file as hf_cli_download,
)
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
# ComfyUI's model folders (folder_paths), for when the agent runs outside ComfyUI and can't ask it. Folders that
# hold code or settings (custom_nodes, configs) aren't download targets.
DEFAULT_FOLDERS = {
    "audio_encoders",
    "background_removal",
    "checkpoints",
    "classifiers",
    "clip",
    "clip_vision",
    "controlnet",
    "detection",
    "diffusion_models",
    "embeddings",
    "frame_interpolation",
    "geometry_estimation",
    "gligen",
    "hypernetworks",
    "latent_upscale_models",
    "loras",
    "model_patches",
    "optical_flow",
    "photomaker",
    "style_models",
    "text_encoders",
    "unet",
    "upscale_models",
    "vae",
    "vae_approx",
}
PART_SUFFIX = ".comfier-part"
CONVERTING_SUFFIX = ".fp16" + PART_SUFFIX
# model.download "convert": the fp8 file is downloaded and verified as usual, then saved as fp16 (Apple Silicon).
CONVERT_FP8_TO_FP16 = "fp8_to_fp16"
PART_MAX_AGE_S = 7 * 86400
# How long a delete waits for a cancelled download of the same file to stop before trying anyway.
CANCEL_SETTLE_SECONDS = 60


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
    def __init__(self, config: AgentConfig, session: aiohttp.ClientSession, send, rescan_inventory, engines=None):
        self.config = config
        # mflux and mlx-video fetch their own models (model.download with "engine").
        self.engines = engines or {}
        self.session = session
        self.send = send
        self.rescan_inventory = rescan_inventory
        self.active: dict[str, DownloadState] = {}
        self.paths_in_progress: dict[str, str] = {}
        self._wait_queue: list[dict[str, Any]] = []
        self._terminal_buffer: list[dict] = []
        self._progress_last: dict[str, float] = {}
        self._deletes: set[asyncio.Task] = set()

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
        if not self._can_start_download():
            self._wait_queue.append(msg)
            return
        self._start(msg)

    def _concurrency_limit(self) -> int | None:
        limit = self.config.max_concurrent_downloads
        return None if limit <= 0 else limit

    def _can_start_download(self) -> bool:
        limit = self._concurrency_limit()
        return limit is None or len(self.active) < limit

    def _start(self, msg: dict[str, Any]) -> None:
        task = asyncio.create_task(self._run(msg))
        self.active[msg["download_id"]] = DownloadState(download_id=msg["download_id"], task=task)

    def _drain_wait_queue(self) -> None:
        while self._wait_queue and self._can_start_download():
            self._start(self._wait_queue.pop(0))

    async def cancel(self, download_id: str) -> None:
        """Stop a download; the running task reports the cancel once it has cleaned up."""
        before = len(self._wait_queue)
        self._wait_queue = [m for m in self._wait_queue if m.get("download_id") != download_id]
        if len(self._wait_queue) < before:
            await self._cancelled(download_id)
            return
        state = self.active.get(download_id)
        if state and state.task and not state.task.done() and state.task is not asyncio.current_task():
            state.cancel = True
            state.task.cancel()
            return
        await self._cancelled(download_id)

    async def delete(self, msg: dict[str, Any]) -> None:
        """model.delete: remove a model file, or an engine's whole model, and report the space freed.

        Comfier cancels a download of the same file just before deleting it; the delete waits, off the message
        loop, for that download to clean up rather than being refused as busy."""
        stopping = self._cancelling_tasks(self._delete_key(msg))
        if not stopping:
            await self._delete_now(msg)
            return
        task = asyncio.create_task(self._delete_after(stopping, msg))
        self._deletes.add(task)
        task.add_done_callback(self._deletes.discard)

    async def _delete_after(self, tasks: list[asyncio.Task], msg: dict[str, Any]) -> None:
        await asyncio.wait(tasks, timeout=CANCEL_SETTLE_SECONDS)
        await self._delete_now(msg)

    def _delete_key(self, msg: dict[str, Any]) -> str | None:
        """What paths_in_progress holds while the model msg names is downloading."""
        if msg.get("engine"):
            return _engine_key(msg["engine"], msg.get("model") or "")
        try:
            return self._resolve_path(msg.get("folder") or "", msg.get("filename") or "")[1]
        except (KeyError, ValueError, TypeError):
            return None

    def _cancelling_tasks(self, key: str | None) -> list[asyncio.Task]:
        if key is None:
            return []
        states = [self.active.get(i) for i, held in self.paths_in_progress.items() if held == key]
        return [s.task for s in states if s and s.cancel and s.task and not s.task.done()]

    async def _delete_now(self, msg: dict[str, Any]) -> None:
        ids = {k: msg[k] for k in ("folder", "filename", "engine", "model") if msg.get(k)}
        try:
            if not self.config.allow_model_downloads:
                raise DeleteRefused("disabled", "model downloads are turned off")
            if msg.get("engine"):
                freed = await self._delete_engine_model(msg["engine"], msg.get("model") or "")
            else:
                freed = await self._delete_file(msg.get("folder") or "", msg.get("filename") or "")
        except DeleteRefused as exc:
            await self.send(compact({"type": "model.delete.failed", "delete_id": msg["delete_id"], **ids,
                                     "reason": exc.reason, "detail": exc.detail[:2000]}))
            return
        except OSError as exc:
            await self.send(compact({"type": "model.delete.failed", "delete_id": msg["delete_id"], **ids,
                                     "reason": "error", "detail": str(exc)[:2000]}))
            return
        LOG.info("deleted %s (%s bytes)", "/".join(str(v) for v in ids.values()), freed)
        await self.send(compact({"type": "model.deleted", "delete_id": msg["delete_id"], **ids,
                                 "bytes": freed or 0, "already_absent": freed is None}))
        await self.rescan_inventory()

    async def _delete_file(self, folder: str, filename: str) -> int | None:
        """Bytes freed, or None when the file wasn't there."""
        if folder not in self._known_folders():
            raise DeleteRefused("invalid", f"unknown folder {folder}")
        if not _safe_filename(filename) or os.path.splitext(filename)[1].lower() not in ALLOWED_EXT | PICKLE_EXT:
            raise DeleteRefused("invalid", "not a model file name")
        try:
            _root, path = self._resolve_path(folder, filename)
        except ValueError:
            raise DeleteRefused("invalid", "path escape") from None
        if path in self.paths_in_progress.values():
            raise DeleteRefused("busy", "the file is downloading")
        with contextlib.suppress(FileNotFoundError):
            os.remove(path + PART_SUFFIX)
        if not os.path.isfile(path):
            return None
        size = os.path.getsize(path)
        os.remove(path)
        return size

    async def _delete_engine_model(self, name: str, model: str) -> int | None:
        engine = self.engines.get(name)
        if engine is None or not hasattr(engine, "delete"):
            raise DeleteRefused("invalid", f"this server doesn't run {name}")
        if not model:
            raise DeleteRefused("invalid", "no model named")
        if _engine_key(name, model) in self.paths_in_progress.values():
            raise DeleteRefused("busy", "the model is downloading")
        try:
            return await engine.delete(model)
        except ValueError as exc:
            raise DeleteRefused("invalid", str(exc)) from None

    async def _cancelled(self, download_id: str) -> None:
        msg = {"type": "model.download.cancelled", "download_id": download_id}
        await self.send(msg)
        self._terminal_buffer.append(msg)

    async def _run(self, msg: dict[str, Any]) -> None:
        if msg.get("engine"):
            await self._run_engine(msg)
            return
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

            if msg.get("convert") not in (None, CONVERT_FP8_TO_FP16):
                await self._failed(download_id, "invalid", f"unknown conversion {msg['convert']}")
                return
            try:
                # A converted file's hash isn't the download's, so only its presence counts.
                check = {**msg, "sha256": None} if msg.get("convert") else msg
                existing = await self._check_existing(final_path, check)
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
            if self._is_frontend_url(original_url):
                headers["Authorization"] = f"Bearer {self.config.api_key}"
            ensure_hf_authorization(headers, original_url)

            if self.config.use_hf_cli and parse_hf_resolve_url(original_url) and not resume:
                try:
                    await self._download_via_hf_cli(download_id, msg, final_path, part, headers, original_url)
                    return
                except HfCliUnavailable as exc:
                    LOG.info("HF CLI unavailable (%s); using HTTP", exc)
                except HfCliCancelled:
                    if os.path.exists(part):
                        os.remove(part)
                    await self._cancelled(download_id)
                    return
                except HfCliError as exc:
                    await self._failed(download_id, "network", str(exc))
                    return

            url = original_url
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

            await self._finish(download_id, msg, part, final_path, done, digest)
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
            self._drain_wait_queue()

    async def _run_engine(self, msg: dict[str, Any]) -> None:
        """A whole mflux or mlx-video model, fetched by its engine the way a job would, without loading it."""
        download_id, name, model = msg["download_id"], msg["engine"], msg.get("model") or ""
        state = self.active.get(download_id)
        engine = self.engines.get(name)
        started, start_time = None, time.time()
        self.paths_in_progress[download_id] = _engine_key(name, model)

        async def progress(done: int) -> None:
            nonlocal started
            started = done if started is None else started
            await self._progress(download_id, done, None, done - started, start_time)

        try:
            if not self.config.allow_model_downloads:
                await self._failed(download_id, "disabled", "model downloads are turned off")
                return
            if engine is None or not hasattr(engine, "download"):
                await self._failed(download_id, "invalid", f"this server doesn't run {name}")
                return
            if not model:
                await self._failed(download_id, "invalid", "no model named")
                return
            size = await engine.download(model, progress=progress, cancelled=lambda: bool(state and state.cancel))
            await self._complete(download_id, name, model, size, None, False)
        except asyncio.CancelledError:
            await self._cancelled(download_id)
        except DownloadFailed as exc:
            await self._failed(download_id, "network" if "connect" in str(exc).lower() else "engine", str(exc))
        finally:
            self.active.pop(download_id, None)
            self.paths_in_progress.pop(download_id, None)
            self._drain_wait_queue()

    async def _download_via_hf_cli(
        self,
        download_id: str,
        msg: dict[str, Any],
        final_path: str,
        part: str,
        headers: dict[str, str],
        original_url: str,
    ) -> None:
        def cancel_check() -> bool:
            state = self.active.get(download_id)
            return bool(state and state.cancel)

        async def progress_loop() -> None:
            while not cancel_check():
                if os.path.isfile(part):
                    done = os.path.getsize(part)
                    await self._progress(download_id, done, msg.get("bytes"), 0, time.time())
                elif os.path.isfile(final_path):
                    done = os.path.getsize(final_path)
                    await self._progress(download_id, done, msg.get("bytes") or done, 0, time.time())
                await asyncio.sleep(1.0)

        progress_task = asyncio.create_task(progress_loop())
        try:
            size = await hf_cli_download(
                self.config,
                url=original_url,
                dest_path=part,
                headers=headers,
                cancel_check=cancel_check,
            )
        finally:
            progress_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await progress_task

        if msg.get("sha256"):
            digest = await asyncio.to_thread(_file_sha256, part)
            if digest.lower() != msg["sha256"].lower():
                os.remove(part)
                await self._failed(download_id, "hash_mismatch", digest)
                return
        else:
            digest = await asyncio.to_thread(_file_sha256, part)

        if msg["filename"].lower().endswith(".safetensors") and not _safetensors_ok(part):
            os.remove(part)
            await self._failed(download_id, "invalid", "not a valid safetensors file (check access token)")
            return

        bytes_total = msg.get("bytes")
        if bytes_total is not None and size != bytes_total:
            os.remove(part)
            await self._failed(download_id, "size_mismatch", f"{size} vs {bytes_total}")
            return

        await self._finish(download_id, msg, part, final_path, size, digest)

    async def _finish(
        self, download_id: str, msg: dict[str, Any], part: str, final_path: str, size: int, digest: str | None
    ) -> None:
        """Moves a verified download into place, converting it first when asked."""
        if msg.get("convert") == CONVERT_FP8_TO_FP16:
            size = await self._convert(download_id, part, final_path)
            if size is None:
                return
            digest = None  # the hash checked was the fp8 download's
        else:
            os.replace(part, final_path)
        await self._complete(download_id, msg["folder"], msg["filename"], size, digest, False)

    async def _convert(self, download_id: str, part: str, final_path: str) -> int | None:
        """fp8 to fp16 beside the download, which is removed once the fp16 file is in place."""
        if not self._disk_ok(final_path, 2 * os.path.getsize(part)):
            os.remove(part)
            await self._failed(download_id, "disk_full", "not enough space to convert to fp16")
            return None
        state = self.active.get(download_id)
        if state:
            state.state = "verifying"
        converting = final_path + CONVERTING_SUFFIX
        # Cancelling the task (a user cancel or the agent shutting down) doesn't stop the worker thread, so it's
        # told to stop, and the fp16 file it may still be writing is removed here as well as by the thread.
        stop = threading.Event()
        try:
            size = await asyncio.to_thread(
                convert_fp8_to_fp16, part, converting, lambda: stop.is_set() or bool(state and state.cancel)
            )
        except (asyncio.CancelledError, ConversionCancelled):
            stop.set()
            with contextlib.suppress(FileNotFoundError):
                os.remove(converting)
            raise asyncio.CancelledError() from None
        except (ConversionError, OSError, ValueError, KeyError) as exc:
            os.remove(part)
            await self._failed(download_id, "invalid", f"couldn't convert to fp16: {exc}")
            return None
        os.replace(converting, final_path)
        os.remove(part)
        LOG.info("converted %s to fp16", os.path.basename(final_path))
        return size

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
            # A models folder that's missing a subfolder ComfyUI knows (a newer one, say) still takes downloads.
            known = set(DEFAULT_FOLDERS)
            if self.config.comfyui_models_dir:
                base = self.config.comfyui_models_dir
                with contextlib.suppress(OSError):
                    known |= {d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d))}
            return known

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
        # Done with the file, so a delete Comfier sends on hearing so isn't refused as busy.
        self.paths_in_progress.pop(download_id, None)
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


class DeleteRefused(Exception):
    def __init__(self, reason: str, detail: str):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


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


def _engine_key(engine: str, model: str) -> str:
    """Where paths_in_progress keeps an engine download; never a real path."""
    return f"\0{engine}\0{model}"


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
