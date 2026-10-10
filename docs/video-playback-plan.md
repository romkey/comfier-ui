# Plan: video playback that always shows the picture

The complaint: open a video under **Results**, see its still, press play, and the still is replaced by
the page background. Sometimes the clock runs, sometimes it doesn't; a reload usually fixes it. Three
earlier fixes each addressed one real thing and left the rest: #33 gave the public share route byte-range
support, #34 added `media_poster_fix.js` (`video.load()` on `turbo:load`), and the poster work gave
grids a still. This plan is written so that there is no fourth guess: it names every defect in the path
a video takes from the agent to the screen, fixes each one, and adds tests that play real bytes in a
real browser.

**Status (2026-10-10):** Phases 1–4 are built as a stack of PRs: #92 (output route), #93 (normalize at ingest),
#94 (player), #95 (browser tests). Phase 0's reporting was folded into the player in #94. What's left is the manual
check in Safari, Firefox, and iOS Safari listed under "Done means".

Each phase is one PR into `main`, shippable on its own. Phase 0 is half a day and tells us which
defect bites most in production; the order of Phases 1–3 can follow that evidence, but all three are
real and all three ship.

---

## Where things stand

**How a video gets here.**

- **mlx-video (LTX-2 / LTX-2.3)** writes frames with OpenCV's `avc1` writer (AVFoundation H.264 on a
  Mac), then runs `ffmpeg -c:v copy -c:a aac` to add the soundtrack. Neither step uses
  `-movflags +faststart`, so the `moov` index sits at the **end** of the file. The agent uploads the
  file as is (`comfyui/comfier_agent/comfier_agent/engines/mlx_video.py`).
- **mlx-video (Wan)** writes with imageio/libx264 (`yuv420p`), again without faststart.
- **ComfyUI** outputs are downloaded by `PollGenerationJob#attach_outputs`, typed from the *filename*
  with Marcel, and attached. Nothing probes them.
- The server never learns a video's codec, pixel format, dimensions, or duration. It only extracts a
  JPEG poster with ffmpeg (`VideoPosterExtractor`), which ends with `update!(updated_at:)`.

**How a video is served.** Every result page (`generations/show`, `shared/show`, the Results grid,
`admin/reports/show`) renders `video_tag(rails_blob_path(output, disposition: 'inline'), poster:,
preload: 'metadata', loop: true, playsinline: true)` (`app/helpers/generations_helper.rb`,
`output_preview`). `rails_blob_path` is Active Storage's **redirect** route:

1. `GET /rails/active_storage/blobs/redirect/<signed_id>/<name>` → `302` with
   `Cache-Control: max-age=300, private` (the controller calls
   `expires_in ActiveStorage.service_urls_expire_in`, 5 minutes by default);
2. → `GET /rails/active_storage/disk/<encoded_key>/<name>`, a signed Disk-service URL that **expires
   after the same 5 minutes**. `ActiveStorage::DiskController#show` answers an expired or invalid key
   with `404`. Byte ranges are handled by `Rack::Files`.

Only the public share route (`PublicSharesController#output`, `OutputServing`) streams directly, with
Range support and no expiry. It is the one route that has not been complained about.

**How browsers play it.** With `preload="metadata"` the browser fetches the start of the file at page
load and, because `moov` is at the end, a second range for the tail, then stops. Pressing play, seeking,
or the `loop` wrapping back to 0 after the buffer was evicted all issue **new** byte-range requests.
Chrome's media loader (`resource_multi_buffer_data_provider.cc`) follows a redirect once, then builds
every later request from the **redirected** URL, and a response that is neither `200` nor a valid
`206` fails the load at once, with no retry. When that happens the poster is already gone (play
removes it) and Chrome paints nothing for a video element with no decoded frame: the page background
shows through. Nothing in the app listens for `error`, so the failure is silent and unlogged.

---

## The defects, ranked

**A. Expiring URLs under a long-lived player (high confidence; matches the symptom exactly).**
Any play, seek, or loop that needs bytes more than 5 minutes after the Disk URL was minted gets a
`404` and the picture vanishes. Because the `302` is cached for 5 minutes too, the clock starts the
*first* time the browser resolved that blob, not when the current page loaded: look at a result, go
back to Results, open it again a few minutes later, press play → blank on the first click. That is the
reported flow, and it explains "frequently" rather than "always". `media_poster_fix`'s `load()` doesn't
help: it re-fetches metadata through the cached redirect to the same expiring URL.

