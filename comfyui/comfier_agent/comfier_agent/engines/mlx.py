"""What the native Apple Silicon engines (mflux, mlx-video) share: recipes, a work folder per job,
and child processes that can be killed to cancel a job or give its memory back."""

from __future__ import annotations

import asyncio
import codecs
import collections
import contextlib
import logging
import os
import re
import shutil
import signal
from pathlib import Path
from typing import Any

from comfier_agent.engines.base import Engine, JobContext, JobError
from comfier_agent.protocol import find_unreplaced_placeholders

LOG = logging.getLogger("comfier_agent")

# The agent decides where results go; a recipe can't (matches EngineRecipe on the frontend).
RESERVED_OPTIONS = frozenset({"output", "output_path", "output_dir"})
# Recipe keys that describe the job rather than being passed to the command.
META_KEYS = frozenset({"command", "min_memory_gb"})
FLAG_KEY = re.compile(r"^[a-z][a-z0-9_]*$")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
STDERR_LINES = 40
KILL_GRACE_S = 5
# The folder holding the comfier_agent package. Inside ComfyUI it's only on sys.path in-process, so
# child processes get it through PYTHONPATH.
PACKAGE_ROOT = str(Path(__file__).resolve().parents[2])


def child_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(p for p in (PACKAGE_ROOT, env.get("PYTHONPATH")) if p)
    env.setdefault("PYTHONUNBUFFERED", "1")
    # Ask rich to draw progress bars even without a terminal, so their percentages can be read.
    env.setdefault("TTY_INTERACTIVE", "1")
    env.setdefault("TTY_COMPATIBLE", "1")
    env.setdefault("COLUMNS", "160")
    return env


def recipe_argv(recipe: dict[str, Any]) -> list[str]:
    """Recipe options as command-line arguments: {"image_strength": 0.4} is --image-strength 0.4,
    true is a bare flag, false or null leaves the flag out, and a list gives the flag several values."""
    argv: list[str] = []
    for key, value in recipe.items():
        if key in META_KEYS or value is None or value is False:
            continue
        flag = "--" + key.replace("_", "-")
        if value is True:
            argv.append(flag)
        elif isinstance(value, list):
            argv += [flag, *(arg_text(v) for v in value)]
        else:
            argv += [flag, arg_text(value)]
    return argv


def arg_text(value: Any) -> str:
    """No shell runs the command, so a home-relative path ("~/models/x") is expanded here."""
    text = str(value)
    return os.path.expanduser(text) if text.startswith("~/") else text


def work_root(config) -> Path:
    return Path(os.path.expanduser(config.work_dir))


class MlxEngine(Engine):
    """Subclasses set name, command (a regex for the recipe's "command"), and implement execute."""

    command = re.compile(r"$^")

    def __init__(self, config):
        self.config = config
        self.version: str | None = None
        self.models: list[str] = []
        self.extra_info: dict[str, Any] = {}

    def info(self) -> dict[str, Any]:
        info = {**self.extra_info, "models": list(self.models)}
        if self.version:
            info["version"] = self.version
        return info

    def check_requirements(self, requires: dict[str, Any], inventory) -> tuple[str, str] | None:
        return None

    def validate(self, workflow: Any) -> None:
        if not isinstance(workflow, dict):
            raise JobError("validate", "the recipe must be an object")
        command = workflow.get("command")
        if not isinstance(command, str) or not self.command.match(command):
            raise JobError("validate", f"{command!r} isn't a {self.name} command")
        for key, value in workflow.items():
            if key in RESERVED_OPTIONS:
                raise JobError("validate", f'"{key}" is set by the agent')
            if not FLAG_KEY.match(key):
                raise JobError("validate", f'"{key}" isn\'t a flag name')
            if isinstance(value, dict):
                raise JobError("validate", f'"{key}" can\'t be an object')
        placeholders = find_unreplaced_placeholders(workflow)
        if placeholders:
            raise JobError("validate", f"unreplaced placeholders: {', '.join(placeholders)}")

    def job_path(self, job_id: str) -> Path:
        return work_root(self.config) / job_id

    def job_dir(self, ctx: JobContext) -> Path:
        path = self.job_path(ctx.job_id)
        path.mkdir(parents=True, exist_ok=True)
        return path

    async def stage_input(self, ctx: JobContext, path: str, filename: str) -> str:
        inputs = self.job_dir(ctx) / "inputs"
        inputs.mkdir(exist_ok=True)
        dest = inputs / filename
        shutil.move(path, dest)
        return str(dest)

    async def fetch_output(self, fdesc: dict[str, Any]) -> str:
        return fdesc["path"]

    def forget(self, ctx: JobContext) -> None:
        """Inputs go once the job ends; results go after upload unless keep_outputs."""
        path = self.job_path(ctx.job_id)
        shutil.rmtree(path / "inputs", ignore_errors=True)
        with contextlib.suppress(OSError):
            path.rmdir()

    def outputs(self, ctx: JobContext, path: Path) -> list[dict[str, Any]]:
        if not path.is_file() or path.stat().st_size == 0:
            raise JobError("outputs", f"{self.name} finished without writing {path.name}")
        return [{"node": self.name, "filename": path.name, "path": str(path)}]


class ChildProcess:
    """A child process whose stderr is logged and whose last lines explain a failure."""

    def __init__(self, name: str, on_line=None):
        self.name = name
        self.on_line = on_line
        self.proc: asyncio.subprocess.Process | None = None
        self.stderr_tail: collections.deque[str] = collections.deque(maxlen=STDERR_LINES)
        self._stderr_task: asyncio.Task | None = None

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.returncode is None

    async def start(self, argv: list[str], *, stdin: bool = False, stdout: bool = False,
                    merged: bool = False) -> None:
        """stdout: a pipe the caller reads. merged: stdout joins stderr, both logged and passed to on_line."""
        self.stderr_tail.clear()
        self.proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE if stdin else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE if stdout or merged else asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.STDOUT if merged else asyncio.subprocess.PIPE,
            start_new_session=True,
            env=child_env(),
        )
        stream = self.proc.stdout if merged else self.proc.stderr
        self._stderr_task = asyncio.create_task(self._read_lines(stream))

    async def _read_lines(self, stream) -> None:
        # Progress bars redraw with \r and no newline, so split on both.
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        pending = ""
        while chunk := await stream.read(4096):
            pending += decoder.decode(chunk)
            *lines, pending = re.split(r"[\r\n]", pending)
            for line in lines:
                self._line(line)
            # A progress bar's latest state has no line end yet; let on_line see it now.
            if pending and self.on_line:
                self.on_line(ANSI.sub("", pending).strip())
        self._line(pending)

    def _line(self, raw: str) -> None:
        line = ANSI.sub("", raw).strip()
        if not line:
            return
        self.stderr_tail.append(line)
        LOG.debug("%s: %s", self.name, line)
        if self.on_line:
            self.on_line(line)

    def tail(self, lines: int = 12) -> str:
        return "\n".join(list(self.stderr_tail)[-lines:])

    async def wait(self) -> int:
        assert self.proc is not None
        code = await self.proc.wait()
        if self._stderr_task:
            with contextlib.suppress(asyncio.TimeoutError, asyncio.CancelledError):
                await asyncio.wait_for(self._stderr_task, 2)
        return code

    async def stop(self) -> None:
        """TERM the process group, then KILL it if it hasn't gone after a few seconds."""
        proc = self.proc
        if proc is None or proc.returncode is not None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, sig)
            try:
                await asyncio.wait_for(proc.wait(), KILL_GRACE_S)
                return
            except asyncio.TimeoutError:
                continue
