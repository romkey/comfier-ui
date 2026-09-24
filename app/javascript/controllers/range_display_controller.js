import { Controller } from "@hotwired/stimulus"

// Shows the current value of a range input (e.g. denoise as a percentage).
export default class extends Controller {
  static targets = ["input", "output"]

  connect() {
    this.update()
  }

  update() {
    this.outputTarget.textContent = this.inputTarget.value
  }
}
