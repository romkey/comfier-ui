import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "icon"]
  static values = { text: String }

  async copy() {
    const text = this.hasTextValue ? this.textValue : (this.sourceTarget.value || this.sourceTarget.textContent)
    await navigator.clipboard.writeText(text.trim())
    this.showCopied()
  }

  showCopied() {
    if (!this.hasIconTarget) return

    const icon = this.iconTarget
    clearTimeout(this.resetTimer)
    icon.classList.replace("bi-clipboard", "bi-check-lg")
    this.resetTimer = setTimeout(() => icon.classList.replace("bi-check-lg", "bi-clipboard"), 1500)
  }

  disconnect() {
    clearTimeout(this.resetTimer)
  }
}
