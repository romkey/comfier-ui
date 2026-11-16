import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["preset", "description"]

  apply() {
    if (!this.presetTarget.value) return
    this.descriptionTarget.value = this.presetTarget.value
    this.descriptionTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
