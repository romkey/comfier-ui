# Plan: MLX engines (mflux and MLX video) on Macs

ComfyUI is unreliable on Macs, and the native MLX tools are faster there. This plan lets the same
Comfier frontend send jobs to **mflux** (images) and an **MLX video tool** on Macs, while other jobs
keep going to ComfyUI. Each Mac runs **at most one job at a time**, whether that job is on ComfyUI,
mflux or the video tool.

Goals:

- One frontend, one queue, one set of studio pages. Users pick a style and the admin decides
  where it runs.
- No new server type to manage: a Mac is just another agent server.
- Installing and updating on a Mac takes a few commands, and the agent runs as a launchd service.

The video tool hasn't been chosen yet. It's the MLX video generator recommended in an earlier
discussion. Below it's called `mlx_video`; replace that with the real name when it's chosen. Nothing
before phase 6 depends on which tool it is.

---

## Approach: engines inside the existing agent

The agent already has the properties this needs:

- **It pulls work.** It sends `job.request` only when it's free, and `Agent::Dispatcher` answers
  with at most one `job.assign` (per-backend advisory lock plus compare-and-set).
- **It can run as a sidecar** (`python -m comfier_agent`) instead of inside ComfyUI.
- It already handles uploads, retries, timings, cancellation, reconnecting, model downloads and
  disk checks.

So instead of building a new backend, the agent gets **execution engines**:

```
Mac ──── comfier-agent (one process, one WebSocket, one job slot)
           ├── engine: comfyui    → local ComfyUI (optional)
           ├── engine: mflux      → mflux worker subprocess
           └── engine: mlx_video  → MLX video worker subprocess
```

One agent process has one job slot, so mutual exclusion across engines comes from the existing pull
model. There's no new distributed lock.

---

## Phase 1 — Engine interface in the agent (no behaviour change)

Refactor `comfier_agent/jobs.py` so everything ComfyUI-specific sits behind an `Engine`:

```python
class Engine(Protocol):
    name: str                                    # "comfyui", "mflux", "mlx_video"
    async def available(self) -> bool
    async def inventory(self) -> dict            # models/node types this engine can use
    async def run(self, job, progress) -> list[OutputFile]
    async def cancel(self, job_id) -> None
    async def free_memory(self) -> None          # unload models
```

- `ComfyUIEngine` wraps the current `_execute_ws`, `_finished_history`, `collect_output_files`,
  `ExecutionWatch` and `/interrupt` handling.
- `JobManager` keeps uploads, previews, timings, the terminal buffer and cancel flow, and calls
  `engine.run`.
- `StatusTracker`'s `busy_local` check stays ComfyUI-specific and only applies when the ComfyUI
  engine is configured.

Done when the existing agent tests pass unchanged.

---

## Phase 2 — Protocol

Additive changes to `protocol/agent-v1.schema.json`. The schema already allows extra properties, and
the protocol version stays 1.

- `hello` and `inventory` gain:
  ```json
  "engines": {
    "comfyui":   { "version": "0.3.x" },
    "mflux":     { "version": "x.y.z", "models": ["qwen-image", "flux2-klein-4b"] },
    "mlx_video": { "version": "x.y.z", "models": ["..."] }
  }
  ```
  An agent that doesn't send `engines` means `{"comfyui": {...}}`.
- `job.assign` gains `"engine": "mflux"`. For non-ComfyUI engines, `workflow` holds the rendered
  recipe (below) in place of an API graph.
- `job.request` is unchanged. The server already knows the agent's engines from `hello`.

Older agents never get non-ComfyUI jobs, because dispatch filters by engine (phase 3).

---

## Phase 3 — Frontend: engine-aware workflows, availability and dispatch

### 3.1 `Workflow.engine`
Migration: `workflows.engine` string, default `comfyui`, not null, with an index.

ComfyUI workflows keep `graph`. mflux and video workflows store a **recipe** in the same column,
using the same `{{placeholders}}` (`Workflow::PLACEHOLDERS`), so `WorkflowRenderer`, studio forms,
estimates, results and notifications need no engine-specific code:

