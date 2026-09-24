import { Controller } from "@hotwired/stimulus"

// Reloads just this frame when a refresh broadcast arrives, instead of refreshing the whole page
// (which would throw away anything being typed into forms elsewhere on it).
export default class extends Controller {
  connect() {
    document.addEventListener("turbo:before-stream-render", this.intercept)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.intercept)
  }

  intercept = (event) => {
    if (event.target.getAttribute("action") !== "refresh") return

    event.preventDefault()
    this.element.reload()
  }
}
