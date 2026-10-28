# Plan: per-server model overrides

Some servers can't run the model files a style names. A Jetson Thor gives static-noise images from fp8
weights with `fp8_matrix_mult`, a Mac can't hold fp8 tensors at all, a 32 GB card wants a GGUF or a
smaller quant. Today Comfier handles exactly one of these cases, with a hard-coded rule:
`Agent::MacWeights` swaps fp8 files for fp16 on Apple Silicon. Every other case means a separate style
per server class, or a style that is blocked on half the fleet.

This plan makes that substitution **data-driven**. An admin or server owner records, per server, that
"when a style needs file X, use file Y instead, from this URL". Comfier then downloads Y to that server
and sends the style's graph to that server with Y in place of X.

Goals:

- One style, many servers. The style's graph keeps naming the canonical file; each server's overrides
  are applied only when a job is routed to it.
- Overrides drive the whole existing pipeline: availability, the `requires` list the agent checks,
  the download queue, and the graph rewrite at dispatch. No second code path.
- No agent or protocol change for the common case. The agent already downloads an arbitrary URL to a
  folder and filename, and already receives the rewritten graph.
- `MacWeights` keeps working unchanged and composes with overrides.

Non-goals for the first version (see "Later"):

- Changing node types (for example `UNETLoader` to `UnetLoaderGGUF`). Version one swaps filenames
  only and warns when the replacement needs a different loader.
- Overrides keyed by a server class or tag. Version one is per server; copying between servers is a
  cheap follow-up once there is a persisted hardware identity to key on.

---

## How it fits today's code

The substitution pipeline already exists; it just has one hard-coded source. Every place that must
see a server's actual filenames already goes through `Agent::MacWeights`:

| Call site | What it needs |
| --- | --- |
| `Agent::Availability#initialize` (`app/services/agent/availability.rb:39-45`) | the substituted model list for missing/strict-combo/disk checks |
| `Agent::Availability#strict_combo_reasons` (`:131-144`) | the rewritten graph, so combo checks see the override name |
| `Agent::Dispatcher#assign_message` (`app/services/agent/dispatcher.rb:80-100`) | rewritten `workflow` and the substituted `requires` |
| `Agent::ServerModels.for_workflow` / `names_for` (`app/services/agent/server_models.rb:27-35, 104-110`) | substituted names for the server page's delete/reload actions |
| `Agent::DownloadSender#disk_problem` (`app/services/agent/download_sender.rb:63`) | disk estimate for the stand-in |

`DownloadPlanner.plan!` (`app/services/agent/download_planner.rb:30-45`) builds a `ModelDownload` from
whatever model hash it receives, so an override that carries its own `url`, `sha256` and `bytes` is
downloaded with no further change.

The plan is therefore: add a second substitution source with the same interface as `MacWeights`, put a
small facade in front of both, and point those five call sites at the facade.

---

## 1. Data model

New table `model_overrides`:

| Column | Type | Notes |
| --- | --- | --- |
| `backend_id` | references, not null | the server the override applies to |
| `workflow_id` | references, nullable | nil = every style on this server that uses the file |
| `folder` | string, not null | folder of the file being replaced, as in `workflow_models` |
| `filename` | string, not null | the canonical file the style names |
| `replacement_filename` | string, not null | may differ in extension (`.gguf`) |
| `replacement_folder` | string, nullable | nil = same folder; needed when a GGUF lives in `unet` not `diffusion_models` |
| `url` | string, nullable | where to fetch it; nil means "already on the server, never download" |
| `sha256` | string, nullable | |
| `bytes` | bigint, nullable | filled by a HEAD request, like `EnrichWorkflowModelsJob` |
| `note` | string, nullable | "fp8 gives noise on sm_110" |
| `created_by_id` | references users, nullable | for the activity log |
| timestamps | | |

Indexes: unique on `(backend_id, workflow_id, folder, filename)` with `NULLS NOT DISTINCT` (Postgres 15+;
otherwise a coalesced expression index), plus `(backend_id)`.

Resolution order when a job is routed: a style-specific override wins over a server-wide one for the
same file. Matching uses `Agent::ModelMatcher`'s folder aliases (`unet` ↔ `diffusion_models`,
`clip` ↔ `text_encoders`) and basename, the same leniency `missing_models` already applies.

