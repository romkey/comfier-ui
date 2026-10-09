"""What every execution engine (ComfyUI, mflux, mlx-video) shares with the job lifecycle."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

from comfier_agent.job_timings import JobTimings

# progress(ctx, phase, fraction, **extra): sends job.progress, throttled by the JobManager.
ProgressFn = Callable[..., Awaitable[None]]


@dataclass
class JobContext:
    job_id: str
    request_id: str | None = None
    engine: str = "comfyui"
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


class Engine:
    """Runs one job's work. The JobManager owns everything around it: the job slot, input downloads,
    result uploads, previews, timings, and the messages to Comfier.

    An output descriptor is a dict with at least "node" and "filename"; fetch_output turns it into a
    local file the JobManager uploads and then deletes (unless keep_outputs)."""

    name = "engine"

    async def available(self) -> bool:
        return True

    async def refresh(self) -> None:
        """Re-read what info() reports (version, downloaded models). Called before each inventory scan."""

    def info(self) -> dict[str, Any]:
        """What hello and inventory report for this engine: version, models, and so on."""
        return {}

    def check_requirements(self, requires: dict[str, Any], inventory) -> tuple[str, str] | None:
        """(reason, detail) when this server can't run the job, else None."""
        return None

    def validate(self, workflow: Any) -> None:
        """Raise ValueError or JobError when the job's workflow/recipe is malformed."""

    async def stage_input(self, ctx: JobContext, path: str, filename: str) -> str:
        """Make a downloaded input available to the engine. Returns what replaces comfier-input://<id>.
        The JobManager deletes `path` afterwards if it still exists."""
        raise NotImplementedError

    async def execute(self, ctx: JobContext, workflow: Any, *, timeout_s: int, progress: ProgressFn) -> list[dict]:
        """Run the job and return its output descriptors. Raises JobError or JobCancelled."""
        raise NotImplementedError

    async def fetch_output(self, fdesc: dict[str, Any]) -> str:
        """A local path for an output descriptor."""
        raise NotImplementedError

    async def cancel(self, ctx: JobContext) -> bool:
        """Stop the job. True when it's gone already and the JobManager can report it cancelled now;
        False when execute will notice and raise JobCancelled."""
        return False

    async def abandon(self, ctx: JobContext) -> None:
        """After a cancel, make sure nothing of the job is left running."""

    async def free_memory(self) -> None:
        """Unload models so another engine has the memory."""

    def active_ids(self) -> set[str]:
        """Engine-side ids of Comfier's own work (ComfyUI prompt ids), so local activity can be told apart."""
        return set()

    async def close(self) -> None:
        pass