**B. Media elements that never start, after Turbo.** Turbo Drive builds the new page with
`DOMParser` and adopts its nodes; the same happens on a morph refresh and a `turbo-stream replace`.
Media elements adopted that way don't always start loading (hotwired/turbo-rails#576, iOS Safari;
audio-only or frozen poster). `media_poster_fix.js` covers `turbo:load` and bfcache only. It does not
cover `turbo:morph`, and `generations/show` morphs on **every** save of the generation
(`after_update_commit -> { broadcast_refresh_later_to self }` in `app/models/generation.rb`): the poster
extractor's `update!`, timing records, sharing changes, album art. The `<figure>`s have no ids, so
idiomorph matches them by position and may re-parent a `<video>` mid-play.

**C. Files the browser may not be able to decode or index.** Nothing guarantees H.264 / `yuv420p` /
`moov`-first / even dimensions. `.mov` (`video/quicktime`) is accepted, which Chrome and Firefox don't
advertise. A 4:4:4 or 10-bit stream, or an audio-only decodable file, plays sound with a transparent
picture, which is the same symptom as A. We have no evidence this is happening today, and no way to
tell, because nothing probes the files.

**D. Failure is invisible.** No `error` handler, no fallback UI, no log line, no black box (CSS gives
the video no background). Every previous attempt was made without knowing which of A–C fired.

**E. Capacity and the proxy in front.** Streaming through Puma holds a thread for the duration of
each range; `RAILS_MAX_THREADS` defaults to 3 and the production compose runs bare Puma. A browser
opens several media connections per page. A reverse proxy that buffers or answers `200` to a Range
request would also kill playback in Chrome (see the loader rule above). Unmeasured today.

**Side effect worth fixing on the way:** Active Storage's redirect URLs are, as Rails documents,
usable by anyone who has them, logged in or not. Private results are currently one copied URL away
from public.

---

## Principles

1. **See it before fixing it.** Instrument first, so this is the last round.
2. **No expiring URL ever reaches a `<video src>`.** Serve outputs from a permanent, authenticated,
   range-capable route of our own.
3. **Make the file safe at ingest.** Probe every video, fix what's fixable, record what we learned,
   and use it in the markup.
4. **The player element heals itself.** One Stimulus controller owns every `<video>`: it loads on
   connect (Drive, morph, streams, bfcache), retries once on a network error, and otherwise shows a
   message and reports.
5. **Prove it with real bytes in a real browser**, then with `curl` against production.

---

## Phase 0 — Confirm and instrument (half a day)

### 0.1 Look at production today
Before writing code, three checks that each take minutes:

```bash
# 404s from the Disk controller are defect A. Count them against the complaints.
docker compose -f docker-compose.production.yml logs --since 72h web \
  | grep -E 'Processing by ActiveStorage::DiskController#show|Completed 404' \
  | grep -A1 'DiskController#show' | grep -c 'Completed 404'
```

In the browser where it fails, right after the blank appears, in the console:

```js
const v = document.querySelector('video.output-media');
({ error: v.error?.code, message: v.error?.message, network: v.networkState,
   ready: v.readyState, src: v.currentSrc, width: v.videoWidth })
```

`error 2` or `4` with a red `404` on a `disk/` request in the Network tab → A. `error 3` → C.
`error` null with `network 0` or `3` → B.

Download one failing file and probe it:

```bash
ffprobe -v error -show_entries stream=codec_name,profile,pix_fmt,width,height:format=format_name -of compact clip.mp4
ffprobe -v trace clip.mp4 2>&1 | grep -o "type:'m[od][oa][vt]'" | head -2   # moov before mdat = faststart
```

### 0.2 Report failures from the page
- New `video_player_controller.js` (Stimulus) attached to every output `<video>` (show, shared,
  public, admin report, grid fallback). On `error`, and on `play` when `readyState` is still below
  `HAVE_CURRENT_DATA` five seconds later, it collects `error.code/message`, `networkState`,
  `readyState`, `currentSrc`, `videoWidth/Height`, time since connect, `visibilityState`, and whether
  the page arrived by Turbo visit, morph, or full load, and POSTs it to a new authenticated,
  rate-limited `POST /client_events`. The controller logs it at `warn` and writes an activity-log
  entry so admins see it under **Log**.
