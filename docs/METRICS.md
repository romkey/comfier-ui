# Prometheus metrics

Comfier serves metrics for [Prometheus](https://prometheus.io/) at `GET /metrics`, in the text exposition format.
They cover users, generations (by kind, workflow, status and server), failures, run times, servers, model downloads,
content reports, chat, storage and the background job queue.

## Turning it on

The endpoint is off until you set a token. Without `METRICS_TOKEN` in the environment, `/metrics` answers `404`.

1. Make a long random token:

   ```bash
   openssl rand -hex 32
   ```

2. Set it as `METRICS_TOKEN` in the `web` container's environment (`.env` for the bundled compose file) and restart
   `web`.

3. Check it:

   ```bash
   curl -H "Authorization: Bearer $METRICS_TOKEN" https://comfier.example.com/metrics
   ```

Every request must send the token as a bearer token in the `Authorization` header. Anything else gets `401`: no
token, a wrong one, the token in the query string, or a signed-in browser session. To change the token, set a new
value and restart `web`.

The token gives read access to operational data, including server names, workflow names and user counts. It doesn't
expose prompts, results, email addresses or anything about a single user. Treat it as a secret all the same.

## Scraping

```yaml
scrape_configs:
  - job_name: comfier
    scheme: https
    metrics_path: /metrics
    scrape_interval: 60s
    scrape_timeout: 20s
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/comfier-metrics-token
    static_configs:
      - targets: ['comfier.example.com']
```

Prometheus on the same Docker network can scrape the container directly instead, with `scheme: http` and a target of
`web:80`. In production `/metrics` is exempt from the HTTPS redirect and from the `APP_HOST` check, like `/up`, so
that works without going through the reverse proxy. If you'd rather the endpoint weren't reachable from the internet
at all, block `/metrics` at the reverse proxy and scrape it only this way.

Scrape **one** target, not every `web` replica: the numbers come from the shared database and Redis, so every web
process gives the same answer.

Each scrape runs a few dozen aggregate queries. That's quick on a typical install; `comfier_scrape_duration_seconds`
says how long the last one took. A 30–60 second interval is plenty.

## How the numbers are made

Nothing is counted in memory as it happens. Every value is worked out from the database, Redis and Sidekiq at the
moment Prometheus asks. Two things follow:

- **Most metrics are gauges of what exists now.** `comfier_generations` counts the generations in the database, so it
  goes down when someone deletes a result. Don't use `rate()` on these.
- **For rates, use `comfier_activity_events_total`.** It counts the activity log, which is only ever added to, so it's
  a true counter: `increase(comfier_activity_events_total{kind="generation_failed"}[1h])` is the generations that
  failed in the last hour, whether or not they've since been deleted.

The duration histograms are also built from the rows that exist. Deleting results lowers their counts; Prometheus
reads that as a counter reset and carries on, so `histogram_quantile` over `rate()` still works, with a blip when
many results are deleted at once.

If one section can't be collected (say Redis is down, so Sidekiq can't be read), the rest are still served and
`comfier_scrape_section_errors{section="…"}` is `1` for the one that failed. The reason is in the web log.

## Metrics

Labels are in braces. `window` is `1d`, `7d` or `30d`. `kind` is `image`, `video`, `audio` or `model_3d`.

### Build and scrape

| Metric | Type | Meaning |
|---|---|---|
| `comfier_build_info{version,commit,ruby,rails}` | gauge | Always 1; the labels carry the running version |
| `comfier_scrape_duration_seconds` | gauge | Time spent building this page |
| `comfier_scrape_section_errors{section}` | gauge | 1 when that section failed to collect |

### Users

| Metric | Type | Meaning |
|---|---|---|
| `comfier_users{role}` | gauge | Accounts; `role` is `admin` or `user` |
| `comfier_users_signed_in{window}` | gauge | Users whose last sign-in was within the window |
| `comfier_users_generating{window}` | gauge | Users who started a generation within the window |
| `comfier_users_chatting{window}` | gauge | Users with a chat active within the window |
| `comfier_api_tokens` | gauge | Personal API tokens that exist |
| `comfier_api_tokens_used{window}` | gauge | Personal API tokens used within the window |

