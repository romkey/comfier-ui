"""Runs an installed console script by name in this Python, e.g.
`python -m comfier_agent.workers.entry_point mlx_video.ltx_2.generate --prompt ...`.

A uv tool install keeps its dependencies' scripts off PATH, and some script names (like
mlx_video.ltx_2.generate) aren't importable module paths, so the agent goes through the entry point."""

from __future__ import annotations

import importlib
import importlib.metadata
import sys


def find(command: str):
    for entry in importlib.metadata.entry_points(group="console_scripts"):
        if entry.name == command:
            module, _, attr = entry.value.partition(":")
            target = importlib.import_module(module)
            for part in (attr or "main").split("."):
                target = getattr(target, part)
            return target
    raise SystemExit(f"{command} isn't installed in {sys.executable}")


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: python -m comfier_agent.workers.entry_point COMMAND [ARGS...]")
    command = sys.argv[1]
    func = find(command)
    sys.argv = [command, *sys.argv[2:]]
    result = func()
    sys.exit(result if isinstance(result, int) else 0)


if __name__ == "__main__":
    main()
