"""Job lifecycle."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import mimetypes
import os
import re
import shutil
import sys
import tempfile
import time
import traceback
from typing import Any

from comfier_agent.config import AgentConfig
from comfier_agent.engines.base import Engine, JobCancelled, JobContext, JobError
from comfier_agent.engines.comfyui import (  # noqa: F401  (re-exported for callers and tests)
    ComfyUIEngine,
    collect_output_files,
    find_missing_models,
    validate_workflow,
    validation_error_text,
)
from comfier_agent.gpu_lock import GpuLock
from comfier_agent.protocol import compact, replace_input_refs
from comfier_agent.status import ComfierJobStatus
from comfier_agent.transfer import UploadError, download_to_file, same_origin, upload_file_multipart

LOG = logging.getLogger("comfier_agent")

SANITIZE = re.compile(r"[^A-Za-z0-9._-]+")

MIME_EXTRA = {
    ".glb": "model/gltf-binary",
    ".gltf": "model/gltf+json",
    ".obj": "model/obj",
    ".ply": "model/ply",
    ".fbx": "application/octet-stream",
    ".webp": "image/webp",
    ".webm": "video/webm",
}

# The only result files the frontend accepts (it checks contents too); anything else is skipped.
OUTPUT_KINDS = {
    **dict.fromkeys((".png", ".jpg", ".jpeg", ".webp", ".gif"), "image"),
    **dict.fromkeys((".mp4", ".webm", ".mov"), "video"),
    **dict.fromkeys((".wav", ".mp3", ".flac", ".ogg"), "audio"),
    **dict.fromkeys((".glb", ".gltf", ".obj", ".ply", ".fbx"), "3d"),
}

OOM = re.compile(r"OutOfMemory|out of memory|CUDA error: out of memory", re.I)
MAX_DETAIL = 2000
MAX_TRACEBACK = 8000
# Still image of a 3D result, rendered in its own process so a bad mesh can't take ComfyUI down with it.
PREVIEW_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "preview.py")
PREVIEW_TIMEOUT_S = 120
# How long a job waits for another program to let go of the GPU lock.
GPU_WAIT_S = 600


def output_kind(filename: str) -> str | None:
    return OUTPUT_KINDS.get(os.path.splitext(filename)[1].lower())


async def render_preview(model_path: str, filename: str) -> str | None:
    """A JPEG of the model, or None when it can't be drawn (no trimesh, unreadable file, too slow).
    Never raises: the model is already uploaded, so a missing preview mustn't fail the job."""
    out_path = None
    rendered = False
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".jpg") as out:
            out_path = out.name
        proc = await asyncio.create_subprocess_exec(
            sys.executable, PREVIEW_SCRIPT, model_path, out_path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        try:
            _, err = await asyncio.wait_for(proc.communicate(), PREVIEW_TIMEOUT_S)
            rendered = proc.returncode == 0 and os.path.getsize(out_path) > 0
            if not rendered:
                detail = (err.decode(errors="replace").strip().splitlines() or ["no output"])[-1]
                LOG.warning("no preview for %s: %s", filename, detail)
        except asyncio.TimeoutError:
            LOG.warning("no preview for %s: rendering took over %ss", filename, PREVIEW_TIMEOUT_S)
        finally:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()
    except Exception as exc:
        rendered = False
        LOG.warning("no preview for %s: %s", filename, exc)
    finally:
        if out_path and not rendered:
            with contextlib.suppress(OSError):
                os.remove(out_path)
    return out_path if rendered else None


def is_oom(*texts: str | None) -> bool:
    return bool(OOM.search(" ".join(t for t in texts if t)))


def mime_for(filename: str) -> str:
    ext = os.path.splitext(filename)[1].lower()
    if ext in MIME_EXTRA:
        return MIME_EXTRA[ext]
    guessed, _ = mimetypes.guess_type(filename)
    return guessed or "application/octet-stream"


def sanitize_filename(name: str) -> str:
    base = os.path.basename(name.replace("\\", "/"))
    cleaned = SANITIZE.sub("_", base)[:100]
    return cleaned or "file.bin"


def input_dir(config: AgentConfig) -> str:
    if config.comfyui_input_dir:
        return config.comfyui_input_dir
    try:
        import folder_paths  # type: ignore

        return folder_paths.get_input_directory()
    except Exception:
        return tempfile.gettempdir()


def output_dir(config: AgentConfig) -> str:
    if config.comfyui_output_dir:
        return config.comfyui_output_dir
    try:
        import folder_paths  # type: ignore

        return folder_paths.get_output_directory()
    except Exception:
        return tempfile.gettempdir()


def delete_job_inputs(config: AgentConfig, job_id: str) -> None:
    base = os.path.join(input_dir(config), "comfier")
    if not os.path.isdir(base):
        return
    prefix = f"{job_id}_"
    for name in os.listdir(base):
        if name.startswith(prefix):
            path = os.path.join(base, name)
            if os.path.isfile(path):
                os.remove(path)


def sweep_stale_work(config: AgentConfig, max_age_s: int = 86400) -> None:
    """Job folders mflux and mlx-video left behind (the agent stopped mid-job), unless keep_outputs."""
    base = os.path.expanduser(config.work_dir)
    if config.keep_outputs or not os.path.isdir(base):
        return
    cutoff = time.time() - max_age_s
    for name in os.listdir(base):
        path = os.path.join(base, name)
        try:
            if os.path.isdir(path) and os.path.getmtime(path) < cutoff:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def sweep_stale_inputs(config: AgentConfig, max_age_s: int = 86400) -> None:
    base = os.path.join(input_dir(config), "comfier")
    if not os.path.isdir(base):
        return
    cutoff = time.time() - max_age_s
    for name in os.listdir(base):
        path = os.path.join(base, name)
        try:
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass




class JobManager:
    """One job slot shared by every engine: Comfier assigns a job only when this server asked for one,
    so ComfyUI, mflux and mlx-video never run Comfier jobs at the same time."""

    def __init__(self, config: AgentConfig, comfy, send, inventory_snap, on_terminal=None, engines=None,
                 gpu_lock: GpuLock | None = None):
        self.config = config
        self.comfy = comfy
        self.send = send
        self.inventory_snap = inventory_snap
        self.on_terminal = on_terminal
        self.engines: dict[str, Engine] = engines if engines is not None else {"comfyui": ComfyUIEngine(comfy)}
        self.gpu_lock = gpu_lock or GpuLock(config.gpu_lock_path, enabled=False)
        self.active: JobContext | None = None
        self.open_request_id: str | None = None
        # The engine that last ran a job, and so may still hold models in memory.
        self.warm_engine: str | None = None
        self._request_counter = 0
        self._progress_last: dict[str, tuple[float, str | None]] = {}
        self._terminal_buffer: list[dict] = []

    @property
    def prompt_ids(self) -> set[str]:
        """ComfyUI prompt ids of Comfier's own jobs, so the status can tell them from local use."""
        ids: set[str] = set()
        for engine in self.engines.values():
            ids |= engine.active_ids()
        return ids

    def drain_terminal_buffer(self) -> list[dict]:
        out = list(self._terminal_buffer)
        self._terminal_buffer.clear()
        return out

    def new_request_id(self) -> str:
        self._request_counter += 1
        rid = f"r_{self._request_counter}"
        self.open_request_id = rid
        return rid

    def void_request(self) -> None:
        self.open_request_id = None

    async def maybe_job_request(self, accepting: bool) -> None:
        if accepting and self.active is None and self.open_request_id is None:
            rid = self.new_request_id()
            await self.send({"type": "job.request", "request_id": rid})

    async def handle_assign(
        self,
        msg: dict[str, Any],
        *,
        accepting: bool,
        inventory,
        accepting_reason: str | None = None,
    ) -> None:
        job_id = msg["job_id"]
        request_id = msg.get("request_id")
        matched = self.open_request_id is not None and request_id == self.open_request_id
        # The frontend consumes its open request when it assigns, whichever id it used.
        self.void_request()
        if not matched:
            await self._reject(job_id, "busy", "no open job request")
            return

        if not accepting or self.active is not None:
            reason = "busy"
            if accepting_reason and "disk" in accepting_reason.lower():
                reason = "disk_full"
            await self._reject(job_id, reason, accepting_reason)
            return

        engine_name = msg.get("engine") or "comfyui"
        engine = self.engines.get(engine_name)
        if engine is None:
            await self._reject(job_id, "missing_engine", f"this server doesn't run {engine_name}")
            return
        problem = engine.check_requirements(msg.get("requires") or {}, inventory)
        if problem:
            await self._reject(job_id, *problem)
            return

        self.active = JobContext(job_id=job_id, request_id=request_id, engine=engine_name)
        await self.send({"type": "job.accepted", "job_id": job_id})
        asyncio.create_task(self._run_job(msg))

    async def _reject(self, job_id: str, reason: str, detail: str | None = None) -> None:
        await self.send({
            "type": "job.rejected",
            "job_id": job_id,
            "reason": reason,
            **({"detail": detail[:MAX_DETAIL]} if detail else {}),
        })

    async def handle_cancel(self, job_id: str) -> None:
        if self.active is None or self.active.job_id != job_id:
            await self.send({"type": "job.cancelled", "job_id": job_id})
            return
        ctx = self.active
        if not ctx.cancel_requested:
            ctx.cancel_requested = True
            ctx.cancel_requested_at = time.time()
        if ctx.phase == "inputs":
            await self._finish_cancel(ctx)
            return
        if await self.engines[ctx.engine].cancel(ctx):
            await self._finish_cancel(ctx)

    async def _finish_cancel(self, ctx: JobContext) -> None:
        if ctx.finished:
            return
        ctx.finished = True
        self._release(ctx)
        msg = {"type": "job.cancelled", "job_id": ctx.job_id}
        await self.send(msg)
        self._terminal_buffer.append(msg)
        if self.on_terminal:
            await self.on_terminal()

    def _release(self, ctx: JobContext) -> None:
        self.gpu_lock.release()
        delete_job_inputs(self.config, ctx.job_id)
        forget = getattr(self.engines.get(ctx.engine), "forget", None)
        if forget:
            forget(ctx)
        if self.active is ctx:
            self.active = None

    async def _take_gpu(self, ctx: JobContext) -> None:
        """Wait while another program on this machine holds the GPU lock."""
        deadline = time.monotonic() + GPU_WAIT_S
        while not self.gpu_lock.acquire():
            if ctx.cancel_requested:
                raise JobCancelled()
            if time.monotonic() >= deadline:
                raise JobError("execute", f"another program held {self.gpu_lock.path} for {GPU_WAIT_S // 60} min")
            await self._progress(ctx, "waiting_for_gpu", 0.0)
            await asyncio.sleep(1)

    async def _make_room_for(self, engine_name: str) -> None:
        """Unified memory is shared, so before one engine loads models the others let theirs go."""
        if self.warm_engine == engine_name:
            return
        # Before the first job we don't know who's warm (someone may have used ComfyUI directly).
        for name, engine in self.engines.items():
            if name != engine_name and self.warm_engine in (None, name):
                await engine.free_memory()
        self.warm_engine = engine_name

    async def _run_job(self, assign: dict[str, Any]) -> None:
        ctx = self.active
        assert ctx is not None
        engine = self.engines[ctx.engine]
        job_id = ctx.job_id
        workflow = assign["workflow"]
        upload_url = assign["upload_url"]
        timeout_s = assign.get("timeout_s") or 1800
        auth = f"Bearer {self.config.api_key}"
        t0 = time.time()
        timings = ctx.timings
        try:
            engine.validate(workflow)

            mapping: dict[str, str] = {}
            max_bytes = self.config.max_download_mb * 1024 * 1024
            for item in assign.get("inputs") or []:
                if ctx.cancel_requested:
                    raise JobCancelled()
                url = item["url"]
                if not same_origin(url, self.config.frontend_url):
                    raise JobError("inputs", "input URL must be on the frontend origin")
                tmp = tempfile.NamedTemporaryFile(delete=False)
                tmp.close()
                try:
                    await self._progress(ctx, "inputs", 0.1)
                    size = await download_to_file(
                        self.comfy.session,
                        url,
                        tmp.name,
                        auth_header=auth,
                        max_bytes=max_bytes,
                        expected_bytes=item.get("bytes"),
                    )
                    timings.input_bytes += size
                    fname = f"{job_id}_{item['id']}_{sanitize_filename(item.get('filename') or 'input')}"
                    mapping[item["id"]] = await engine.stage_input(ctx, tmp.name, fname)
                finally:
                    if os.path.exists(tmp.name):
                        os.remove(tmp.name)

            workflow = replace_input_refs(workflow, mapping)
            timings.mark_inputs_done()
            if ctx.cancel_requested:
                raise JobCancelled()
            await self._progress(ctx, "inputs", 1.0)

            await self._take_gpu(ctx)
            await self._make_room_for(ctx.engine)
            outputs = await engine.execute(ctx, workflow, timeout_s=timeout_s, progress=self._progress)
            files, skipped = split_allowed(outputs)
            previews = "3d" in (assign.get("previews") or [])
            uploaded_out = await self._upload_outputs(ctx, files, upload_url, auth, previews=previews)

            duration_ms = int((time.time() - t0) * 1000)
            msg = {
                "type": "job.completed",
                "job_id": job_id,
                "prompt_id": ctx.prompt_id,
                "outputs": uploaded_out,
                "duration_ms": duration_ms,
                "timings": timings.to_dict(),
            }
            warning = output_warning(uploaded_out, skipped)
            if warning:
                msg["warning"] = warning
            await self._terminal(compact(msg), ctx)
        except JobCancelled:
            await engine.abandon(ctx)
            await self._finish_cancel(ctx)
        except JobError as exc:
            await self._fail(
                ctx,
                exc.stage,
                exc.message,
                node_errors=exc.node_errors,
                node=exc.node,
                exception_type=exc.exception_type,
                traceback_tail=exc.traceback_tail,
            )
        except Exception as exc:
            LOG.exception("job %s failed", job_id)
            await self._fail(
                ctx,
                "execute",
                str(exc) or type(exc).__name__,
                exception_type=type(exc).__name__,
                traceback_tail=traceback.format_exc(),
            )

    async def _upload_outputs(
        self, ctx: JobContext, files: list[dict[str, str]], upload_url: str, auth: str, *, previews: bool = False
    ):
        """Upload each result, keeping its file on disk until the frontend has it or we give up. When the
        frontend takes previews, the first 3D result also gets a still image of it."""
        timings = ctx.timings
        uploaded = []
        preview_tried = False
        if files:
            timings.mark_upload_start()
        for idx, fdesc in enumerate(files):
            if ctx.cancel_requested:
                raise JobCancelled()
            await self._progress(ctx, "uploading", idx / len(files))
            path = await self.engines[ctx.engine].fetch_output(fdesc)
            name = fdesc["filename"]
            kind, mime = output_kind(name), mime_for(name)
            preview_path = None
            try:
                resp = await upload_file_multipart(
                    self.comfy.session,
                    upload_url,
                    auth_header=auth,
                    fields={"job_id": ctx.job_id, "node": fdesc["node"], "filename": name, "mime": mime, "kind": kind},
                    file_path=path,
                    filename=name,
                    mime=mime,
                    retry_for_s=self.config.upload_retry_s,
                    should_stop=lambda: ctx.cancel_requested,
                )
                file_bytes = os.path.getsize(path)
                if previews and kind == "3d" and not preview_tried:
                    preview_tried = True
                    preview_path = await render_preview(path, name)
            except UploadError as exc:
                if ctx.cancel_requested:
                    raise JobCancelled() from exc
                raise JobError("outputs", f"{name}: {exc}") from exc
            finally:
                if not self.config.keep_outputs and os.path.exists(path):
                    os.remove(path)
            timings.output_bytes += file_bytes
            uploaded.append({
                "upload_id": resp["upload_id"],
                "node": fdesc["node"],
                "kind": kind,
                "filename": name,
                "mime": mime,
                "bytes": file_bytes,
            })
            if preview_path:
                entry = await self._upload_preview(ctx, fdesc, preview_path, upload_url, auth)
                if entry:
                    timings.output_bytes += entry["bytes"]
                    uploaded.append(entry)
        if files:
            timings.mark_upload_end()
        return uploaded

    async def _upload_preview(self, ctx: JobContext, fdesc: dict[str, str], path: str, upload_url: str, auth: str):
        """A preview that doesn't make it is skipped; the model it shows is what the job is for."""
        name = f"{os.path.splitext(fdesc['filename'])[0]}_preview.jpg"
        mime = "image/jpeg"
        try:
            resp = await upload_file_multipart(
                self.comfy.session,
                upload_url,
                auth_header=auth,
                fields={
                    "job_id": ctx.job_id, "node": fdesc["node"], "filename": name, "mime": mime, "kind": "image",
                    "role": "preview",
                },
                file_path=path,
                filename=name,
                mime=mime,
                retry_for_s=self.config.upload_retry_s,
                should_stop=lambda: ctx.cancel_requested,
            )
            file_bytes = os.path.getsize(path)
        except UploadError as exc:
            if ctx.cancel_requested:
                raise JobCancelled() from exc
            LOG.warning("preview %s not uploaded: %s", name, exc)
            return None
        except Exception as exc:
            LOG.warning("preview %s not uploaded: %s", name, exc)
            return None
        finally:
            with contextlib.suppress(OSError):
                os.remove(path)
        return {
            "upload_id": resp["upload_id"],
            "node": fdesc["node"],
            "kind": "image",
            "role": "preview",
            "filename": name,
            "mime": mime,
            "bytes": file_bytes,
        }

    async def _progress(self, ctx: JobContext, phase: str, progress: float, **extra) -> None:
        ctx.phase = phase
        ctx.progress = progress
        now = time.time()
        last, last_phase = self._progress_last.get(ctx.job_id, (0, None))
        # A new phase always goes out; progress within a phase at most twice a second.
        if now - last < 0.5 and phase == last_phase and phase not in ("queued", "uploading"):
            return
        self._progress_last[ctx.job_id] = (now, phase)
        msg = {"type": "job.progress", "job_id": ctx.job_id, "phase": phase, "progress": progress}
        msg.update({k: v for k, v in extra.items() if v is not None})
        if ctx.node:
            msg["node"] = ctx.node
        await self.send(msg)

    async def _fail(self, ctx: JobContext, stage: str, error: str, **extra) -> None:
        await self._terminal(failure_message(ctx.job_id, stage, error, ctx.timings.to_dict(), **extra), ctx)

    async def _terminal(self, msg: dict, ctx: JobContext) -> None:
        if ctx.finished:
            return
        ctx.finished = True
        self._release(ctx)
        await self.send(msg)
        self._terminal_buffer.append(msg)
        if self.on_terminal:
            await self.on_terminal()

    def active_job_status(self) -> ComfierJobStatus | None:
        if not self.active:
            return None
        return ComfierJobStatus(
            job_id=self.active.job_id,
            state="running",
            progress=self.active.progress,
            node=self.active.node,
        )

    def active_jobs_for_hello(self) -> list[dict]:
        if not self.active:
            return []
        return [{"job_id": self.active.job_id, "prompt_id": self.active.prompt_id, "state": self.active.phase}]


def split_allowed(files: list[dict[str, str]]) -> tuple[list[dict[str, str]], list[str]]:
    allowed, skipped = [], []
    for fdesc in files:
        if output_kind(fdesc["filename"]):
            allowed.append(fdesc)
        else:
            LOG.warning("not uploading %s: only image, video, audio and 3D files are sent", fdesc["filename"])
            skipped.append(fdesc["filename"])
    return allowed, skipped


def output_warning(uploaded: list[dict], skipped: list[str]) -> str | None:
    parts = []
    if skipped:
        parts.append(f"skipped {len(skipped)} unsupported file(s): {', '.join(skipped)}")
    if not uploaded:
        parts.append("workflow produced no output files")
    return "; ".join(parts)[:MAX_DETAIL] or None


def failure_message(job_id: str, stage: str, error: str, timings: dict, **extra) -> dict[str, Any]:
    """job.failed with the detail the frontend's failure table reads. OOM always reads as OOM."""
    exception_type = extra.get("exception_type")
    if is_oom(error, exception_type) and "out of memory" not in error.lower():
        error = f"Out of memory: {error}"
    node = extra.get("node")
    node_errors = extra.get("node_errors")
    tail = extra.get("traceback_tail")
    return compact({
        "type": "job.failed",
        "job_id": job_id,
        "stage": stage,
        "error": error[:MAX_DETAIL],
        "timings": timings,
        "node": str(node) if node is not None else None,
        "exception_type": str(exception_type) if exception_type else None,
        "node_errors": node_errors if isinstance(node_errors, dict) and node_errors else None,
        "traceback_tail": tail[-MAX_TRACEBACK:] if tail else None,
    })
