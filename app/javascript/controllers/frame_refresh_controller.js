import { Controller } from "@hotwired/stimulus"

// Reloads one Turbo Frame when a targeted refresh stream arrives, without morphing the whole page.
export default class extends Controller {
  static values = { src: String }

  connect() {
    document.addEventListener("turbo:before-stream-render", this.intercept)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.intercept)
  }

  intercept = (event) => {
    const stream = event.target
    if (stream.getAttribute("action") !== "refresh") return

    const target = stream.getAttribute("target")
    if (target && target !== this.element.id) return

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
    this.element.reload()
  }
}
