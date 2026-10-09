"""Per-job phase timings (monotonic clock, milliseconds)."""

from __future__ import annotations

import time
from dataclasses import dataclass, field


def _ms(start: float | None, end: float | None) -> int:
    if start is None or end is None:
        return 0
    return max(0, int((end - start) * 1000))


@dataclass
class JobTimings:
    accepted_at: float = field(default_factory=time.monotonic)
    inputs_end: float | None = None
    prompt_at: float | None = None
    execution_start: float | None = None
    execution_end: float | None = None
    upload_start: float | None = None
    upload_end: float | None = None
    input_bytes: int = 0
    output_bytes: int = 0
    nodes_total: int = 0
    nodes_cached: int = 0

    def mark_inputs_done(self) -> None:
        self.inputs_end = time.monotonic()

    def mark_prompt(self) -> None:
        self.prompt_at = time.monotonic()

    def mark_execution_start(self) -> None:
        self.execution_start = time.monotonic()

    def mark_execution_end(self) -> None:
        self.execution_end = time.monotonic()

    def mark_upload_start(self) -> None:
        self.upload_start = time.monotonic()

    def mark_upload_end(self) -> None:
        self.upload_end = time.monotonic()

    def set_node_counts(self, *, total: int, cached: int) -> None:
        self.nodes_total = total
        self.nodes_cached = cached

    def to_dict(self) -> dict[str, int]:
        exec_end = self.execution_end or self.upload_start or time.monotonic()
        upload_end = self.upload_end or exec_end
        return {
            "inputs_ms": _ms(self.accepted_at, self.inputs_end),
            "local_queue_ms": _ms(self.prompt_at, self.execution_start),
            "execute_ms": _ms(self.execution_start, self.execution_end),
            "upload_ms": _ms(self.upload_start or self.execution_end, upload_end),
            "nodes_total": self.nodes_total,
            "nodes_cached": self.nodes_cached,
            "input_bytes": self.input_bytes,
            "output_bytes": self.output_bytes,
        }
