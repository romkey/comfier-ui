"""Stands in for `python -m comfier_agent.workers.entry_point mlx_video.ltx_2.generate ...` in tests.

Draws a progress bar the way rich does (\\r, no newline). The prompt picks the behaviour: "hang" waits to
be killed, "fail" exits 1 after printing an error."""

import json
import sys
import time

command, *argv = sys.argv[1:]
if command == "--probe":
    print(json.dumps({"version": "0.1.0", "models": ["prince-canuma/LTX-2.3-distilled"]}))
    sys.exit(0)

opts = dict(zip(argv[::2], argv[1::2]))
print("Loading model from prince-canuma/LTX-2.3-distilled", flush=True)
if opts.get("--prompt") == "fail":
    print("ValueError: height must be divisible by 64", file=sys.stderr, flush=True)
    sys.exit(1)
for step in range(1, 5):
    sys.stdout.write(f"\r\x1b[36mDenoising (distilled)\x1b[0m ━━━━━━━━ {step * 25}% {step}/4")
    sys.stdout.flush()
    time.sleep(0.3)
    if opts.get("--prompt") == "hang":
        time.sleep(60)
sys.stdout.write("\n")
with open(opts["--output-path"], "wb") as f:
    f.write(b"\x00\x00\x00\x18ftypmp42 " + " ".join([command, *argv]).encode())
print(f"Saved {opts['--output-path']}")
