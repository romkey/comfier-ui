import { Controller } from "@hotwired/stimulus"

// Share toggle on the studio form (local only) and result detail (PATCH + Turbo Stream).
export default class extends Controller {
  static targets = ["shareResult"]
  static values = { url: String, live: Boolean }

  update() {
    if (!this.liveValue) return

    const body = new FormData()
    body.append("share_result", this.shareResultTarget.checked ? "1" : "0")

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        Accept: "text/vnd.turbo-stream.html",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content
      },
      body,
      credentials: "same-origin"
    })
      .then((response) => {
        if (response.ok) return response.text()
        throw new Error("Share update failed")
      })
      .then((html) => {
        if (html) window.Turbo.renderStreamMessage(html)
      })
      .catch(() => {})
  }
}
