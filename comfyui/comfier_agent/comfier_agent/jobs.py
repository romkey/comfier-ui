"""Job lifecycle."""

from __future__ import annotations

import asyncio
import logging
import mimetypes
import os
import re
import tempfile
import time
import traceback
from dataclasses import dataclass, field
from typing import Any

from comfier_agent.config import AgentConfig
from comfier_agent.job_timings import JobTimings
from comfier_agent.protocol import compact, find_unreplaced_placeholders, replace_input_refs
from comfier_agent.status import ComfierJobStatus
from comfier_agent.transfer import UploadError, download_to_file, same_origin, upload_file_multipart

LOG = logging.getLogger("comfier_agent")

# Folders ComfyUI treats as the same; matches Agent::ModelMatcher on the frontend.
FOLDER_ALIASES = {
    "unet": ("diffusion_models",),
    "diffusion_models": ("unet",),
    "clip": ("text_encoders",),
    "text_encoders": ("clip",),
}

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
# How long a cancelled job waits for ComfyUI to report the interrupt before giving up on it.
CANCEL_GRACE_S = 10


def output_kind(filename: str) -> str | None:
    return OUTPUT_KINDS.get(os.path.splitext(filename)[1].lower())


def is_oom(*texts: str | None) -> bool:
    return bool(OOM.search(" ".join(t for t in texts if t)))


def mime_for(filename: str) -> str:
    ext = os.path.splitext(filename)[1].lower()
    if ext in MIME_EXTRA:
        return MIME_EXTRA[ext]
    guessed, _ = mimetypes.guess_type(filename)
    return guessed or "application/octet-stream"


def collect_output_files(outputs: dict[str, Any], *, include_temp_if_empty: bool = True) -> list[dict[str, str]]:
    """Walk history outputs and collect file descriptors."""

    files: list[dict[str, str]] = []

    def walk(node_id: str, value: Any) -> None:
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict) and "filename" in item:
                    files.append(
                        {
                            "node": node_id,
                            "filename": item["filename"],
                            "subfolder": item.get("subfolder") or "",
                            "type": item.get("type") or "output",
                        }
                    )
                else:
                    walk(node_id, item)
        elif isinstance(value, dict):
            for v in value.values():
                walk(node_id, v)

    for node_id, node_out in outputs.items():
        walk(str(node_id), node_out)

    output_only = [f for f in files if f.get("type") == "output"]
    if output_only:
        return output_only
    if include_temp_if_empty and files:
        return [f for f in files if f.get("type") == "temp"]
    return files if not include_temp_if_empty else []


def validate_workflow(workflow: Any) -> None:
    if not isinstance(workflow, dict):
        raise ValueError("workflow must be an object")
    for node_id, node in workflow.items():
        if not isinstance(node, dict) or "class_type" not in node or "inputs" not in node:
            raise ValueError(f"node {node_id} missing class_type/inputs")


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



def find_missing_models(required: dict[str, list[str]], installed: dict[str, list[str]]) -> list[str]:
    """Required models not installed. A folder's aliases count, and "unknown" matches any folder by path or basename."""
    missing: list[str] = []
    for folder, names in required.items():
        if folder == "unknown":
            paths = {n for files in installed.values() for n in files}
            bases = {os.path.basename(n) for n in paths}
            missing += [
                f"{folder}/{name}" for name in names if name not in paths and os.path.basename(name) not in bases
            ]
            continue
        have = set()
        for f in (folder, *FOLDER_ALIASES.get(folder, ())):
            have.update(installed.get(f) or [])
        missing += [f"{folder}/{name}" for name in names if name not in have]
    return missing

@dataclass
class JobContext:
    job_id: str
    request_id: str | None = None
    prompt_id: str | None = None
    phase: str = "inputs"
    progress: float = 0.0
    node: str | None = None
    cancel_requested: bool = False
    cancel_requested_at: float | None = None
    finished: bool = False
    started_at: float = field(default_factory=time.time)
    ws_state: dict[str, Any] = field(default_factory=dict)
    timings: JobTimings = field(default_factory=JobTimings)


