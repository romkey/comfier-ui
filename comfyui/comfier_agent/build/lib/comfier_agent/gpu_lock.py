"""A lock file other programs on this Mac can share with the agent, so a hand-run mflux or mlx-video
doesn't compete with a Comfier job for memory: `comfier-agent lock -- mflux-generate ...` waits for the
agent's job to finish, and the agent takes no jobs while it runs."""

from __future__ import annotations

import contextlib
import fcntl
import os
from pathlib import Path


class GpuLock:
    def __init__(self, path: str, enabled: bool = True):
        self.path = Path(os.path.expanduser(path))
        self.enabled = enabled
        self._fd: int | None = None

    def _open(self) -> int:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        return os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)

    def acquire(self, *, wait: bool = False) -> bool:
        if not self.enabled or self._fd is not None:
            return True
        fd = self._open()
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            os.close(fd)
            return False
        self._fd = fd
        return True

    def release(self) -> None:
        if self._fd is None:
            return
        with contextlib.suppress(OSError):
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        os.close(self._fd)
        self._fd = None

    @property
    def held(self) -> bool:
        return self._fd is not None

    def held_elsewhere(self) -> bool:
        """Another process has the lock right now."""
        if not self.enabled or self.held:
            return False
        if self.acquire():
            self.release()
            return False
        return True