- The same controller shows an inline notice, "The video didn't load (code N) · Reload", whose button
  re-requests the source with a cache-busting query and calls `load()`.
- CSS: `.output-full video, .result-media video { background: #000 }` and an `aspect-ratio` from
  `width`/`height` attributes (Phase 2 supplies them; until then from the poster). A failed or
  pending frame is a black box, never the page background.

This phase ships on its own. Within a day the Log says which of A, B, or C fires, per browser.

---

## Phase 1 — A permanent, authenticated, range-capable output route

### 1.1 Route and controller
```ruby
# config/routes.rb, inside resources :generations (path 'results')
member do
  get 'outputs/:attachment_id(/*filename)', to: 'generation_outputs#show',  as: :output, format: false
  get 'poster',                             to: 'generation_outputs#poster', as: :poster
  get 'cover',                              to: 'generation_outputs#cover',  as: :cover
  get 'input_image',                        to: 'generation_outputs#input_image', as: :input_image
end
```

`GenerationOutputsController` includes `OutputServing` and authorizes exactly as the pages do:
owner, any signed-in user when the generation is in the shared gallery (`Generation.shared_gallery`),
admin; otherwise `404`. `show` finds the attachment **through** `@generation.outputs` so one result
can't serve another's file. `?download=1` switches the disposition to `attachment` for the Download
button.

### 1.2 Serving
Extend `OutputServing` so that, for the Disk service, it serves with `Rack::Files` the way
`ActiveStorage::FileServer` does (`Rack::Files.new(nil).serving(request, path)`): correct `200`/`206`/`416`,
`Accept-Ranges`, `Content-Range`, `HEAD`, and a body that responds to `to_path`, which is what lets
`Rack::Sendfile` hand the file to a front proxy later (1.4). Other services keep
`send_blob_byte_range_data`. Headers on every response: the blob's content type,
`X-Content-Type-Options: nosniff`, `ETag` from the blob checksum, and
`Cache-Control: private, max-age=31536000, immutable`, which is safe because an attachment id always
maps to the same blob (Phase 2 replaces blobs by creating a *new* attachment).

### 1.3 Use it everywhere
- `GenerationsHelper#output_preview`, `output_poster_url`, `album_art_url`, the show page's download
  link and reference image, `shared/show`, `admin/reports/show`: every `rails_blob_path` on a result
  page becomes one of the new routes. The public share page already has its own.
- Delete nothing else yet; `media_poster_fix.js` goes in Phase 3.
- Safety net: `config.active_storage.resolve_model_to_route = :rails_storage_proxy`, so any
  `rails_blob_path` that slips in later is at least permanent and range-capable; plus an integration
  test that renders Results, a result page, Shared, and a public link and asserts no
  `/rails/active_storage/` URL appears in the HTML.

### 1.4 Capacity
- Interim: document `RAILS_MAX_THREADS=5` in `.env.example` and the README.
- Proper: add `thruster` and run `./bin/thrust ./bin/rails server` in the Dockerfile `CMD` (Rails 8's
  default). Thruster serves `X-Sendfile` responses straight from disk with Go's `http.ServeFile`
  (Range, HEAD, If-Range) and frees the Puma thread. Gate it with
  `config.action_dispatch.x_sendfile_header = ENV['SENDFILE_HEADER']` so bare Puma, Thruster
  (`X-Sendfile`), and nginx (`X-Accel-Redirect`, with an `internal` location for `/rails/storage`) all
  work and the header never leaks without a proxy to honor it.

