# Comfier Agent

A ComfyUI custom node that connects **outbound** to a Comfier server and turns this ComfyUI into a Comfier worker.
ComfyUI needs no open port; the agent keeps one WebSocket open to Comfier, receives jobs, runs them on the local
ComfyUI, and uploads the results. It also downloads the models Comfier asks for and reports what's installed.

## Install

1. In Comfier, open **Servers → + Add a server**. Name it, choose who can use it, and choose **Add server and create
   a key**. Copy the key; Comfier only shows it once.
2. Copy this folder into ComfyUI's `custom_nodes` directory:

   ```bash
   git clone --depth 1 https://github.com/romkey/comfier-ui.git /tmp/comfier-ui
   cp -r /tmp/comfier-ui/comfyui/comfier_agent ComfyUI/custom_nodes/comfier_agent
   ```

   `aiohttp` ships with ComfyUI; there's nothing else to install. For preview images of 3D results (below), the agent
   also uses `numpy`, `Pillow` and `trimesh`; ComfyUI's 3D nodes usually bring them, or `pip install trimesh` in
   ComfyUI's environment.
3. Give it Comfier's URL and the key, either as environment variables before ComfyUI starts:

   ```bash
   export COMFIER_URL=https://comfier.example.com
   export COMFIER_API_KEY=cmf_...
   ```

   or with Docker:

   ```yaml
   environment:
     COMFIER_URL: https://comfier.example.com
     COMFIER_API_KEY: cmf_...
   ```

   or in the **Comfier** panel (below).
4. Restart ComfyUI. The server's setup page in Comfier updates when it connects.

## Install on a Mac (mflux, no ComfyUI needed)

