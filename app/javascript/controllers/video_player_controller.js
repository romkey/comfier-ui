import { Controller } from "@hotwired/stimulus"

// Owns every result video. Turbo builds pages by parsing HTML and adopting the nodes, and morphs and streams
// insert them too; media elements that arrive that way don't always start loading (hotwired/turbo-rails#576),
// so the player loads itself whenever it connects. A network error gets one retry with a fresh request; after
// that, or when playback never starts, the player says so, offers Reload, and reports what happened.
const STALL_MS = 8000
const NETWORK = 2
const UNSUPPORTED = 4
const CODES = { 1: "aborted", 2: "network error", 3: "couldn't decode it", 4: "format not supported" }

let turboVisits = 0
let morphs = 0
document.addEventListener("turbo:visit", () => turboVisits++)
document.addEventListener("turbo:morph", () => morphs++)

export default class extends Controller {
  static targets = ["video", "notice", "message"]
  static values = { reportUrl: String, generation: String, page: String }

  connect() {
    this.connectedAt = performance.now()
    this.retried = false
    this.reported = false
    this.video.addEventListener("error", this.onError)
    this.video.addEventListener("play", this.onPlay)
    this.video.addEventListener("playing", this.clearStall)
    window.addEventListener("pageshow", this.onPageShow)
    // A video still playing was only moved within the page; anything else gets a fresh start.
    if (this.video.paused) this.video.load()
  }

  disconnect() {
    this.clearStall()
    this.video.removeEventListener("error", this.onError)
    this.video.removeEventListener("play", this.onPlay)
    this.video.removeEventListener("playing", this.clearStall)
    window.removeEventListener("pageshow", this.onPageShow)
    // A removed video can keep playing its sound; one that was only moved is back in the page by now.
    if (!this.video.isConnected) this.video.pause()
  }

  get video() {
    return this.hasVideoTarget ? this.videoTarget : this.element.querySelector("video")
  }

  onPageShow = (event) => {
    if (event.persisted) this.video.load()
  }

  onPlay = () => {
    this.clearStall()
    this.stallTimer = setTimeout(() => {
      if (this.video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA && !this.video.error) this.fail("stalled")
    }, STALL_MS)
  }

  clearStall = () => {
    clearTimeout(this.stallTimer)
    this.stallTimer = null
  }

  onError = () => {
    const code = this.video.error?.code
    if (!this.retried && (code === NETWORK || code === UNSUPPORTED)) {
      this.retried = true
      this.restart()
      return
    }
    this.fail(code)
  }

  // Reload button: a fresh request, picking up where the viewer was.
  reload(event) {
    event?.preventDefault()
    this.retried = true
    this.reported = false
    this.noticeTarget.hidden = true
    this.restart(true)
  }

  restart(play = !this.video.paused) {
    const time = this.video.currentTime
    const url = new URL(this.video.currentSrc || this.video.getAttribute("src"), window.location.href)
    url.searchParams.set("retry", Date.now().toString())
    this.video.addEventListener("loadedmetadata", () => {
      if (time > 0 && time < this.video.duration) this.video.currentTime = time
      if (play) this.video.play().catch(() => {})
    }, { once: true })
    this.video.src = url.toString()
    this.video.load()
  }

  fail(code) {
    this.clearStall()
    if (this.hasNoticeTarget) {
      this.messageTarget.textContent = code === "stalled"
        ? "The video is taking too long to start."
        : `The video didn't load (${CODES[code] || "unknown error"}).`
      this.noticeTarget.hidden = false
    }
    this.report(code)
  }

  report(code) {
    if (this.reported || !this.hasReportUrlValue) return
    this.reported = true
    const video = this.video
    const src = new URL(video.currentSrc || video.getAttribute("src") || "", window.location.href)
    const body = {
      code: String(code ?? ""),
      message: video.error?.message || "",
      network_state: video.networkState,
      ready_state: video.readyState,
      src: src.pathname,
      video_width: video.videoWidth,
      seconds: Math.round((performance.now() - this.connectedAt) / 100) / 10,
      retried: this.retried,
      visibility: document.visibilityState,
      arrival: turboVisits ? "turbo" : "full",
      morphs,
      generation_id: this.generationValue,
      page: this.pageValue || window.location.pathname
    }
    fetch(this.reportUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      keepalive: true,
      credentials: "same-origin"
    }).catch(() => {})
  }
}