### Generations

| Metric | Type | Meaning |
|---|---|---|
| `comfier_generations{kind,status}` | gauge | Generations in the database. `status` is `queued`, `running`, `succeeded`, `failed` or `cancelled` |
| `comfier_workflow_generations{workflow,kind,status}` | gauge | The same, by workflow name |
| `comfier_generations_via_api` | gauge | Generations started through the API |
| `comfier_generations_in_progress{kind,state}` | gauge | Waiting or running now. `state` is the detailed state: `routing`, `queued`, `waiting_models`, `dispatched`, `accepted`, `running`, `uploading`, `cancelling` |
| `comfier_generations_oldest_queued_seconds` | gauge | Age of the oldest generation still queued; 0 when none |
| `comfier_queue_predicted_drain_seconds` | gauge | Seconds until everything in progress is predicted to finish; 0 when unknown |
| `comfier_job_attempts{server,outcome,infra}` | gauge | Tries at running a generation on a server. `outcome` is `completed`, `failed`, `rejected`, `lost`, `cancelled` or `timeout`; `infra="true"` means the server or connection was at fault. `server` is empty for a server since deleted |
| `comfier_generations_shared` | gauge | Generations shared with other users |
| `comfier_generations_public_links` | gauge | Generations with a public link |
| `comfier_generations_hidden_for_review` | gauge | Generations hidden while a report is reviewed |
| `comfier_public_link_views` | gauge | Public link views, over generations that still exist |

A cancelled job is stored as failed; these metrics report it as `cancelled` so failures mean failures.
Job attempts are recorded for agent servers only.

### Durations

Histograms over successful generations, by `kind`, with buckets from 1 second to 1 hour.

| Metric | Meaning |
|---|---|
| `comfier_generation_run_seconds` | Time spent running on a server |
| `comfier_generation_queue_wait_seconds` | Time from the request until it started running |
| `comfier_generation_total_seconds` | Time from the request until the result was ready |

### Servers

Per-server series carry the server's name as `server`. Deleted servers are left out.

| Metric | Type | Meaning |
|---|---|---|
| `comfier_servers{connection_kind,visibility}` | gauge | Servers, by `agent`/`legacy` and `private`/`shared`/`public` |
| `comfier_servers_online` | gauge | Servers reachable now |
| `comfier_server_info{server,connection_kind,visibility,gpu,agent_version,comfyui_version}` | gauge | Always 1; details in the labels |
| `comfier_server_up{server}` | gauge | 1 when an agent is connected and reporting, or a legacy server passed its last check |
| `comfier_server_enabled{server}` | gauge | 1 when enabled |
| `comfier_server_paused{server}` | gauge | 1 when paused |
| `comfier_server_state{server,state}` | gauge | Agent servers: 1 for the current state (`offline`, `paused`, `error`, `busy_local`, `busy`, `idle`, `starting`, `disk_low`) |
| `comfier_server_last_seen_timestamp_seconds{server}` | gauge | When it was last heard from (agent) or checked (legacy), as Unix time |
| `comfier_server_vram_total_bytes{server}` | gauge | GPU memory |
| `comfier_server_vram_free_bytes{server}` | gauge | Free GPU memory; online agents only |
| `comfier_server_disk_free_bytes{server}` | gauge | Free disk space; online agents only |
| `comfier_server_speed_index{server}` | gauge | Measured speed: 1 is typical, 2 is twice as slow |
| `comfier_server_generations_in_progress{server}` | gauge | Generations assigned to it and not finished |
| `comfier_server_model_downloads_active{server}` | gauge | Model downloads queued or running on it |

### Workflows, downloads, reports, chat and storage