class JobManager:
    def __init__(self, config: AgentConfig, comfy, send, inventory_snap, on_terminal=None):
        self.config = config
        self.comfy = comfy
        self.send = send
        self.inventory_snap = inventory_snap
        self.on_terminal = on_terminal
        self.active: JobContext | None = None
        self.prompt_ids: set[str] = set()
        self.open_request_id: str | None = None
        self._request_counter = 0
        self._progress_last: dict[str, float] = {}
        self._terminal_buffer: list[dict] = []

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
            await self.send({
                "type": "job.rejected",
                "job_id": job_id,
                "reason": "busy",
                "detail": "no open job request",
            })
            return

        if not accepting or self.active is not None:
            reason = "busy"
            detail = accepting_reason
            if accepting_reason and "disk" in accepting_reason.lower():
                reason = "disk_full"
            await self.send({
                "type": "job.rejected",
                "job_id": job_id,
                "reason": reason,
                **({"detail": detail[:MAX_DETAIL]} if detail else {}),
            })
            return

        requires = msg.get("requires") or {}
        missing_nodes = [n for n in requires.get("node_types") or [] if n not in inventory.node_types]
        if missing_nodes:
            await self.send({
                "type": "job.rejected",
                "job_id": job_id,
                "reason": "missing_nodes",
                "detail": ", ".join(missing_nodes)[:MAX_DETAIL],
            })
            return
        missing_models = find_missing_models(requires.get("models") or {}, inventory.models)
        if missing_models:
            await self.send({
                "type": "job.rejected",
                "job_id": job_id,
                "reason": "missing_models",
                "detail": ", ".join(missing_models)[:MAX_DETAIL],
            })
            return

        self.active = JobContext(job_id=job_id, request_id=request_id)
        await self.send({"type": "job.accepted", "job_id": job_id})
        asyncio.create_task(self._run_job(msg))

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
        if ctx.prompt_id and ctx.phase in ("queued", "running"):
            if await self._stop_prompt(ctx.prompt_id) == "pending":
                await self._finish_cancel(ctx)
        # Otherwise execution_interrupted ends the watch, or it gives up after CANCEL_GRACE_S.

    async def _stop_prompt(self, prompt_id: str) -> str | None:
        """Takes the prompt out of ComfyUI wherever it is, going by ComfyUI's own queue rather than our
        WebSocket view of it, which can be stale. Returns "pending", "running" or None if it's gone."""
        try:
            queue = await self.comfy.queue()
        except Exception:
            LOG.warning("couldn't read the ComfyUI queue to cancel %s; interrupting", prompt_id, exc_info=True)
            queue = {}
        pending = {item[1] for item in queue.get("queue_pending") or [] if len(item) > 1}
        running = {item[1] for item in queue.get("queue_running") or [] if len(item) > 1}
        try:
            if prompt_id in pending:
                await self.comfy.delete_queue([prompt_id])
                return "pending"
            if prompt_id in running or not queue:
                await self.comfy.interrupt(prompt_id)
                return "running"
        except Exception:
            LOG.warning("couldn't stop prompt %s", prompt_id, exc_info=True)
        return None

    async def _finish_cancel(self, ctx: JobContext) -> None:
        if ctx.finished:
            return
        ctx.finished = True
        delete_job_inputs(self.config, ctx.job_id)
        self.prompt_ids.discard(ctx.prompt_id or "")
        if self.active is ctx:
            self.active = None
        msg = {"type": "job.cancelled", "job_id": ctx.job_id}
        await self.send(msg)
        self._terminal_buffer.append(msg)
        if self.on_terminal:
            await self.on_terminal()

    async def _run_job(self, assign: dict[str, Any]) -> None:
        ctx = self.active
        assert ctx is not None
        job_id = ctx.job_id
        workflow = assign["workflow"]
        upload_url = assign["upload_url"]
        timeout_s = assign.get("timeout_s") or 1800
        auth = f"Bearer {self.config.api_key}"
        t0 = time.time()
        timings = ctx.timings
        try:
            validate_workflow(workflow)
            placeholders = find_unreplaced_placeholders(workflow)
            if placeholders:
                raise JobError("validate", f"unreplaced placeholders: {', '.join(placeholders)}")

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
                    uploaded = await self.comfy.upload_image(tmp.name, fname)
                    sub = uploaded.get("subfolder") or ""
                    name = uploaded.get("name") or fname
                    mapping[item["id"]] = f"{sub}/{name}" if sub else name
                finally:
                    if os.path.exists(tmp.name):
                        os.remove(tmp.name)

            workflow = replace_input_refs(workflow, mapping)
            timings.mark_inputs_done()
            if ctx.cancel_requested:
                raise JobCancelled()
            await self._progress(ctx, "inputs", 1.0)

            result = await self.comfy.submit_prompt(workflow, job_id=job_id)
            timings.mark_prompt()
            if result.get("error"):
                error = validation_error_text(result["error"])
                raise JobError("validate", error, node_errors=result.get("node_errors"))

            ctx.prompt_id = result.get("prompt_id")
            if ctx.prompt_id:
                self.prompt_ids.add(ctx.prompt_id)
            ctx.phase = "queued"
            await self._progress(ctx, "queued", 0.0, queue_position=result.get("number"))

            await self._execute_ws(ctx, timeout_s=timeout_s, timings=timings)

            history = await self.comfy.history(ctx.prompt_id)
            entry = history.get(ctx.prompt_id) or {}
            files, skipped = split_allowed(collect_output_files(entry.get("outputs") or {}))
            uploaded_out = await self._upload_outputs(ctx, files, upload_url, auth)

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
            # A cancel that landed mid-submit, or one ComfyUI never confirmed, can leave the prompt behind.
            if ctx.prompt_id:
                await self._stop_prompt(ctx.prompt_id)
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

    async def _upload_outputs(self, ctx: JobContext, files: list[dict[str, str]], upload_url: str, auth: str):
        """Upload each result, keeping its file on disk until the frontend has it or we give up."""
        timings = ctx.timings
        uploaded = []
        if files:
            timings.mark_upload_start()
        for idx, fdesc in enumerate(files):
            if ctx.cancel_requested:
                raise JobCancelled()
            await self._progress(ctx, "uploading", idx / len(files))
            path = await self._download_output_file(fdesc)
            name = fdesc["filename"]
            kind, mime = output_kind(name), mime_for(name)
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
        if files:
            timings.mark_upload_end()
        return uploaded

    async def _download_output_file(self, fdesc: dict[str, str]) -> str:
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=os.path.splitext(fdesc["filename"])[1])
        tmp.close()
        async with await self.comfy.stream_view(fdesc["filename"], fdesc["subfolder"], fdesc["type"]) as resp:
            resp.raise_for_status()
            with open(tmp.name, "wb") as out:
                async for chunk in resp.content.iter_chunked(1024 * 1024):
                    out.write(chunk)
        return tmp.name

    async def _execute_ws(self, ctx: JobContext, *, timeout_s: int, timings: JobTimings) -> None:
        watch = ExecutionWatch(ctx, timings)
        self.comfy.add_ws_handler(watch.on_event)
        try:
            await self.comfy.ensure_ws()
            deadline = time.time() + timeout_s
            while not watch.done.is_set():
                if ctx.finished:
                    raise JobCancelled()
                if ctx.cancel_requested and time.time() - (ctx.cancel_requested_at or 0) >= CANCEL_GRACE_S:
                    # ComfyUI never said it stopped (it may already be done, or we missed the event).
                    raise JobCancelled()
                if time.time() >= deadline:
                    await self.comfy.interrupt(ctx.prompt_id)
                    raise JobError("execute", "timeout")
                await self._progress(ctx, ctx.phase, watch.fraction(), node=watch.current_node)
                try:
                    await asyncio.wait_for(watch.done.wait(), timeout=0.5)
                except asyncio.TimeoutError:
                    pass
        finally:
            self.comfy.remove_ws_handler(watch.on_event)
        if watch.interrupted and ctx.cancel_requested:
            raise JobCancelled()
        if watch.error:
            if ctx.cancel_requested:
                raise JobCancelled()
            raise watch.job_error()
        timings.set_node_counts(total=len(watch.nodes | watch.cached), cached=len(watch.cached))

    async def _progress(self, ctx: JobContext, phase: str, progress: float, **extra) -> None:
        ctx.phase = phase
        ctx.progress = progress
        now = time.time()
        last = self._progress_last.get(ctx.job_id, 0)
        if now - last < 0.5 and phase not in ("queued", "uploading"):
            return
        self._progress_last[ctx.job_id] = now
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
        delete_job_inputs(self.config, ctx.job_id)
        self.prompt_ids.discard(ctx.prompt_id or "")
        if self.active is ctx:
            self.active = None
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


