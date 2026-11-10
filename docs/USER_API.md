# User API

The `/api/v1` JSON API lets scripts list workflows, submit generations, poll their status, cancel work,
and download results. It uses the same validation, queue, server permissions, and generation settings
as the web interface. The existing `/api/agent` endpoints are a separate API for generation servers.

## Authentication

Sign in to Comfier and open **Settings → API tokens**. Give a token a name and copy its value when
it is created; Comfier shows the full token only once and stores only its digest. Tokens begin with
`cmfu_`. Send the token on every API request, including output downloads:

```http
Authorization: Bearer cmfu_…
```

Revoke a token from the same Settings page when it is no longer needed. Use HTTPS outside local
development. User tokens cannot authenticate generation servers, and server keys cannot authenticate
this API. Browser session cookies are not API authentication.

Tokens act as their owner. Even administrators can use this API to read, cancel, or download only
their own generations. Before using the API, accept the current Code of Conduct and privacy notice
in the web interface. If the notice changes, the API returns `403` until you accept the new version.

## Endpoints

All paths below are relative to your Comfier URL.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/workflows` | List enabled workflows and their supported inputs. |
| POST | `/api/v1/generations` | Submit a generation; returns `201` with its ID and a `Location` header. |
| GET | `/api/v1/generations` | List your generations, newest first. |
| GET | `/api/v1/generations/:id` | Get status, progress, parameters, errors, and output URLs. |
| POST | `/api/v1/generations/:id/cancel` | Request cancellation of a queued or running generation. |
| GET | `/api/v1/generations/:id/outputs/:output_id` | Download an output with Bearer authentication. |

Generation submission accepts JSON or multipart form data under a `generation` object. File uploads
use multipart form data. Submission returns immediately; poll the generation URL until `status` is
`succeeded` or `failed`. Cancellation uses the existing generation lifecycle and can finish asynchronously. A cancelled generation
finishes with `status: "failed"` and `error: "Cancelled"`. Backend availability is checked by the
normal scheduler after submission; an accepted generation can subsequently fail if no server can run it.

## Submit and retrieve a result

This example requires `curl` and `jq`. Replace the URL and token, then choose a workflow from the list.

```bash
export COMFIER_URL='https://comfier.example.com'
export COMFIER_TOKEN='cmfu_replace_with_your_token'

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $COMFIER_TOKEN" \
  "$COMFIER_URL/api/v1/workflows" | jq .

export WORKFLOW_ID=1 # Replace with an ID from the workflow response.

response=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $COMFIER_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: first-example-generation' \
  --data "$(jq -n --argjson workflow_id "$WORKFLOW_ID" \
    '{generation: {workflow_id: $workflow_id, prompt: "A lighthouse above a misty sea", aspect_ratio: "16:9"}}')" \
  "$COMFIER_URL/api/v1/generations")

generation_id=$(printf '%s' "$response" | jq -r '.generation.id')

while true; do
  result=$(curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer $COMFIER_TOKEN" \
    "$COMFIER_URL/api/v1/generations/$generation_id") || exit 1
  status=$(printf '%s' "$result" | jq -r '.generation.status')
  case "$status" in
    succeeded) break ;;
    failed) printf '%s\n' "$result" | jq '.generation.error'; exit 1 ;;
  esac
  sleep 3
done

output_url=$(printf '%s' "$result" | jq -r '.generation.outputs[0].download_url')
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $COMFIER_TOKEN" \
  --output result.bin "$output_url"
```

Use a new idempotency key for each intended generation. Reuse the same key and request when retrying
a submission after a lost connection; otherwise the example above will return the earlier generation.

For a workflow with an image input, submit a local file:

```bash
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $COMFIER_TOKEN" \
  -H 'Idempotency-Key: reference-image-example' \
  -F "generation[workflow_id]=$WORKFLOW_ID" \
  -F 'generation[prompt]=A watercolor version of this scene' \
  -F 'generation[input_image]=@reference.png' \
  -F 'generation[denoise]=0.6' \
  "$COMFIER_URL/api/v1/generations"
```

Cancel with:

```bash
curl --fail-with-body --silent --show-error --request POST \
  -H "Authorization: Bearer $COMFIER_TOKEN" \
  "$COMFIER_URL/api/v1/generations/$generation_id/cancel"
