import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source"]

  async copy() {
    const text = this.sourceTarget.value || this.sourceTarget.textContent
    await navigator.clipboard.writeText(text.trim())
  }
}