def validation_error_text(error: Any) -> str:
    """ComfyUI's /prompt 400 body: {"error": {"message", "details"}, "node_errors": {...}}."""
    if isinstance(error, dict):
        return ": ".join(str(error[k]) for k in ("message", "details") if error.get(k)) or "invalid prompt"
    return str(error) if error not in (None, True) else "invalid prompt"


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


class ExecutionWatch:
    """Follows one prompt through ComfyUI's WebSocket events."""

    def __init__(self, ctx: JobContext, timings: JobTimings):
        self.ctx = ctx
        self.timings = timings
        self.done = asyncio.Event()
        self.error: dict | None = None
        self.interrupted = False
        self.nodes: set[str] = set()
        self.cached: set[str] = set()
        self.current_node: str | None = None
        self.node_progress = 0.0

    def on_event(self, data: dict) -> None:
        if data.get("prompt_id") and data["prompt_id"] != self.ctx.prompt_id:
            return
        handler = getattr(self, f"_on_{data.get('type') or data.get('event')}", None)
        if handler:
            handler(data)

    def fraction(self) -> float:
        active = [n for n in self.nodes if n not in self.cached]
        finished = len(active) - (1 if self.current_node in active else 0)
        return min(0.99, (finished + self.node_progress) / max(len(active), 1))

    def job_error(self) -> JobError:
        error = self.error or {}
        return JobError(
            "execute",
            error.get("exception_message") or "execution error",
            node=error.get("node_id"),
            exception_type=error.get("exception_type"),
            traceback_tail="\n".join((error.get("traceback") or [])[-20:]),
        )

    def _on_execution_start(self, _data: dict) -> None:
        self.ctx.phase = "running"
        self.timings.mark_execution_start()

    def _on_executing(self, data: dict) -> None:
        if data.get("node") is None:
            return
        self.current_node = str(data["node"])
        self.node_progress = 0.0
        self.ctx.node = self.current_node
        self.nodes.add(self.current_node)
        self.ctx.ws_state["executing_prompt"] = self.ctx.prompt_id

    def _on_progress(self, data: dict) -> None:
        max_v = float(data.get("max") or 1)
        self.node_progress = float(data.get("value") or 0) / max_v if max_v else 0.0

    def _on_execution_cached(self, data: dict) -> None:
        self.cached.update(str(n) for n in data.get("nodes") or [])

    def _on_execution_success(self, _data: dict) -> None:
        self.timings.mark_execution_end()
        self.done.set()

    def _on_execution_error(self, data: dict) -> None:
        self.error = data
        self.done.set()

    def _on_execution_interrupted(self, _data: dict) -> None:
        self.interrupted = True
        if not self.ctx.cancel_requested:
            self.error = {"exception_message": "interrupted"}
        self.done.set()


class JobError(Exception):
    def __init__(self, stage: str, message: str, **extra):
        super().__init__(message)
        self.stage = stage
        self.message = message
        self.node_errors = extra.get("node_errors")
        self.node = extra.get("node")
        self.exception_type = extra.get("exception_type")
        self.traceback_tail = extra.get("traceback_tail")


class JobCancelled(Exception):
    pass
