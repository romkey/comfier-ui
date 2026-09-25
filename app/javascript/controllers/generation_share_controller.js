import { Controller } from "@hotwired/stimulus"

// Share toggles on the studio form (local only) and result detail (PATCH + Turbo Stream).
export default class extends Controller {
  static targets = ["shareResult", "sharePrompt", "shareInput"]
  static values = { url: String, live: Boolean }

  connect() {
    this.syncDisabled()
  }

  update() {
    this.syncDisabled()
    if (!this.liveValue) return

    const body = new FormData()
    body.append("share_result", this.shareResultTarget.checked ? "1" : "0")
    body.append("share_prompt", this.sharePromptTarget.checked ? "1" : "0")
    if (this.hasShareInputTarget) {
      body.append("share_input", this.shareInputTarget.checked ? "1" : "0")
    }

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

  syncDisabled() {
    const sharing = this.shareResultTarget.checked
    this.sharePromptTarget.disabled = !sharing
    if (this.hasShareInputTarget) {
      this.shareInputTarget.disabled = !sharing
    }
  }
}