```json
{
  "model": "qwen-image",
  "quantize": 8,
  "prompt": "{{prompt}}",
  "negative_prompt": "{{negative_prompt}}",
  "width": "{{width}}",
  "height": "{{height}}",
  "steps": "{{steps}}",
  "guidance": "{{cfg}}",
  "seed": "{{seed}}",
  "image": "{{image}}",
  "image_strength": "{{denoise}}",
  "loras": [{ "repo": "...", "scale": 1.0 }]
}
```

The video recipe adds `duration`/`frames` and `frame_rate`.

Validation by engine: `graph_is_api_format` applies only to `comfyui`, and a `RecipeSchema` per
engine checks keys, types and allowed models.

### 3.2 Admin UI
The workflow form gets an engine picker. For `comfyui` it shows the existing graph upload. For
`mflux`/`mlx_video` it shows a recipe editor (a JSON textarea with a schema hint, and a model
dropdown filled from what connected agents report). Engines are limited to sensible kinds:
`mflux` → image, `mlx_video` → video.

### 3.3 Availability
`Agent::Availability#compute` branches on engine:

- `comfyui`: unchanged (node types, models, `object_info`).
- `mflux`/`mlx_video`: the backend must advertise the engine. If the recipe's model is in the
  agent's engine inventory it's **ready**. If not, it's **needs downloads** (Hugging Face repo from a
  small model→repo table), using the existing download planner. Otherwise it's **blocked** with a
  reason ("This server doesn't run mflux").

`Agent::Requirements` gets an engine-aware `for(workflow)` that returns the model list for recipes,
so the download and disk-space checks are reused.

### 3.4 Dispatch and routing
- `Agent::Router` only considers backends where the workflow's availability is ready or needs
  downloads, which the 3.3 change gives it for free.
- `Agent::Dispatcher#claim` skips queued jobs whose workflow engine the requesting agent didn't
  advertise. This is a guard in case availability is stale.
- `assign_message` adds `engine` and sends the rendered recipe.

### 3.5 Servers page
Show each server's engines as badges ("ComfyUI", "mflux", "MLX video"). The speed and estimate
tables (`BackendSpeed`, `PerfStat`) are already keyed by workflow, so mflux timings get their own
estimates.

---

## Phase 4 — mflux engine

### 4.1 Worker subprocess
mflux gets most of its speed from keeping the model loaded, so the engine runs a **long-lived
worker subprocess** (`python -m comfier_agent.workers.mflux`) instead of `mflux-generate` per job:

- The agent and worker talk JSON lines over stdin/stdout: `load`, `generate`, `unload`, `ping`.
- The worker keeps the last model and quantization loaded. A job with a different model reloads it.
- Step progress goes back as `progress` lines, mapped to `job.progress`.
- **Cancel** sends SIGTERM, waits a few seconds, then SIGKILL, and the next job restarts the worker.
  mflux has no clean mid-step interrupt, so killing is the reliable way to cancel.
- A worker crash or out-of-memory fails the job (`stage: "execute"`, OOM detected from stderr) and
  doesn't affect the agent.
- Outputs are written to the agent's output dir and uploaded by the shared code.

### 4.2 Unified memory handoff
On Apple Silicon, ComfyUI and mflux share memory. Two engines holding models at once makes the Mac
swap heavily, so only one engine is "warm" at a time:

- Before an mflux or video job: if ComfyUI is configured, `POST /free`
  `{"unload_models": true, "free_memory": true}`, and unload the other MLX worker.
- Before a ComfyUI job: tell both MLX workers to `unload`, or stop them.
- After `COMFIER_MLX_IDLE_UNLOAD_MINUTES` (default 10) with no jobs, unload the MLX worker so the
  Mac is usable for other things.

### 4.3 Inventory
mflux models come from the Hugging Face cache. The engine reports which of a known model list are
fully cached (`huggingface_hub.scan_cache_dir`), plus local LoRAs from a configured folder.
`model_download` for an mflux model runs `hf download <repo>` with the existing `HF_ENDPOINT` /
`HF_TOKEN` / disk-limit handling.

