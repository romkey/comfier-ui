import { Controller } from "@hotwired/stimulus"

// Reloads managed Turbo Frames on targeted refresh streams instead of Turbo's default frame reload.
export default class extends Controller {
  static values = { src: String }

  connect() {
    this.interceptOptions = { capture: true }
    document.addEventListener("turbo:before-stream-render", this.intercept, this.interceptOptions)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.intercept, this.interceptOptions)
  }

  intercept = (event) => {
    const stream = event.target
    if (stream.getAttribute("action") !== "refresh") return

    const target = stream.getAttribute("target")
    if (!target) return

    // Every frame-refresh controller must block Turbo's default targeted refresh. After Re-scan (or
    // lazy load), managed frames often have no `src`; Turbo's built-in reload then shows
    // "Content missing". Only the matching frame performs our src-aware reload.
    event.preventDefault()
    if (target === this.element.id) this.refreshFrame()
  }

  refreshFrame() {
    // Prefer the declared src value: after a form submits inside the frame (e.g. Re-scan), Turbo sets
    // the frame's `src` to the POST URL, and reloading that with GET hits no route.
    const baseUrl = (this.hasSrcValue && this.srcValue) || this.element.getAttribute("src")
    if (!baseUrl) {
      this.element.reload()
      return
    }

    const url = new URL(baseUrl, window.location.href)
    url.searchParams.set("refresh", Date.now().toString())

    this.element.removeAttribute("complete")
    this.element.setAttribute("src", url.toString())
  }
}