### 1.5 Tests (integration, `test/integration/generation_outputs_test.rb`)
`200` with `Accept-Ranges: bytes`, `Content-Length`, `Content-Type: video/mp4`, `nosniff`, `ETag`;
`Range: bytes=0-1` → `206` (Safari's probe); `bytes=0-4` → `Content-Range: bytes 0-4/N`; suffix range
`bytes=-100` (the moov-at-the-end fetch) → `206`; `bytes=999999-` → `416`; `HEAD` → headers without a
body; `?download=1` → `attachment`; poster, cover, and input image; another user → `404`; shared
generation → `200` for a signed-in stranger, `404` once unshared or hidden for review; signed out →
redirect to login; no `/rails/active_storage/` in rendered result pages.

---

## Phase 2 — Normalize every video at ingest

### 2.1 Probe
`VideoProbe.call(blob)` runs `ffprobe -v error -print_format json -show_format -show_streams` on the
downloaded file and returns container, video codec, profile, pixel format, width, height, frame rate,
duration, audio codec, and whether `moov` precedes `mdat` (a 15-line walk over the top-level MP4 boxes
in Ruby; don't scrape `ffprobe -v trace`).

### 2.2 Policy and fix
Browser-safe means: MP4 container, H.264 with profile Baseline/Main/High, `yuv420p`, even width and
height, `moov` first, AAC or no audio. Anything else goes through `VideoNormalizer`:

```bash
# only the index or container is wrong: remux, no quality change
ffmpeg -i in -c copy -movflags +faststart out.mp4
# otherwise: transcode
ffmpeg -i in -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p -preset medium -crf 18 \
       -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:a aac -b:a 160k -movflags +faststart out.mp4
```

`VIDEO_NORMALIZE=transcode|remux|off` (default `transcode`) for operators who'd rather keep bytes
untouched. WebM is transcoded too: Safari's WebM support is partial and "reliable" means one format.

### 2.3 Job
`ProcessVideoOutputJob` replaces `ExtractVideoPosterJob` (same trigger: status becomes `succeeded` on
a video generation, same retry-until-outputs-arrive loop). For each video output: probe → normalize if
needed → attach the new blob as a **new** attachment with the same filename, purge the old → store the
probe result in `blob.metadata` (`width`, `height`, `duration`, `video_codec`, `pix_fmt`,
`normalized_from`) → extract the poster from the final file → one `update!` at the end (one morph
refresh instead of several). Sidekiq runs the same image as web, so ffmpeg is there. Log what was
done per file at `info`, failures at `warn` with ffmpeg's last stderr line; a failed normalization
keeps the original file and still extracts the poster.

### 2.4 Use what we learned
`output_preview` sets `width`/`height` on the `<video>` from the metadata, so the element has its
final size before the poster or first frame arrives and never collapses; Results shows the duration
on the card. The poster is extracted after normalization, so it always matches the frames.

### 2.5 Agent follow-up (separate small PR)
`MlxVideoEngine.outputs` remuxes with `-c copy -movflags +faststart` before uploading (seconds, no
quality change), and the upload carries width/height/duration so the server can size the element
before processing finishes. The server-side job stays as the guarantee for ComfyUI outputs and older
agents.

### 2.6 Tests
A `VideoFixtures` helper builds clips with `ffmpeg -f lavfi -i testsrc=…` (CI installs ffmpeg
already): good H.264, `yuv444p`, 10-bit, odd dimensions, `moov` last, WebM, `.mov`, audio-only.
Tests: the probe reads each correctly; the policy picks `remux`, `transcode`, or nothing; the
normalizer's output passes the policy; the job replaces the blob under a new attachment, keeps the
filename, records metadata, extracts the poster, and leaves a bad file in place with a warning;
`output_preview` renders `width`/`height`.

---

## Phase 3 — A player element that heals itself

### 3.1 One controller, every `<video>`
`video_player_controller.js` from Phase 0 becomes the sole owner of media behavior; delete
`media_poster_fix.js` and its import-map pin.

```js
connect() {
  this.video = this.element.querySelector("video")
  // Elements Turbo adopted from a parsed page, morphed in, or inserted by a stream
  // don't always start loading. Stimulus connects in every one of those cases.
  if (this.video.networkState === HTMLMediaElement.NETWORK_EMPTY || !this.video.currentSrc) this.video.load()
  this.video.addEventListener("error", this.onError)
}
disconnect() { this.video.pause(); this.video.removeEventListener("error", this.onError) }
onError = () => {
  const code = this.video.error?.code            // 2 network, 3 decode, 4 unsupported
  if (!this.retried && (code === 2 || code === 4)) {   // one retry with a fresh request
    this.retried = true
    this.video.src = withCacheBuster(this.video.currentSrc || this.video.src)
    this.video.load(); this.video.play().catch(() => {})
    return
  }
  this.showNotice(code); this.report(code)
}
```

`pageshow` with `persisted` calls `load()` as before. Pausing in `disconnect` means Turbo never caches
a snapshot with a playing element.

### 3.2 Markup
- Each output `<figure>` gets `id: dom_id(output)` so idiomorph matches videos by identity and never
  re-parents one during a morph refresh.
- The first video on a result page uses `preload="auto"` (the files are seconds long and the URL is now
  permanent), so frames are already buffered when play is pressed; others keep `metadata`. The grid
  keeps the `<img>` poster and gets a placeholder, not a `<video>`, while the poster is still being
  made (today it renders a muted `<video>` per card for that window).
- `loop` stays; it works once bytes can always be refetched.

### 3.3 Fewer morphs
`broadcast_refresh_later_to self` only when something the page shows changed (`status`,
`error_message`, sharing, review, outputs/poster via the processing job's final `update!`), not on
every timing or counter write. Not strictly a video fix, but every needless morph is a chance to
disturb a playing element.

---

## Phase 4 — Prove it

### 4.1 Browser tests
Add Rails system tests: `capybara` + `selenium-webdriver`, driven by a `selenium/standalone-chrome`
service in `docker-compose.test.yml` (Google Chrome, which decodes H.264; plain Chromium does not)
with `--autoplay-policy=no-user-gesture-required --mute-audio`, and `Capybara.server_host = 0.0.0.0`
so the browser container reaches the test server. `test/system/video_playback_test.rb` seeds a
succeeded video generation with a real one-second H.264 clip from `VideoFixtures` and asserts, within
ten seconds of `play()`:

```js
!v.error && v.readyState >= 2 && v.videoWidth > 0 && v.currentTime > 0
```

in each of: Results → click the card (Turbo visit); back then forward (snapshot preview + adoption);
after `Turbo::StreamsChannel.broadcast_refresh_to(generation)` while on the page (morph); the Shared
page; the public link; and with time travelled past five minutes between first view and play. It also
asserts, via `performance.getEntriesByType("resource")`, that every media request went to
`/results/…/outputs/…` and none to `/rails/active_storage/`. Runs with
`docker compose -f docker-compose.test.yml run --rm system` and in CI.

### 4.2 Production checklist (README, "Serving results")
```bash
H='Cookie: _comfier_session=…'; U=https://host/results/ID/outputs/ATT/clip.mp4
curl -sI -H "$H" $U                          # 200, Accept-Ranges: bytes, Content-Length, video/mp4
curl -sI -H "$H" -H 'Range: bytes=0-1' $U    # 206, Content-Range: bytes 0-1/N  (Safari's probe)
curl -sI -H "$H" -H 'Range: bytes=-1024' $U  # 206 (tail fetch)
curl -sI -H "$H" -H 'Range: bytes=0-' $U | grep -i 'x-sendfile\|server'   # proxy honored sendfile?
```
Plus the nginx notes next to the existing WebSocket snippet: `proxy_buffering off` (or large
buffers) for `/results/*/outputs/`, no `proxy_max_temp_file_size 0` surprises, `proxy_read_timeout`,
and HTTP/2 on.

### 4.3 Docs
CHANGELOG entry under **Fixed**; README sections for `SENDFILE_HEADER`, `RAILS_MAX_THREADS`,
`VIDEO_NORMALIZE`, and the checklist; USER_GUIDE line that a video that fails to load says so and can
be reloaded.

---

## Done means

- A video result plays on the first click from Results, Shared, its own page, and its public link, in
  desktop Chrome, Safari, and Firefox and in iOS Safari, including: more than five minutes after it was
  first viewed; after back/forward; after a live refresh of the page; while three other videos stream.
- No result page requests `/rails/active_storage/blobs/redirect` or `/rails/active_storage/disk`.
- Every video output is H.264/`yuv420p`/AAC MP4 with `moov` first, or the Log says why not.
- A load that fails shows a message and lands in the Log with its error code. Never a blank box.
- Outputs can't be fetched without being signed in and allowed to see the result.

## Risks and notes

- Until Thruster lands, streaming holds Puma threads; raise `RAILS_MAX_THREADS` with Phase 1.
- Transcoding changes bytes. `crf 18` is visually transparent for generated video; remux is used
  whenever only the index is wrong; `VIDEO_NORMALIZE=off` exists. Keep the original if a user asks
  for it later: the job's `normalized_from` metadata records what happened.
- Old agents and ComfyUI workflows need no change; everything is fixed server-side.
- `Rack::Files` is the same code Active Storage uses to serve Disk blobs today, so Range semantics
  don't change, only the URL's lifetime and the authorization in front of it.
