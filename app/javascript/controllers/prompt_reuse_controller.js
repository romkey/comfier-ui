import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["prompt"]

  reuse(event) {
    if (!this.hasPromptTarget) return

    this.promptTarget.value = event.currentTarget.dataset.promptReusePrompt
    this.promptTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.promptTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.promptTarget.focus()
  }
}