| Metric | Type | Meaning |
|---|---|---|
| `comfier_workflows{kind,engine,enabled}` | gauge | Workflows |
| `comfier_model_downloads{status}` | gauge | Model downloads on record: `queued`, `running`, `succeeded`, `failed` |
| `comfier_model_download_bytes_remaining` | gauge | Bytes still to fetch across downloads in progress |
| `comfier_report_cases{status}` | gauge | Content report cases: `open` or `reviewed` |
| `comfier_reports` | gauge | Individual reports received |
| `comfier_chat_conversations` | gauge | Chat conversations |
| `comfier_chat_messages{role,status}` | gauge | Chat messages; a `failed` assistant message is a failed reply |
| `comfier_video_script_requests{status}` | gauge | Video script requests |
| `comfier_storage_blobs` | gauge | Files in storage (inputs, results, posters) |
| `comfier_storage_bytes` | gauge | Their total size |

### Activity

| Metric | Type | Meaning |
|---|---|---|
| `comfier_activity_events_total{kind}` | counter | Events in the activity log |

`kind` is one of the activity log's kinds, including `generation_queued`, `generation_succeeded`,
`generation_failed`, `generation_cancelled`, `login`, `login_failed`, `logout`, `llm_chat`, `media_failed`,
`api_token_created`, and the `server_*` and `model_*` events. Every kind is always present, at 0 until it first
happens.

### Background jobs (Sidekiq)

| Metric | Type | Meaning |
|---|---|---|
| `comfier_sidekiq_processed_total` | counter | Jobs run |
| `comfier_sidekiq_failed_total` | counter | Jobs that raised an error |
| `comfier_sidekiq_enqueued` | gauge | Jobs waiting, all queues |
| `comfier_sidekiq_scheduled` | gauge | Jobs scheduled for later |
| `comfier_sidekiq_retries` | gauge | Jobs waiting to be retried |
| `comfier_sidekiq_dead` | gauge | Jobs that ran out of retries |
| `comfier_sidekiq_busy` | gauge | Jobs running now |
| `comfier_sidekiq_processes` | gauge | Sidekiq processes running; 0 means nothing is running jobs |
| `comfier_sidekiq_queue_size{queue}` | gauge | Jobs waiting in the queue |
| `comfier_sidekiq_queue_latency_seconds{queue}` | gauge | How long the oldest job in the queue has waited |

## Example queries

```promql
# Generations started per hour
sum(increase(comfier_activity_events_total{kind="generation_queued"}[1h]))

# Failure rate over the last day
  increase(comfier_activity_events_total{kind="generation_failed"}[1d])
/ (increase(comfier_activity_events_total{kind="generation_succeeded"}[1d])
   + increase(comfier_activity_events_total{kind="generation_failed"}[1d]))

# 90th percentile video run time
histogram_quantile(0.9, sum by (le) (rate(comfier_generation_run_seconds_bucket{kind="video"}[1d])))

# Average image run time, all time
comfier_generation_run_seconds_sum{kind="image"} / comfier_generation_run_seconds_count{kind="image"}

# What's waiting, and why
sum by (state) (comfier_generations_in_progress)

# Which workflows fail most
topk(5, sum by (workflow) (comfier_workflow_generations{status="failed"}))

# Servers losing jobs
sum by (server) (comfier_job_attempts{infra="true"})

# Failed sign-ins in the last 15 minutes
increase(comfier_activity_events_total{kind="login_failed"}[15m])
```

## Example alerts

```yaml
groups:
  - name: comfier
    rules:
      - alert: ComfierServerDown
        expr: comfier_server_up == 0 and comfier_server_enabled == 1
        for: 10m
      - alert: ComfierQueueStuck
        expr: comfier_generations_oldest_queued_seconds > 1800
        for: 5m
      - alert: ComfierNoServersOnline
        expr: comfier_servers_online == 0
        for: 5m
      - alert: ComfierSidekiqDown
        expr: comfier_sidekiq_processes == 0 or comfier_scrape_section_errors{section="sidekiq"} == 1
        for: 5m
      - alert: ComfierJobsBackingUp
        expr: comfier_sidekiq_queue_latency_seconds > 120
        for: 10m
      - alert: ComfierServerDiskLow
        expr: comfier_server_disk_free_bytes < 20e9
        for: 15m
```