### 4.4 Locking against people using the Mac directly
- **Comfier jobs:** one job slot (pull model).
- **Someone using ComfyUI directly:** the existing `busy_local` state stops new jobs (unless
  `COMFIER_SHARE_QUEUE`).
- **Someone running mflux or the video tool by hand (optional):** the agent holds an `flock` on
  `~/.comfier/gpu.lock` while a job runs, and reports `busy_local` when another process holds it. A
  tiny `comfier-agent lock -- mflux-generate ...` wrapper lets people's own scripts join the lock.

---

## Phase 5 — Installing and managing on a Mac

### 5.1 Packaging
`pyproject.toml` extras:

```toml
[project.optional-dependencies]
mflux = ["mflux>=..."]
video = ["<mlx video package>"]
mac = ["comfier-agent[mflux,video,preview]"]
```

Install, with `uv` handling Python versions and isolation:

```bash
uv tool install "comfier-agent[mac]"
```

### 5.2 CLI
- `comfier-agent setup`: asks for the Comfier URL, API key, server name, optional ComfyUI URL, and
  which engines to enable. It writes `~/.comfier/agent.json` (mode `0600`) and checks the
  connection. Environment variables still override the file, as now.
- `comfier-agent service install | uninstall | start | stop | status`: writes
  `~/Library/LaunchAgents/com.comfier.agent.plist` (`RunAtLoad`, `KeepAlive`) and loads it with
  `launchctl bootstrap gui/$UID`.
- `comfier-agent logs [-f]`: tails `~/Library/Logs/comfier-agent.log`.
- `comfier-agent doctor`: reports the Python and MLX versions, Apple Silicon and memory, which
  engines import cleanly, whether ComfyUI is reachable, free disk, and connectivity and key validity
  for Comfier.

### 5.3 Updating
`uv tool upgrade comfier-agent && comfier-agent service restart`. The existing **Update available**
badge on the Servers page already compares agent versions. The page should show this command for
sidecar installs.

### 5.4 Configuration additions

| Variable | Default | What it does |
|---|---|---|
| `COMFIER_ENGINES` | detected | Comma-separated engines to enable: `comfyui,mflux,mlx_video`. |
| `COMFIER_COMFYUI_URL` | — | Now optional. Without it the server is MLX-only. |
| `COMFIER_MLX_IDLE_UNLOAD_MINUTES` | `10` | Unload the MLX model after this long with no jobs. |
| `COMFIER_MFLUX_LORA_DIR` | `~/.comfier/loras` | Local LoRAs mflux recipes may use. |
| `COMFIER_GPU_LOCK` | `true` | Hold `~/.comfier/gpu.lock` while running and honour it from others. |

The ComfyUI custom-node install is unchanged for Linux and GPU servers.

---

## Phase 6 — MLX video engine

Once the tool is chosen, add `MlxVideoEngine` and its worker, built the same way as phase 4: the
same JSON-lines worker, memory handoff, cancel by kill, and HF-cache inventory. Map its options
(text-to-video, image-to-video, frames, fps, resolution) to a recipe schema, and register `video`
as its allowed kind. If the tool only has a CLI, the worker can shell out per job and give up
keeping the model loaded. Check how long it takes to load before deciding.

---

## Order and shipping

Each phase is one PR and safe to ship alone:

1. Engine interface refactor in the agent (ComfyUI only, tests unchanged).
2. Protocol fields (`engines`, `engine`). Old agents and the frontend ignore them.
3. Frontend: `Workflow.engine`, recipes, availability, dispatch guard, admin UI, server badges.
4. mflux engine and worker, memory handoff, inventory and downloads.
5. `setup` / `service` / `doctor` CLI, launchd, packaging; update the agent README and
   `docs/USER_GUIDE.md`.
6. MLX video engine.

Bump the agent `__version__` in every PR that touches `comfyui/comfier_agent`.

## Open questions

- Which MLX video tool? (Phase 6.)
- Should a Mac with both ComfyUI and mflux prefer mflux for image styles that exist in both forms,
  or should admins pick per workflow? This plan assumes per workflow: two styles, routed by engine.
- Does the Mac host stay a single-user machine, or should the GPU lock be on by default?
