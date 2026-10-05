import { Controller } from "@hotwired/stimulus"

// Reloads managed Turbo Frames on refresh streams instead of full-page Turbo refresh.
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

    if (target) {
      // Every frame-refresh controller must block Turbo's default targeted refresh. After Re-scan (or
      // lazy load), the styles frame often has no `src`; Turbo's built-in reload then shows
      // "Content missing". Only the matching frame performs our src-aware reload.
      event.preventDefault()
      if (target === this.element.id) this.refreshFrame()
      return
    }

    // Untargeted refresh (e.g. :model_downloads on the workflow editor): reload this frame only.
    event.preventDefault()
    this.refreshFrame()
  }

  refreshFrame() {
    const baseUrl = this.element.getAttribute("src") || (this.hasSrcValue ? this.srcValue : null)
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
