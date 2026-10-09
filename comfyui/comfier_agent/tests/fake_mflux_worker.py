"""Stands in for comfier_agent.workers.mflux_worker in tests: same protocol, no mflux.

The prompt picks the behaviour: "hang" waits to be killed, "boom" reports an error, "crash" exits.
Every request after the first reports the model as already loaded, like the real worker."""

import json
import os
import sys
import time

if sys.argv[1:] == ["--inventory"]:
    print("mflux says hello")
    hub = os.environ.get("HF_HUB_CACHE") or ""
    fetched = [d.removeprefix("models--fake--") for d in (os.listdir(hub) if os.path.isdir(hub) else [])]
    print(json.dumps({"version": "9.9.9", "models": sorted({"z-image-turbo", *fetched}),
                      "catalog": ["dev", "z-image-turbo"]}))
    sys.exit(0)

if sys.argv[1:2] == ["--download"]:
    # Writes a fake model into HF_HUB_CACHE in two parts. "broken" fails, "slow" waits to be cancelled.
    model = sys.argv[2]
    repo = f"fake/{model}"
    print(json.dumps({"event": "repo", "repo": repo}), flush=True)
    if model == "broken":
        print(json.dumps({"event": "error", "message": "ConnectError: no route to huggingface.co"}), flush=True)
        sys.exit(1)
    blobs = os.path.join(os.environ["HF_HUB_CACHE"], "models--" + repo.replace("/", "--"), "blobs")
    os.makedirs(blobs, exist_ok=True)
    for part in range(2):
        with open(os.path.join(blobs, f"part{part}"), "wb") as f:
            f.write(b"x" * 1000)
        time.sleep(60 if model == "slow" else 0.1)
    print(json.dumps({"event": "done"}), flush=True)
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
