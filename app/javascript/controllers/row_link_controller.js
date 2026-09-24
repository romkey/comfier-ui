import { Controller } from "@hotwired/stimulus"

// Makes a whole table row open its detail page, without hijacking clicks on its own buttons or links.
export default class extends Controller {
  static values = { href: String }

  connect() {
    this.element.addEventListener("click", this.visit)
  }

  disconnect() {
    this.element.removeEventListener("click", this.visit)
  }

  visit = (event) => {
    if (event.target.closest("a, button, form, input, select, textarea, .dropdown")) return
    Turbo.visit(this.hrefValue)
  }
}