`ModelOverride` model: `belongs_to :backend`, `belongs_to :workflow, optional: true`, validations
(filename and replacement differ; URL host allowed by the same rule the agent's `_validate` enforces;
`sha256` is 64 hex chars when present), and `to_stand_in(model)` that produces the hash the pipeline
expects: the original requirement hash with `filename`, `folder`, `url`, `sha256`, `bytes` replaced and
`'replaces' => original filename`, with the `fp16_*` keys dropped so `MacWeights` doesn't re-swap it.

`Backend has_many :model_overrides, dependent: :destroy`; `Workflow has_many :model_overrides,
dependent: :destroy`.

## 2. Substitution service

`Agent::ModelOverrides.new(backend)` with the `MacWeights` interface:

- `active?` — the server has any overrides.
- `substitute(model, workflow:)` — the stand-in hash or nil.
- `models(models, workflow:)` — the list with stand-ins applied.
- `downloads(models, workflow:)` — same, but every stand-in with a URL is a fresh download; one
  without a URL is left out (the admin said it's already there).
- `problems(models, workflow:)` — reasons the override can't be used: the replacement has no URL and
  isn't on the server; the replacement's extension implies a different loader than the node uses
  (`.gguf` into `UNETLoader`); the replacement folder isn't one the server's inventory knows.
- `rewrite(graph, models, workflow:)` — renames literal input values through `{old => new}`, reusing
  `MacWeights#rewrite_node`'s shape (extract it to a shared helper rather than duplicate it).

`Agent::ModelSubstitution.new(backend, workflow)` is the facade: it applies overrides first, then
`MacWeights` to the result, and exposes the same five methods. Because override stand-ins drop the
`fp16_*` keys and usually no longer match `/fp8/`, `MacWeights` leaves them alone; an fp8 file an admin
deliberately overrides with another fp8 file on a Mac still gets the Mac treatment, which is correct.

Call-site changes are mechanical: replace `MacWeights.new(backend)` with
`ModelSubstitution.new(backend, workflow)` in the five places above. `Dispatcher#requires` must use the
substituted folder as well as filename, since a replacement may change folder.

### Legacy (non-agent) servers

Overrides apply to agent servers only. `ModelOverrides` ignores them on a legacy server, and the overrides page
lives under the agent-only server routes. Legacy servers download through ComfyUI-Manager or the downloader node
from bare folder/name/link requirements, so they couldn't fetch a replacement with its checksum anyway, and
`LegacyRunner` (which doesn't apply `MacWeights` either) stays unchanged.

### Submission's `model_set_hash`

`Agent::Submission.enqueue!` (`app/services/agent/submission.rb:34`) computes `model_set_hash` before a
server is chosen and `Perf::Predictor` and `Agent::Warmth` key on it. Leave it server-agnostic in
version one: the prediction is slightly wrong for an overridden server, but a per-server hash would
fragment the perf samples. Note it in the code.

## 3. Downloads

Nothing new in `DownloadPlanner`, `DownloadSender`, `DownloadLifecycle` or the agent.

One existing bug must be fixed first, or override downloads lose their metadata:
`Servers::DownloadsController#workflow_requirements` (`app/controllers/servers/downloads_controller.rb:89-96`)
and `Backends::AgentRunner#download` (`app/services/backends/agent_runner.rb:10-13`) collapse the model
hash to `ModelRequirement(directory, name, url)`, dropping `sha256`, `bytes` and `convert`. This
already breaks `MacWeights` conversions queued from the server page. Pass the full hash through to
`DownloadPlanner.manual!` for agent servers; keep `ModelRequirement` for the legacy `ModelInstaller`
path only.

When an override is saved with a URL and no `bytes`, enqueue a `EnrichModelOverrideJob` that HEADs the
URL for `bytes` (and `sha256` from an `ETag`/`X-Linked-ETag` on Hugging Face, as
`EnrichWorkflowModelsJob` does), so disk checks and progress bars work.

## 4. Invalidation

Saving, changing or deleting an override:

1. `RecomputeAvailabilityJob.perform_later(backend_id:)` when `workflow_id` is nil, else
   `(workflow_id:, backend_id:)`. This refreshes `workflow_availabilities` and broadcasts the
   `[backend, :styles]` frame.
2. Re-plan jobs `queued` or in `waiting_models` on this backend for the affected style(s) in place
   (`Agent::ModelOverrides.replan_jobs!`), covering the styles on both sides of a change of scope: release their
   old downloads, then queue the job if its files are now all there, wait for the new downloads if not, or
   reroute it elsewhere only if the style can't run on the server at all. A queued job would otherwise go out
   naming a replacement the server doesn't have yet. Rerouting every waiting job, as `ServerStyles#reroute_jobs!` does, would fail jobs whose only
   server still needs downloads, because the router treats such servers as ineligible.
3. `ActivityLog.record(kind: :model_override_changed, subject: backend, details: {...})`.

A job that has already been assigned keeps the graph it was dispatched with; changing an override
mid-run has no effect on it.

## 5. UI

Follow the per-style requirements editor (`app/views/admin/workflows/requirements.html.erb`): a
`form_with method: :patch` table of editable rows plus one blank row, no JSON widgets.

**Server page.** New nested resource `servers/:id/model_overrides` (`Servers::ModelOverridesController`,
`show` and `update`), guarded by `BackendPolicy#can_manage?`. Linked from the styles frame on the server
page (`app/views/servers/_styles.html.erb`) as "Model overrides", and from each style row's action
column as "Override models…" which opens the page filtered to that style.

The page lists every model the server's enabled styles require, de-duplicated by `(folder, filename)`,
each with the styles that use it, whether it is on the server, and its current override (if any):

| Style(s) | Folder / file the style names | On server? | Use instead (filename) | URL | sha256 | Scope | Note |
| --- | --- | --- | --- | --- | --- | --- | --- |

"Scope" is a select: *all styles on this server* / *only &lt;style&gt;*. Rows with an override show a
"Clear" checkbox. Saving runs the invalidation steps above and re-renders the frame.

**Admin style page.** The per-server availability table on `admin/workflows/:id/requirements`
(`requirements.html.erb:72-112`) gets a column showing which files are overridden on each server, so
an admin preparing a style sees at a glance why Thor will download something different.

**Availability reasons.** `Agent::Availability` already renders reasons and hints into the styles
frame; `ModelOverrides#problems` feeds that list, so a misconfigured override shows up as a blocked
reason on the server page rather than as a silent failure at dispatch.

## 6. Tests

- `test/services/agent/model_overrides_test.rb`: substitute (style-specific beats server-wide; folder
  aliases; no match), rewrite (renames literal inputs across nodes, leaves other strings alone),
  downloads (URL-less stand-in excluded), problems (loader/extension mismatch, unknown folder).
- `test/services/agent/model_substitution_test.rb`: override then MacWeights on an Apple Silicon
  backend; override of an fp8 file to a GGUF is not re-swapped.
- `test/services/agent/availability_test.rb`: with an override, the original file missing does not
  block; the replacement missing yields `needs_downloads` naming the replacement.
- `test/services/agent/dispatcher_test.rb`: `assign_message` carries the rewritten graph and the
  replacement in `requires`, with the replacement's folder.
- `test/integration/servers/model_overrides_test.rb`: owner can edit, non-owner gets 403,
  saving enqueues `RecomputeAvailabilityJob` and reroutes a `waiting_models` job.
- Regression test for the metadata-stripping fix in `Servers::DownloadsController`.

## 7. Phases

1. **Plumbing (no UI).** Migration and model; `ModelOverrides` and `ModelSubstitution`; swap the call sites;
   fix the download metadata bug (its own PR, first); invalidation hooks. Overrides can be
   created in the console. Ships behind nothing: with zero rows the behaviour is identical to today.
2. **Server page UI.** Controller, views, enrich job, activity log, tests.
3. **Admin visibility.** Override column on the admin requirements page; override problems surfaced
   as availability reasons; USER_GUIDE section.

Phase 1 is roughly a day; 2 and 3 together about the same.

---

## Later

- **Server classes.** Persist `hello.resources.platform.arch` and `machine_type` on `backends`
  (`Agent::MessageHandler#hello_system_json` already has them in hand) so overrides can be keyed by a
  class such as "Jetson Thor" or "Apple Silicon" and apply to every matching server. `MacWeights` then
  becomes a seeded, read-only class override rather than code.
- **Node-type overrides.** Let an override also name the loader node type to use, so a GGUF
  replacement rewrites `UNETLoader` → `UnetLoaderGGUF` (and adds the node type to `requires`).
- **Copy overrides** between servers, and import/export as JSON alongside the style export.
- **Agent-side conversion modes** beyond `fp8_to_fp16`, gated with `agent_at_least?` like
  `MacWeights::CONVERTING_AGENT`.