```

## Generation inputs

`GET /api/v1/workflows` returns a `workflows` array. Each entry has `id`, `name`, `kind`,
`description`, and an `inputs` object keyed by the supported field names. For example:

```json
{
  "workflows": [{
    "id": 1,
    "name": "Watercolor",
    "kind": "image",
    "description": "Soft painted scenes",
    "inputs": {
      "prompt": {"type": "string", "required": true, "max_length": 10000},
      "aspect_ratio": {"type": "string", "required": false, "enum": ["1:1", "4:3", "3:4", "16:9", "9:16"]},
      "seed": {"type": "integer", "required": false, "minimum": 0, "maximum": 4294967295}
    }
  }]
}
```

A file input has `type: "file"`; numeric inputs describe their `minimum` and `maximum`.
Fields appear only when used by the workflow.

Only send controls supported by the chosen workflow. The workflow response describes those inputs;
`workflow_id` always selects the workflow, which determines the output kind. Raw workflow graphs,
server credentials, output attachments, status, and ownership cannot be supplied by clients.

| Field | Meaning |
| --- | --- |
| `workflow_id` | ID from the workflow list; required. |
| `prompt` | Prompt text; required when the workflow uses it, up to 10,000 characters. |
| `negative_prompt` | Optional things to avoid, up to 10,000 characters. |
| `input_image` | Multipart file for workflows with an image input; required for those workflows. |
| `seed` | Optional integer from 0 through 4294967295; omitted means random. |
| `aspect_ratio` | `1:1`, `4:3`, `3:4`, `16:9`, or `9:16`; defaults to your preferred shape. |
| `duration` | Duration in seconds, from 1 through 30. |
| `quality` | `fast`, `standard` (default), or `best`; scales the workflow's sampling steps. |
| `cfg_level` | `loose`, `balanced` (default), or `strict`; scales the workflow's prompt guidance. |
| `denoise` | Reference-image change strength from 0.1 through 1.0, default 0.6. |
| `lyrics` | Lyrics text; required when the workflow uses it, up to 10,000 characters. |
| `batch_size` | Number of outputs from 1 through 4, default 1. |

Width, height, frame count, sampling steps, and guidance are derived by the workflow from these
controls. The returned `parameters` object contains the resolved values. As in the web interface,
numeric controls are clamped to their supported ranges and unrecognized choice values fall back
to defaults. The API's `denoise` uses a fraction (for example `0.6`), rather than the web form's percentage.

## Listing and polling

`GET /api/v1/generations?page=1&per_page=24` returns a `generations` array and
`pagination: {page, per_page, next_page}`. Pages start at 1; `per_page` defaults to 25 and is capped at 100.
A `null` `next_page` means there are no more results. Invalid or nonpositive pagination values return `400`.

Individual responses use a `generation` object. It includes the ID, workflow ID and name, kind,
status, prompt, negative prompt, resolved parameters, creation and completion timestamps, error,
and an `outputs` array. Each output includes `id`, `filename`, `content_type`, `byte_size`, and
`download_url`. Downloads require the same Bearer token; these URLs do not publish the output.

The coarse `status` is `queued`, `running`, `succeeded`, or `failed`. `progress` contains `phase`
and `fraction`; progress may be unavailable for some servers or phases. Poll every few seconds
until a terminal status is returned. Output URLs appear once files have been saved.

## Retrying submissions

The optional `Idempotency-Key` header accepts 1–255 bytes. Keys are scoped to the user,
so another token for the same user can safely retry a request. The server remembers the key and
request fingerprint, including uploaded file contents, filename, and content type. Receipts persist
even if a generation is deleted; retrying a deleted generation returns `409` rather than creating another job.

- A new key creates one generation and returns `201`.
- Repeating the same key and payload returns that generation's current state with `200` and
  `Idempotency-Replayed: true`; it does not enqueue another generation.
- Repeating the key with a different payload returns `409 idempotency_conflict`.

Keep the same key for retries of one request and generate a fresh key for each new intended job.
Without a key, each successful POST creates a new generation.

## Errors

JSON errors use this envelope:

```json
{"error":{"code":"validation_failed","message":"Generation is invalid","details":{}}}
```

The `details` member, when present, supplies field-specific validation information. Clients should
use the HTTP status and error code rather than matching human-readable message text.

| HTTP status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | Malformed request or invalid request structure. |
| 401 | `invalid_token` | Missing, invalid, or revoked personal token. |
| 403 | `privacy_acceptance_required` | Accept the current notice in the web interface. |
| 404 | `not_found` | Resource does not exist or does not belong to this user. |
| 409 | `idempotency_conflict` | Idempotency key was already used for a different request. |
| 409 | `not_cancellable` | Generation is no longer queued or running. |
| 422 | `validation_failed` | Generation failed the normal input/workflow validation. |
