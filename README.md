# Comfier

[![Tests](https://github.com/romkey/comfier-ui/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/romkey/comfier-ui/actions/workflows/tests.yml)
[![Lint](https://github.com/romkey/comfier-ui/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/romkey/comfier-ui/actions/workflows/lint.yml)
[![Security](https://github.com/romkey/comfier-ui/actions/workflows/security.yml/badge.svg?branch=main)](https://github.com/romkey/comfier-ui/actions/workflows/security.yml)
[![Ruby 4.0.7](https://img.shields.io/badge/Ruby-4.0.7-blue)](https://www.ruby-lang.org/)
[![Rails 8.1](https://img.shields.io/badge/Rails-8.1-blue)](https://rubyonrails.org/)
[![Works with ComfyUI](https://img.shields.io/badge/works%20with-ComfyUI-lightgrey)](https://github.com/comfyanonymous/ComfyUI)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

A simplified front end for [ComfyUI](https://github.com/comfyanonymous/ComfyUI). People sign in with Authentik,
type a prompt, pick a shape and get a result, without ever seeing a node graph. Admins decide what each page does by
uploading ComfyUI workflows, and point the app at one or more ComfyUI servers.

The navbar has **Image**, **Video**, **Audio** and **3D Model** (one simple form each), **Results** (everything you've
made) and **Settings** (your preferences, plus backends and workflows for admins).

See [docs/USER_GUIDE.md](docs/USER_GUIDE.md) for how to use it.

## Requirements

Everything runs in Docker; you only need Docker with Compose v2 on the host.

| Component | Version |
|---|---|
| Ruby | 4.0.7 |
| Rails | 8.1 |
| PostgreSQL | 18 |
| Redis | 8 |
| Sidekiq | 8 |
| Node | not used (importmap, vendored Bootstrap) |

## Setup

```bash
git clone <repo> comfier-ui && cd comfier-ui
cp .env.example .env
```

In `.env`, either fill in the Authentik settings or turn on developer sign-in, a single email/password account
that needs no identity provider. It only works in development, and only once both credentials are set:

```bash
DEV_LOGIN=true
DEV_LOGIN_EMAIL=you@example.com
DEV_LOGIN_PASSWORD=...          # e.g. openssl rand -base64 12
DEV_LOGIN_NAME=Your Name        # optional, default "Developer"
DEV_LOGIN_ADMIN=true            # false to see the app as a regular user
```

The account is updated from these values on every sign-in, and the web container reads them at boot, so restart it
after changing them.

### Authentik

Create an **OAuth2/OpenID Provider** and an application for it:

- Redirect URI: `${APP_URL}/auth/authentik/callback`
- Scopes: `openid`, `email`, `profile`, plus a scope that includes a `groups` claim
- Copy the issuer URL, client ID and client secret into `AUTHENTIK_ISSUER`, `AUTHENTIK_CLIENT_ID` and
  `AUTHENTIK_CLIENT_SECRET`

Anyone in the `AUTHENTIK_ADMIN_GROUP` group (default `comfier-admins`) is an admin. This is re-checked on every sign-in.

Comfier also requests a `slack` scope, which links users to Slack for notifications. In Authentik, create a
**Scope Mapping** with scope name `slack` and an expression that returns the user's Slack member ID and name, e.g.:

```python
return {
    "slack": {
        "uid": request.user.attributes.get("slack_uid"),
        "name": request.user.attributes.get("slack_name"),
    }
}
```

Add it to the provider's selected scopes. Comfier stores `uid` and `name` on every sign-in; users without a Slack
link just can't turn on Slack notifications. If the scope mapping isn't set up, sign-in still works.

### Notifications

Users can choose to be told by email and/or Slack DM when a generation finishes, fails or is cancelled, optionally
with the output attached. Email addresses and Slack IDs come from Authentik; users can't edit them.

- **Email**: set `SMTP_ADDRESS` (plus port, credentials and `MAIL_FROM`). Email is unavailable until it's set.
- **Slack**: create a Slack app with a bot user, give the bot the `chat:write`, `im:write` and `files:write` scopes,
  install it to the workspace, and put its bot token in `SLACK_BOT_TOKEN`. Slack is unavailable until it's set.
- Attachments over the size limit (default `20` MB total per message) are replaced by a link. Admins can change the
  limit under **Settings → Notifications**.

### Environment variables

| Variable | Purpose |
|---|---|
| `APP_URL` | Public URL of the app |
| `APP_HOST` | Hostname allowed by Rails host authorization |
| `AUTHENTIK_ISSUER`, `AUTHENTIK_CLIENT_ID`, `AUTHENTIK_CLIENT_SECRET` | OIDC provider |
| `AUTHENTIK_ADMIN_GROUP` | Authentik group whose members are admins |
| `DEV_LOGIN` | `true` enables developer sign-in (development only) |
| `DEV_LOGIN_EMAIL`, `DEV_LOGIN_PASSWORD` | The developer sign-in credentials; both required |
| `DEV_DNS` | Development only: LAN DNS server for resolving private ComfyUI hostnames |
| `DEV_LOGIN_NAME`, `DEV_LOGIN_ADMIN` | The developer account's display name, and whether it's an admin (default `true`) |
| `SECRET_KEY_BASE` | Production only; `bin/rails secret` |
| `ACTIVE_RECORD_ENCRYPTION_*` | Production only; `bin/rails db:encryption:init`. Encrypts backend API tokens |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USERNAME`, `POSTGRES_PASSWORD` | PostgreSQL connection |
| `POSTGRES_DATABASE`, `POSTGRES_DATABASE_TEST`, `POSTGRES_DATABASE_PRODUCTION` | Database name per environment |
| `POSTGRES_HOST_PORT` | Dev only: host port when compose publishes Postgres |
| `TIME_ZONE`, `GENERATION_TIMEOUT_MINUTES`, `SIDEKIQ_CONCURRENCY`, `FORCE_SSL`, `ASSUME_SSL` | Optional tuning |
| `MODEL_DOWNLOAD_TIMEOUT_HOURS` | How long a model download may run before it's marked failed (default `12`) |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` | Outgoing mail server for email notifications |
| `SMTP_AUTHENTICATION`, `SMTP_ENABLE_STARTTLS`, `SMTP_DOMAIN` | SMTP options (defaults `plain`, `true`, `APP_URL` host) |
| `MAIL_FROM` | Sender address for notification emails |
| `SLACK_BOT_TOKEN` | Slack bot token (`xoxb-…`) for Slack DM notifications |
| `NOTIFICATION_ATTACHMENT_MAX_MB` | Default attachment size limit when the database is first created (default `20`; editable in Settings → Notifications) |

## Running locally

```bash
docker compose -f docker-compose.dev.yml up
```

This starts Postgres, Redis, the web server and Sidekiq, with the code bind-mounted and gems cached in a shared
volume. The web container runs `db:prepare`. No workflows are seeded, so the Image, Video, Audio and 3D Model pages
stay empty until an admin adds workflows under **Settings → Workflows**. Open <http://localhost:3000>.

To try the whole flow without a GPU, start the fake ComfyUI server and add a backend with URL
`http://fake-comfyui:8188` under **Settings → Backends**. It finishes every prompt after three seconds with a
generated PNG. It also pretends to have the Comfier downloader node and starts with only the Stable Diffusion 1.5
checkpoint, so model installs can be tried out too (downloads "finish" without fetching anything, and are forgotten
when it restarts).

```bash
docker compose -f docker-compose.dev.yml --profile fake up
```

A real ComfyUI server on your network is added by URL the same way. Remember the URL is used from inside the
containers: `localhost` means the container itself (use `host.docker.internal` for a ComfyUI running on your Mac).
If the server has a private hostname that only your LAN DNS knows, Docker Desktop won't resolve it; set `DEV_DNS` in
`.env` to your LAN DNS server and run `docker compose -f docker-compose.dev.yml up -d` to recreate the containers.

Useful extras:

```bash
docker compose -f docker-compose.dev.yml --profile tools run --rm migrate   # run migrations
docker compose -f docker-compose.dev.yml run --rm web bin/rails console
```

The Sidekiq dashboard is at `/admin/sidekiq` (admins only).

## Testing

```bash
docker compose -f docker-compose.test.yml run --rm test
```

Runs the Minitest suite against a throwaway Postgres on tmpfs. ComfyUI and Authentik are always stubbed (WebMock and
OmniAuth test mode); the tests never touch the network. Don't run `bin/rails test` inside the dev `web` container: its
`DATABASE_URL` points at the development database, and loading fixtures there would replace your data. The suite
refuses to start unless the database name ends in `_test`.

The ComfyUI downloader node has its own tests, which need only Python 3.8+ (no ComfyUI):

```bash
python3 -m unittest discover -s comfyui/tests
```

## Linting

```bash
docker compose -f docker-compose.lint.yml run --rm rubocop
docker compose -f docker-compose.lint.yml run --rm brakeman
```

## Deployment

`Dockerfile` builds the production image (multi-stage, non-root, assets precompiled). The version is baked in at build
time with `--build-arg APP_VERSION=...` and read through `AppVersion`. The newest `v*` git tag is the canonical version;
there is no `VERSION` file.

`docker-compose.production.yml` runs the image as `web`, `sidekiq` and a `migrate` tool, with bundled Postgres and
Redis. Set `COMFIER_IMAGE` to choose the image, and fill in the production secrets in `.env`.

```bash
docker compose -f docker-compose.production.yml --profile tools run --rm migrate
docker compose -f docker-compose.production.yml up -d
```

Uploaded inputs and generated outputs are stored with Active Storage on local disk. Back them up along with the
database. Both `web` and `sidekiq` must mount the same path (Docker volume or bind mount) — Sidekiq writes generated
files during background jobs; the web process serves them. If only one container has the mount, images 404 with
`ActiveStorage::DiskController` in the logs.

Background jobs run in the `sidekiq` container, not `web`. Tail Sidekiq separately:

```bash
docker compose logs -f sidekiq
```

On startup Sidekiq logs the Redis URL it connected to. Web and Sidekiq must share the same `REDIS_URL` (compose
default: `redis://redis:6379/0`, using the compose service name `redis`).

To debug missing images or stuck jobs:

```bash
docker compose ps                                           # sidekiq must be running
docker compose exec sidekiq printenv REDIS_URL
docker compose exec web printenv REDIS_URL                # must match sidekiq
docker compose exec redis redis-cli LLEN queue:default    # pending jobs, if any
docker compose exec sidekiq ls -la /rails/storage
docker compose exec web ls -la /rails/storage
```

Both containers should list the same blob directories under `/rails/storage`. If neither has files, regenerate after
fixing storage — old blob records in Postgres won't recover.

### Preparing ComfyUI servers for model installs

Comfier checks which models each backend has through ComfyUI's own `/models` API; that needs nothing extra. To
install missing models from the workflow page, a backend needs one of these:

**The Comfier downloader node (recommended).** It downloads any direct link into the right models folder. Copy
`comfyui/comfier_downloader` into ComfyUI's `custom_nodes` folder and restart ComfyUI:

```bash
docker cp comfyui/comfier_downloader <comfyui-container>:/path/to/ComfyUI/custom_nodes/   # or copy it onto the volume
docker restart <comfyui-container>
```

If ComfyUI runs with `--base-directory`, `custom_nodes` lives under that directory. Files go into the first path
ComfyUI lists for each folder (normally `models/<folder>` under ComfyUI's base directory). For gated Hugging Face
repos or CivitAI files, set `HF_TOKEN` and/or `CIVITAI_TOKEN` in ComfyUI's environment; each token is only sent to its
own site. Use **Re-check** on the backend (or save it) so Comfier notices the node.

**ComfyUI-Manager 4 (fallback).** When the node isn't installed, Comfier asks Manager instead, which only downloads
files that are in Manager's own model catalog, at exactly the folder and file name the workflow uses. Comfier reads the
catalog when it checks the backend, and only offers Install for files that are in it; the workflow page lists the rest
and why. Many workflows use files Manager doesn't have, so the node is the practical choice. Manager refuses downloads
from other machines
unless `network_mode = personal_cloud` (and `security_level` is `normal` or lower) in
`<base directory>/user/__manager/config.ini`; restart ComfyUI after changing it. Only do this if the ComfyUI port
isn't reachable from untrusted networks.

GitHub Actions runs on every pull request and on pushes to `staging` and `main`: [Tests](.github/workflows/tests.yml)
(Rails and the ComfyUI downloader node), [Lint](.github/workflows/lint.yml) (RuboCop), and
[Security](.github/workflows/security.yml) (Brakeman, bundler-audit, importmap audit). Work branches target
`staging`; see the deployment rules in `.cursor/rules/deployment-rules.mdc`.

Docker images are built on GitHub and published to `ghcr.io/<owner>/comfier-ui`:

| Workflow | When | Image tags |
|---|---|---|
| [Staging](.github/workflows/staging.yml) | Push to `staging` | `:staging` |
| [Release](.github/workflows/release.yml) | Manual run on `main` | `:latest`, `:X.Y.Z`, `:MAJOR` |

Cut a production release from `main` with **Actions → Release → Run workflow** (choose `patch`, `minor`, or `major`), or:

```bash
gh workflow run release.yml -f bump=patch
gh workflow run release.yml -f bump=minor -f dry_run=true   # preview only
```

Set `COMFIER_IMAGE=ghcr.io/<owner>/comfier-ui:latest` (or `:staging` on staging) in production `.env`.
The first push to GHCR may require making the package public under the repo's **Packages** settings.

## Architecture

| Path | What lives there |
|---|---|
| `app/models/generation_kind.rb` | The four media kinds (label, icon, route), which drive the navbar and studios |
| `app/models/workflow.rb` | An admin-supplied ComfyUI graph (API format) with `{{placeholders}}` |
| `app/models/generation.rb` | One request: prompt, resolved parameters, status, attached outputs |
| `app/models/backend.rb` | A ComfyUI server; its API token is encrypted at rest |
| `app/services/comfyui/` | HTTP client for ComfyUI's API (`/prompt`, `/history`, `/view`, `/upload/image`, `/queue`) |
| `app/services/workflow_renderer.rb` | Substitutes form values into a workflow graph |
| `app/services/backend_selector.rb` | Picks a backend: the user's preferred one, otherwise the least busy reachable one |
| `app/jobs/submit_generation_job.rb` | Uploads inputs, renders the graph and queues it on ComfyUI |
| `app/jobs/poll_generation_job.rb` | Polls history, downloads outputs into Active Storage, times out stuck jobs |
| `app/services/workflow_models.rb` | Works out which model files a workflow loads, and reads links from UI-format exports |
| `app/services/model_installer.rb`, `app/jobs/*_model_download_job.rb` | Queue, start and follow model downloads |
| `comfyui/comfier_downloader/` | The ComfyUI custom node that performs downloads on the server |
| `app/models/privacy_notice.rb` | Privacy notice text and version; users must agree before using the app |
| `app/services/queue_estimator.rb` | Estimates wait times from recent run durations and queue position |
| `app/controllers/shared_controller.rb` | Gallery of results members chose to share |
| `app/jobs/notify_generation_job.rb` | Sends finished/failed/cancelled notifications, one retried job per channel |
| `app/mailers/generation_mailer.rb`, `app/services/slack_notifier.rb` | Email and Slack DM delivery |

### How a generation flows

1. A user submits a studio form. A `Generation` is saved as `queued` and `SubmitGenerationJob` is enqueued.
2. The job picks a backend, uploads any input image, fills the workflow's placeholders and POSTs to `/prompt`.
3. `PollGenerationJob` checks `/history/{id}` every two seconds. When ComfyUI finishes, it downloads each output
   through `/view` and attaches it.
4. Every status change is broadcast over Turbo Streams (Action Cable on Redis), so result cards update live.
5. When it finishes, fails or is cancelled, `NotifyGenerationJob` emails and/or Slack-messages the owner if they
   turned notifications on.

### Workflow placeholders

Admins export a workflow from ComfyUI with **Export (API)** and replace literal values with placeholders. The studio
form only shows fields for the placeholders a workflow uses.

| Placeholder | Filled with |
|---|---|
| `{{prompt}}`, `{{negative_prompt}}` | What the user typed |
| `{{seed}}` | The user's seed, or a random one |
| `{{width}}`, `{{height}}` | The chosen shape at the workflow's base resolution, rounded to multiples of 64 |
| `{{duration}}`, `{{frames}}` | Seconds requested, and seconds × frame rate + 1 |
| `{{image}}` | The name of the uploaded input image on the backend |

A string that is exactly one placeholder (`"{{seed}}"`) becomes the typed value (an integer here), so numeric
inputs stay numeric.

## License

MIT. See [LICENSE](LICENSE).
