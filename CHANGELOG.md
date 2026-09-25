# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses semantic versioning based on git tags.

## [Unreleased]

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
