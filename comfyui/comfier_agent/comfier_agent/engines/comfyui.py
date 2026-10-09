"""Runs jobs as prompts on the local ComfyUI."""

from __future__ import annotations

import asyncio
import logging
import os
import tempfile
import time
from typing import Any

from comfier_agent.engines.base import Engine, JobCancelled, JobContext, JobError, ProgressFn
from comfier_agent.job_timings import JobTimings
from comfier_agent.protocol import find_unreplaced_placeholders

LOG = logging.getLogger("comfier_agent")

# Folders ComfyUI treats as the same; matches Agent::ModelMatcher on the frontend.
FOLDER_ALIASES = {
    "unet": ("diffusion_models",),
    "diffusion_models": ("unet",),
    "clip": ("text_encoders",),
    "text_encoders": ("clip",),
}

MAX_DETAIL = 2000
# How long a cancelled job waits for ComfyUI to report the interrupt before giving up on it.
CANCEL_GRACE_S = 10
# ComfyUI sends execution_success before it writes the prompt's history entry, and may unload every
# model in between, so the entry can lag well behind a long job.
HISTORY_WAIT_S = 120
HISTORY_POLL_S = 0.5


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


def validation_error_text(error: Any) -> str:
    """ComfyUI's /prompt 400 body: {"error": {"message", "details"}, "node_errors": {...}}."""
    if isinstance(error, dict):
        return ": ".join(str(error[k]) for k in ("message", "details") if error.get(k)) or "invalid prompt"
    return str(error) if error not in (None, True) else "invalid prompt"


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


class ComfyUIEngine(Engine):
    name = "comfyui"

    def __init__(self, comfy):
        self.comfy = comfy
        self.prompt_ids: set[str] = set()
        self.version: str | None = None

    def info(self) -> dict[str, Any]:
        return {"version": self.version} if self.version else {}

    def active_ids(self) -> set[str]:
        return self.prompt_ids

    def check_requirements(self, requires: dict[str, Any], inventory) -> tuple[str, str] | None:
        node_types = inventory.node_types if inventory else []
        missing_nodes = [n for n in requires.get("node_types") or [] if n not in node_types]
        if missing_nodes:
            return "missing_nodes", ", ".join(missing_nodes)[:MAX_DETAIL]
        missing_models = find_missing_models(requires.get("models") or {}, inventory.models if inventory else {})
        if missing_models:
            return "missing_models", ", ".join(missing_models)[:MAX_DETAIL]
        return None

    def validate(self, workflow: Any) -> None:
        validate_workflow(workflow)
        placeholders = find_unreplaced_placeholders(workflow)
        if placeholders:
            raise JobError("validate", f"unreplaced placeholders: {', '.join(placeholders)}")

    async def stage_input(self, ctx: JobContext, path: str, filename: str) -> str:
        uploaded = await self.comfy.upload_image(path, filename)
        sub = uploaded.get("subfolder") or ""
        name = uploaded.get("name") or filename
        return f"{sub}/{name}" if sub else name

    async def execute(self, ctx: JobContext, workflow: Any, *, timeout_s: int, progress: ProgressFn) -> list[dict]:
        timings = ctx.timings
        result = await self.comfy.submit_prompt(workflow, job_id=ctx.job_id)
        timings.mark_prompt()
        if result.get("error"):
            error = validation_error_text(result["error"])
            raise JobError("validate", error, node_errors=result.get("node_errors"))

        ctx.prompt_id = result.get("prompt_id")
        if ctx.prompt_id:
            self.prompt_ids.add(ctx.prompt_id)
        ctx.phase = "queued"
        await progress(ctx, "queued", 0.0, queue_position=result.get("number"))
        await self._execute_ws(ctx, timeout_s=timeout_s, timings=timings, progress=progress)
        entry = await self._finished_history(ctx.prompt_id)
        files = collect_output_files(entry.get("outputs") or {})
        if not files:
            LOG.warning("prompt %s finished without any output files", ctx.prompt_id)
        return files

    def forget(self, ctx: JobContext) -> None:
        self.prompt_ids.discard(ctx.prompt_id or "")

    async def fetch_output(self, fdesc: dict[str, Any]) -> str:
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=os.path.splitext(fdesc["filename"])[1])
        tmp.close()
        async with await self.comfy.stream_view(fdesc["filename"], fdesc["subfolder"], fdesc["type"]) as resp:
            resp.raise_for_status()
            with open(tmp.name, "wb") as out:
                async for chunk in resp.content.iter_chunked(1024 * 1024):
                    out.write(chunk)
        return tmp.name

    async def cancel(self, ctx: JobContext) -> bool:
        if ctx.prompt_id and ctx.phase in ("queued", "running"):
            return await self._stop_prompt(ctx.prompt_id) == "pending"
        # Otherwise execution_interrupted ends the watch, or it gives up after CANCEL_GRACE_S.
        return False

    async def abandon(self, ctx: JobContext) -> None:
        # A cancel that landed mid-submit, or one ComfyUI never confirmed, can leave the prompt behind.
        if ctx.prompt_id:
            await self._stop_prompt(ctx.prompt_id)

    async def free_memory(self) -> None:
        try:
            await self.comfy.free_memory()
        except Exception:
            LOG.warning("couldn't ask ComfyUI to free memory", exc_info=True)

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

    async def _execute_ws(self, ctx: JobContext, *, timeout_s: int, timings: JobTimings, progress: ProgressFn) -> None:
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
                await progress(ctx, ctx.phase, watch.fraction(), node=watch.current_node)
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

    async def _finished_history(self, prompt_id: str) -> dict[str, Any]:
        deadline = time.monotonic() + HISTORY_WAIT_S
        while True:
            entry = (await self.comfy.history(prompt_id)).get(prompt_id) or {}
            if entry:
                return entry
            if time.monotonic() >= deadline:
                raise JobError("outputs", f"ComfyUI never recorded history for prompt {prompt_id}")
            await asyncio.sleep(HISTORY_POLL_S)


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
