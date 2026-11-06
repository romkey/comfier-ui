"""Persistent protocol stand-in using the existing fake video CLI."""
import json
import os
import runpy
import sys
from pathlib import Path

fake = str(Path(__file__).with_name("fake_mlx_video.py"))
if sys.argv[1:] == ["--probe"]:
    runpy.run_path(fake, run_name="__main__")
out = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
for line in sys.stdin:
    req = json.loads(line)
    sys.argv = [fake, req["command"], *req["argv"], "--output-path", req["output"]]
    try:
        runpy.run_path(fake, run_name="__main__")
        event = {"event": "done", "id": req["id"]}
    except SystemExit as exc:
        event = {"event": "error", "id": req["id"], "message": f"exited with code {exc.code}"}
    out.write(json.dumps(event) + "\n")
    out.flush()
