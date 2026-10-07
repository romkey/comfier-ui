# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses semantic versioning based on git tags.

## [Unreleased]

### Added
- **3D results**: Agent servers render a 1024×1024 preview image of a job's first 3D model and upload it with the
  results, so 3D work shows a picture in Results, on its page, and on shared and public pages instead of a file icon.
  The agent draws it on the CPU with `trimesh` (which ComfyUI's 3D nodes usually install) and skips it when that
  isn't available or the model can't be read; FBX isn't supported. Older agents and older Comfier servers carry on
  without previews. `AGENT_MAX_PREVIEW_MB` (default 25) caps the upload.
- **Message of the day**: Admins set a banner under Settings → Message of the day. It shows at the top of every
  page for signed-in users, who can dismiss it; changing the text shows it to everyone again.
- **Servers**: Owners and admins turn individual styles on or off per server from the server page's Styles table.
  Turned-off styles can't be picked for that server in the studio, jobs don't route there, and jobs for that style
  still waiting on the server move elsewhere (pinned ones fail with the reason).

### Changed
- **Settings**: `GENERATION_TIMEOUT_MINUTES` is removed; time limits are set under Settings instead.
- **Servers**: The "Styles it runs" allowlist in server settings is replaced by the per-style toggles. Existing
  allowlists are converted to the equivalent turned-off styles, and styles added later now run everywhere by default.

### Fixed
- **Agent servers**: Long jobs were marked lost partway through, then cancelled on the server, which older agents
  reported as completed with nothing to show. A status after a short gap now clears the server's offline marker
  (before, the next late status expired its jobs at once instead of after the two-minute grace), job progress counts
  as a sign of life, and the agent no longer holds its heartbeat for up to five minutes waiting on a busy ComfyUI.
- **Agent servers**: A finished job could come back with no outputs because the agent read ComfyUI's history before
  ComfyUI had written it (ComfyUI reports success first, and can unload models before saving history). The agent now
  waits up to two minutes for the history entry.
- **Agent servers**: A completion with no outputs now fails the generation with the server's explanation instead of
  showing it as succeeded with nothing to see. One that arrives while the job is being cancelled counts as the
  cancel, since agents before the interrupt fix reported cancelled jobs that way.
- **Agent servers**: Viewing a running agent job no longer queues HTTP polls that fail with "not an HTTP URI".
- **Workflows**: Long runs on agent servers were always stopped after one hour. Admins now set time limits per
  page under Settings → **Time limits** (defaults: image 20 minutes, video 4 hours, audio 30 minutes, 3D 1 hour),
  and can give a style its own **Time limit** on its workflow page, which also overrides the estimate-based limit.
- **Servers**: The Styles table no longer goes blank when the agent reports back after **Re-scan**. Turbo had left
  the frame's `src` pointing at the POST-only `rescan` URL, so the live reload hit a 404; `frame-refresh` now reloads
  from its declared URL.
- **Servers**: Styles **Re-scan** preserves the “Re-scanning…” state until fresh inventory arrives, live frame
  reloads no longer show “Content missing”, and style availability recomputes on every agent inventory message even
  when the model list hash is unchanged.
- **Servers**: Targeted Turbo Frame refresh restores `src` and forces a frame reload so styles and downloads stay
  current after lazy load strips the frame URL; all `frame-refresh` controllers now block Turbo's default targeted
  refresh so sibling frames cannot leave a `src`-less frame showing "Content missing" after Re-scan.
- **Workflows / servers**: Model download refresh streams target `workflow_models` and the downloads frame so
  layout `:queue` refreshes still update the server page while the workflow editor reloads models via stored frame `src`.
- **Servers**: Style availability treats cached ComfyUI `object_info` as authoritative for installed custom nodes,
  syncs node types when it arrives, and reads required nodes from the live workflow graph.

## [v0.12.8] - 2026-10-05

### Added
- **Servers**: **Re-scan** on an agent server’s Styles table asks Comfier Agent to refresh inventory and updates
  availability in place (no full page reload).

## [v0.12.7] - 2026-10-03

### Added
- **Servers**: Styles that need downloads show how many models are already on the server (for example, 2 of 5
  downloaded). Owners can clear finished entries from the server download log.

## [v0.12.6] - 2026-10-03

### Fixed
- **Comfier Agent**: Ruff lint fixes in the model download manager (CI on `main`).

## [v0.12.5] - 2026-10-03

### Added
- **Comfier Agent**: Hugging Face Hub downloads default to the `hf` CLI (with HTTP fallback), honoring
  `HF_ENDPOINT` and the Hub token. The Comfier panel configures CLI use and download concurrency (0 = unlimited).
- **Servers**: **Download all** queues every missing installable model across styles on an agent server.

## [v0.12.3] - 2026-10-02

### Added
- **Model downloads**: Comfier Agent and the Comfier downloader node honor `HF_ENDPOINT` on the ComfyUI machine,
  rewriting Hugging Face Hub URLs through a caching proxy while forwarding `HF_TOKEN` (and optional `HF_PROXY_TOKEN`).

## [v0.9.2] - 2026-09-28

### Fixed
- **Chat**: Auto-scroll when new messages stream in (listen for Turbo streams on `document`).
- **Chat**: Model picker keeps the full LiteLLM catalog after each reply instead of collapsing to the default model.

## [v0.9.1] - 2026-09-28

### Fixed
- **Chat**: Send works again after the first reply (Turbo composer updates kept the wrong DOM target).

## [v0.9.0] - 2026-09-28

### Changed
- GitHub Actions workflows run on `ubuntu-26.04` instead of the migrating `ubuntu-latest` image.

### Fixed
- Chat notice link URLs are validated as full `http`/`https` URLs (Brakeman `ValidationRegex`).

## [v0.8.0] - 2026-09-28

### Added
- **Comfier Agent**: ComfyUI servers connect outbound to Comfier for job routing, sharing, model downloads, and queue
  estimates. Members can register agent servers under **Servers** when admins allow it.
- **Chat** tab (after 3D Model) when LiteLLM is configured: saved conversations, model picker fed from the proxy,
  image upload for vision models, and async replies via Sidekiq.
- **Settings → Chat** (admins): default model for new conversations and an optional notice at the top of Chat with a
  link to a more capable chat system elsewhere.

## [v0.4.4] - 2026-09-26

### Fixed
- **Suggest placeholders** accepts more LiteLLM reply shapes (top-level workflow JSON, array wrappers, and
  JSON-encoded workflow strings) instead of failing while parsing the response.

## [v0.4.3] - 2026-09-26

### Fixed
- **Suggest placeholders** no longer returns HTTP 500 when the model reply has unexpected node shapes; errors show
  in the debug panel instead.

## [v0.4.2] - 2026-09-26

### Changed
- **Suggest placeholders** now updates the workflow form in place via Turbo Stream instead of reloading the page.
  Each run shows the LiteLLM request (model, endpoint, system prompt, user message) and the raw reply for debugging.

## [v0.4.1] - 2026-09-26

### Added
- Backends can opt in to deleting uploaded inputs, generated files, previews, and ComfyUI history after each run
  finishes. File deletion uses the Comfier downloader node; without it, only the history entry is cleared.

### Fixed
- **Suggest placeholders** on the workflow form hit the wrong route and returned 404 on existing workflows.

## [v0.4.0] - 2026-09-26

### Added
- Workflow assistant for admins: upload ComfyUI's API and regular exports together, optionally ask LiteLLM to suggest
  `{{placeholders}}` in the API JSON, and edit the assistant prompt under Settings → Workflow assistant.
  Configure `LITELLM_URL`, `LITELLM_API_KEY` and `LITELLM_MODEL` in `.env`.

## [v0.3.1] - 2026-09-25

### Fixed
- No notification was sent for generations queued with "Share result with everyone". Comfier now also logs when a
  user has notifications on but the server or their account can't deliver them.

## [v0.3.0] - 2026-09-25

### Fixed
- Generated images 404 in production when web and Sidekiq did not share the same Active Storage volume. Documented
  the requirement and added Sidekiq startup logging for Redis connectivity.
- Generations that finished on ComfyUI but stayed "Generating" in Comfier: polling now checks ComfyUI's queue, falls back through recent history, fails clearly when history never arrives, and stops retrying forever when output downloads fail. Opening a result or studio page re-schedules polling for stuck jobs.

### Added
- Notifications by email and/or Slack direct message when a generation finishes, fails or is cancelled, chosen
  under Settings → Notifications, optionally with the finished file attached. Email addresses and Slack accounts come
  from Authentik (a new `slack` scope); admins configure SMTP and the Slack bot in `.env`.
- Processing timestamps on generations: when ComfyUI started and finished executing a workflow, plus derived queue wait and processing durations. Queue estimates now prefer actual processing time over end-to-end elapsed time.
- Site footer with a GitHub link and the running app version.
- Cancel for queued and running generations: users can stop their own jobs, admins can stop any job. Comfier asks ComfyUI to dequeue or interrupt the prompt when it was already submitted.
- Sign-in with Authentik (OpenID Connect). Members of the admin group in Authentik become admins automatically.
- Image, Video, Audio and 3D Model pages: a prompt box, shape picker, optional "avoid" text, seed, length and input
  image, showing only the fields the chosen style needs.
- Results page with filters by kind and status, live-updating cards, a detail page with download, run again, tweak,
  retry and delete.
- Settings for everyone: default shape, things to always avoid, and a preferred server when there is more than one.
- Admin settings for ComfyUI backends: add several servers, check they're reachable, keep API tokens encrypted, and
  have jobs sent to the least busy one.
- Admin settings for workflows: upload or paste a ComfyUI API-format workflow, mark inputs with placeholders, set
  base resolution and frame rate, and order the styles users can pick from.
- A "Needs attention" section in admin settings that flags pages with no workflow and unreachable backends.
- Developer sign-in for local development: one email/password account set in `.env`, with a configurable name and
  admin flag, so a dev instance can run without Authentik.
- Model checks for workflows. Comfier works out which model files a workflow loads, lets admins add download links
  (typed in, or picked up from ComfyUI's regular export), and shows which backends have each file. Jobs only go to
  backends that have every model the chosen style needs, and missing models appear under "Needs attention".
- One-click model installs from the workflow page, with live progress. Downloads go through a small ComfyUI custom
  node that ships with Comfier (`comfyui/comfier_downloader`), or through ComfyUI-Manager for files in its catalog.
- Saving a workflow now returns to its page, so the model check is right there.
- Privacy notice every user must agree to before using Comfier. Admins can edit it under Settings → Privacy notice,
  and choose whether a wording change should ask everyone to agree again.
- Richer studio inputs when a workflow uses the matching placeholders: Quality (steps), Prompt strength (CFG),
  reference strength (denoise), lyrics, batch count, and clearer reference-image labels per page.
- **Use as reference** on image results, to start a new generation from an old output.
- **Shared** gallery: members can share finished results with everyone, optionally including the prompt and/or
  reference image. Admins can remove shares.
- **Queue** page with live updates and time estimates per job and for the whole queue, based on recent run times.
- Results show which workflow style was used (even after the workflow is removed).
- Workflow file upload fixed: exported JSON files upload correctly instead of producing a parse error.
- Workflows can be deleted from their own page as well as the list; the confirmation says how many past results stay.
- The workflow page lists models that won't install, with the reason and what to do, instead of hiding it in a
  tooltip. Install only counts files the backend can actually fetch.
- Backends with only ComfyUI-Manager: Comfier reads Manager's catalog (including subfolder and default-folder
  entries) and only offers files that are in it, using the catalog's link when the workflow has none.
- Hugging Face `/blob/` page links are turned into `/resolve/` file links, and the downloader node refuses web pages
  instead of saving them as model files.
- The test suite refuses to run against any database whose name doesn't end in `_test`.
- README badges for Tests, Lint, Security, Ruby, Rails, ComfyUI and MIT license. CI split into three workflows for
  separate status badges. MIT [LICENSE](LICENSE) added.
- Agreeing to the privacy notice works even if the user's other settings no longer validate.

## [v0.1.4] - 2026-09-25

### Added
- GitHub Actions workflows that build and publish Docker images to GHCR: [Staging](.github/workflows/staging.yml) on
  pushes to `staging`, and [Release](.github/workflows/release.yml) (manual on `main`) for production tags.
- `image_processing` gem (libvips) for Active Storage image variants.

### Changed
- PostgreSQL connection settings use `POSTGRES_*` variables in `.env` instead of hardcoded compose values.
