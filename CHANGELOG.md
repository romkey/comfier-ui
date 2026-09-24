# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses semantic versioning based on git tags.

## [Unreleased]

### Added
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