On an Apple Silicon Mac the agent can run on its own, as a login service, and run image jobs with
[mflux](https://github.com/filipstrand/mflux), with or without ComfyUI. You need
[uv](https://docs.astral.sh/uv/) (`brew install uv`).

```bash
uv tool install --python 3.12 "comfier-agent[mac] @ git+https://github.com/romkey/comfier-ui.git#subdirectory=comfyui/comfier_agent"
comfier-agent setup            # Comfier's URL, this server's key, and whether this Mac runs ComfyUI too
comfier-agent service install  # starts now and at every login; restarts if it stops
```

The server's setup page in Comfier shows these lines with your URL and key filled in.

| Command | What it does |
|---|---|
| `comfier-agent setup` | Asks for Comfier's URL, the key, the server name, ComfyUI's URL (`none` if there isn't one) and the engines, and saves them to `~/.comfier/agent.json`. Takes `--url`, `--key`, `--name`, `--comfyui-url`, `--engines` and `-y` to skip the questions. |
| `comfier-agent service install` | Installs a launchd agent (`~/Library/LaunchAgents/com.comfier.agent.plist`) that starts at login and restarts on a crash. |
| `comfier-agent service status \| start \| stop \| restart \| uninstall` | Manages it. |
| `comfier-agent logs [-f]` | Shows `~/Library/Logs/comfier-agent.log`. |
| `comfier-agent doctor` | Checks the settings, Comfier and ComfyUI connections, the engines and their versions, memory and disk. |
| `comfier-agent pull MODEL` | Downloads an mflux model (for example `z-image-turbo`) by making a small test image, so the first real job doesn't wait for the download. |
| `comfier-agent lock -- COMMAND` | Runs a command while holding the GPU lock, so no Comfier job runs alongside it. |
| `comfier-agent run` | Runs in the foreground, which is what the service does. |

To update: `uv tool upgrade comfier-agent && comfier-agent service restart`. Comfier marks the server
**Update available** when there's a newer agent.

## The Comfier panel

ComfyUI's sidebar gets a **Comfier** tab. It shows whether the agent is connected, the server name, the Comfier URL,
the agent version, and whether it's taking jobs. When the connection fails, it says why: for example the key was revoked or replaced,
another ComfyUI is using the same key, or the agent is too old for this Comfier.

You can set the Comfier URL, API key, server name, and whether to share the queue from the panel. The saved key is
never shown again, only its last four characters. Changing the URL or key reconnects straight away. Settings go to
`comfier_agent.json` in ComfyUI's user directory (mode `0600`).

The panel's routes live under `/comfier-agent/` on ComfyUI. ComfyUI has no authentication, so anyone who can reach
ComfyUI's port can change them; keep that port off untrusted networks.

## Configuration

Environment variables override `comfier_agent.json`.

| Variable | Default | What it does |
|---|---|---|
| `COMFIER_URL` | *(required)* | Comfier's base URL. Must be `https` unless `COMFIER_ALLOW_INSECURE=true`. |
| `COMFIER_API_KEY` | *(required)* | This server's key from Comfier. |
| `COMFIER_BACKEND_NAME` | host name | Name reported to Comfier. |
| `COMFIER_COMFYUI_URL` | detected | Where the agent reaches ComfyUI, for example `http://127.0.0.1:8188`. |
| `COMFIER_ENABLED` | `true` | Set to `false` to load the node without connecting. |
| `COMFIER_SHARE_QUEUE` | `false` | Take Comfier jobs even while someone is using this ComfyUI directly. |
| `COMFIER_ALLOW_INSECURE` | `false` | Allow an `http` Comfier URL (development only). |
| `COMFIER_KEEP_OUTPUTS` | `false` | Keep result files in ComfyUI's output folder after uploading them. |
| `COMFIER_ALLOW_MODEL_DOWNLOADS` | `true` | Let Comfier ask this server to download models. |
| `COMFIER_MODEL_HOSTS` | any https host | Comma-separated hosts (and their subdomains) models may be downloaded from. |
| `COMFIER_MAX_DOWNLOAD_MB` | `200` | Largest input file (reference image, audio) the agent fetches for a job. |
| `COMFIER_UPLOAD_RETRY_SECONDS` | `600` | How long to keep retrying a result upload that fails with a network or server error. |
| `COMFIER_HEARTBEAT_SECONDS` | `10` | How often to send status. |
| `COMFIER_INVENTORY_POLL_SECONDS` | `60` | How often to check for added or removed models. |
| `COMFIER_INPUT_DIR`, `COMFIER_OUTPUT_DIR`, `COMFIER_MODELS_DIR` | ComfyUI's | Override ComfyUI's folders when the agent runs outside ComfyUI. |
| `HF_ENDPOINT` | — | Caching proxy or mirror base URL; rewrites `huggingface.co` / `hf.co` download links (like `huggingface_hub`). |
| `HF_TOKEN` | — | Used when Comfier did not send an `Authorization` header for a Hugging Face URL. |
| `HF_PROXY_TOKEN` | — | Optional token for the cache, sent on rewritten requests only. |
| `HF_PROXY_TOKEN_HEADER` | `X-Proxy-Token` | Header name for `HF_PROXY_TOKEN`. |
| `COMFIER_USE_HF_CLI` | `true` | Use the `hf` / `huggingface-cli` tool for Hub `/resolve/` links (falls back to HTTP). |
| `COMFIER_MAX_CONCURRENT_DOWNLOADS` | `1` | Parallel model downloads (`0` = no limit). |
| `COMFIER_ENGINES` | detected | Comma-separated engines to run: `comfyui`, `mflux`, `mlx_video`. Default: ComfyUI plus whichever of mflux and mlx-video are installed. Leave out `comfyui` on a Mac that doesn't run it. |
| `COMFIER_WORK_DIR` | `~/.comfier/work` | Where mflux and mlx-video jobs keep their inputs and results while they run. |
| `COMFIER_MLX_IDLE_UNLOAD_MINUTES` | `10` | Unload mflux's model after this long without a job (`0` keeps it loaded). |
| `COMFIER_MLX_LOAD_TIMEOUT_SECONDS` | `3600` | How long loading an mflux or mlx-video model may take, including its first download. The job's time limit starts after. |
| `COMFIER_GPU_LOCK` | `true` | Hold `~/.comfier/gpu.lock` while a job runs, and take no jobs while another program holds it. |
| `COMFIER_HOME` | `~/.comfier` | Where a standalone agent keeps its settings (`agent.json`), work files and lock. |

`comfier_agent.json` also accepts `max_model_download_gb` (50), `min_free_disk_gb` (10), `max_concurrent_downloads`
(1), `use_hf_cli` (true), and `allow_pickle_formats` (true). When free space on a job or model volume falls below
`min_free_disk_gb`, the
server stops taking jobs and Comfier shows which path is low.

## What it sends

- **Status**: machine type, ComfyUI version, CPU, RAM, GPU, free disk, queue length, and the models installed.
- **Node list**: ComfyUI's `object_info`, compressed, so Comfier can check a workflow's nodes before sending it.
- **Results**: only image, video, audio and 3D files (`png`, `jpg`, `webp`, `gif`, `mp4`, `webm`, `mov`, `wav`,
  `mp3`, `flac`, `ogg`, `glb`, `gltf`, `obj`, `ply`, `fbx`). Anything else a workflow writes is skipped with a
  warning.
- **3D previews**: a 1024×1024 JPEG of a job's first 3D result (`glb`, `gltf`, `obj` or `ply`), for browsers that
  can't show the model. It's rendered on the CPU in a separate process, gives up after two minutes, and is skipped
  (with a warning in ComfyUI's log) when `trimesh` isn't installed or the model can't be read. FBX isn't supported.
- **Timings**: how long each phase of a job took, used for Comfier's time estimates.
- **Failures**: which node failed and ComfyUI's error, with out-of-memory errors called out.

Every message follows [`protocol/agent-v1.schema.json`](../../protocol/agent-v1.schema.json).

If the connection drops, the agent reconnects with backoff and tells Comfier which jobs are still running, so they
carry on. Finished and failed jobs that happened while disconnected are reported after reconnecting. Uploads that
fail with a network error or a 5xx or 429 response are retried for up to `COMFIER_UPLOAD_RETRY_SECONDS`.

## Versioning

The agent reports `__version__` from `comfier_agent/__init__.py` in every hello, and logs it when ComfyUI starts.
Comfier reads the same file from its own build and marks a server **Update available** when its agent is older, or
**Newer than Comfier** when it's newer. Bump `__version__` with every change to the agent, or Comfier can't tell
old agents from new ones. `pyproject.toml` takes its version from there.

## mflux on Apple Silicon

On a Mac the agent can run image jobs with [mflux](https://github.com/filipstrand/mflux) instead of
ComfyUI. It's faster and avoids ComfyUI's Mac problems. Install mflux next to the agent
(`pip install "comfier-agent[mflux]"`), and the agent reports the `mflux` engine to Comfier. Admins
then add mflux workflows (**Settings → Workflows → Runs on: mflux**), which only go to servers with
mflux and enough memory.

- **One job at a time.** A server runs one Comfier job whichever engine it's on.
- **Memory is handed over.** On Apple Silicon, ComfyUI and mflux share memory. Before an mflux job the
  agent asks ComfyUI to unload its models, and before a ComfyUI job it stops mflux. mflux also unloads
  after `COMFIER_MLX_IDLE_UNLOAD_MINUTES` without a job.
- **The model stays loaded.** mflux runs in a worker process that keeps the last model loaded, so only
  the first job with a model pays to load it. Cancelling a job ends the worker; the next job starts a
  new one.
- **Models download ahead, or on first use.** On the server's page in Comfier, a style whose model isn't
  on the Mac yet has a **Download** button (and **Download all** covers every style), which fetches
  exactly the files mflux uses without loading the model. Otherwise mflux fetches it during the first
  job, which then takes longer. The agent reports which models are already downloaded.
- **The GPU lock.** While a job runs the agent holds `~/.comfier/gpu.lock` (an `flock` lock). If another
  program holds it, the agent takes no jobs until it's released, so your own scripts can keep Comfier
  jobs off the GPU while they run.

To run mflux without ComfyUI at all, set `COMFIER_ENGINES=mflux` and run the agent as a sidecar (below).

## MLX video on Apple Silicon

Video jobs can run with [mlx-video](https://github.com/Blaizzy/mlx-video), which runs LTX-2 / LTX-2.3
(text, image and audio to video) and Wan2.1 / Wan2.2 natively. The `[mac]` install includes it; on its own
it's `pip install "comfier-agent[video]"`. It's installed from a pinned GitHub commit, because mlx-video
isn't on PyPI.

- Each job runs mlx-video's command-line tool (`mlx_video.ltx_2.generate` or `mlx_video.wan_2.generate`)
  with the recipe's flags, so its model loads once per job. That's small next to generating a video, and
  a crash or an mlx-video change only affects that job. Progress comes from the tool's denoising bar.
- LTX recipes name a Hugging Face repo (`model_repo`, for example `prince-canuma/LTX-2.3-distilled`),
  which downloads on the first run. Wan needs weights converted to MLX first (see mlx-video's README);
  point `model_dir` at them.
- LTX-2.3 conversions don't include their text encoder, so LTX recipes also name one with
  `text_encoder_repo` (the presets use `mlx-community/gemma-3-12b-it-bf16`, about 26 GB). Comfier offers it
  for download alongside the model. Don't use `Lightricks/LTX-2` there: mlx-video then loads the wrong
  tokenizer and every prompt gives the same video.
- Memory matters: LTX-2.3 is a 22B video model plus the 12B text encoder, so plan on 96 GB. Wan2.2 TI2V 5B
  fits in 32 GB. Set `min_memory_gb` in the recipe and Comfier only sends the style to Macs with that much.
- The agent works around an mlx-video bug that makes LTX videos come out black on some Macs
  ([Blaizzy/mlx-video#55](https://github.com/Blaizzy/mlx-video/issues/55)).
- Before uploading, the agent moves the MP4's index to the front with `ffmpeg -c copy -movflags +faststart` (no
  re-encoding), so browsers can start playing right away. Without ffmpeg the file goes as is and Comfier fixes it.
- The one-job-at-a-time rule, the GPU lock and the memory handover with ComfyUI and mflux apply to video
  jobs too.

## Sidecar mode

The agent can also run as its own process next to ComfyUI instead of inside it (on a Mac, the
service above does this):

```bash
pip install ./comfyui/comfier_agent
comfier-agent run --comfyui-url http://127.0.0.1:8188
```

Set `COMFIER_INPUT_DIR`, `COMFIER_OUTPUT_DIR` and `COMFIER_MODELS_DIR` if it can't find ComfyUI's folders.

## Testing

The tests run the agent against a fake Comfier and a fake ComfyUI (no GPU or ComfyUI install needed) and validate
every message against the protocol schema:

```bash
python3 -m venv /tmp/comfier-venv
/tmp/comfier-venv/bin/pip install -e ".[test]" ruff
/tmp/comfier-venv/bin/ruff check comfier_agent tests && /tmp/comfier-venv/bin/pytest -q
```

The end-to-end test in the main repository runs this agent against real Rails, Sidekiq and Redis:

```bash
docker compose -f docker-compose.test.yml run --rm e2e
```

### Manual smoke test with a real ComfyUI

1. Start Comfier: `docker compose -f docker-compose.dev.yml up`, and sign in at <http://localhost:3000>.
2. Add a server under **Servers → + Add a server** and copy the key.
3. On the ComfyUI machine, install the agent as above with `COMFIER_URL` set to an address that machine can reach
   (for example `http://your-mac.local:3000`) and `COMFIER_ALLOW_INSECURE=true`, since the dev server is plain http.
4. Restart ComfyUI. The setup page should switch to connected, and the server's page should list its models.
5. Generate an image with a style whose models the server has. Watch progress on the result card, and check the
   result appears and the job shows on the server's page.
6. Stop ComfyUI mid-job and start it again: the job should be recovered and either resume or be retried.

## Security

- Anyone with this server's key can run arbitrary workflows on it, and custom nodes can run arbitrary code. Issue one
  key per server, and revoke keys you no longer use (**Servers → your server → Keys**).
- Whoever owns a server can see the prompts, images and results of every job that runs on it. Comfier warns people
  before their job runs on someone else's server.
- Download tokens you add in Comfier are only sent to the matching site and its subdomains. When a download redirects
  to another host, the agent drops every credential header.
