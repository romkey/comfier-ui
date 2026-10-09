"""Stands in for comfier_agent.workers.mflux_worker in tests: same protocol, no mflux.

The prompt picks the behaviour: "hang" waits to be killed, "boom" reports an error, "crash" exits.
Every request after the first reports the model as already loaded, like the real worker."""

import json
import os
import sys
import time

if sys.argv[1:] == ["--inventory"]:
    print("mflux says hello")
    print(json.dumps({"version": "9.9.9", "models": ["z-image-turbo"], "catalog": ["dev", "z-image-turbo"]}))
    sys.exit(0)

out = sys.stdout
loaded = None
for line in sys.stdin:
    req = json.loads(line)
    if req.get("op") != "generate":
        continue
    argv = req["argv"]
    prompt = argv[argv.index("--prompt") + 1] if "--prompt" in argv else ""
    model = argv[argv.index("--model") + 1] if "--model" in argv else None

    def emit(event, **extra):
        out.write(json.dumps({"event": event, "id": req["id"], **extra}) + "\n")
        out.flush()

    if model != loaded:
        emit("loading")
        loaded = model
    emit("loaded", pid=os.getpid())
    if prompt == "hang":
        time.sleep(60)
    if prompt == "crash":
        print("Traceback: something awful", file=sys.stderr, flush=True)
        sys.exit(3)
    if prompt == "boom":
        emit("error", type="RuntimeError", message="[metal] out of memory", traceback="Traceback ...")
        continue
    for step in range(1, 5):
        emit("progress", step=step, total=4)
    with open(req["output"], "wb") as f:
        f.write(b"\x89PNG " + " ".join(argv).encode())
    emit("done", output=req["output"])
