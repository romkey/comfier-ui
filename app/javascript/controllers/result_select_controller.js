import { Controller } from "@hotwired/stimulus"

// Select mode on the Results page: shows a checkbox on each card and enables the bulk actions.
export default class extends Controller {
  static targets = ["toggle", "checkbox", "count", "action"]
  static classes = ["active"]

  toggle() {
    const active = this.element.classList.toggle(this.activeClass)
    this.toggleTarget.textContent = active ? "Done" : "Select"
    this.toggleTarget.classList.toggle("active", active)
    if (!active) this.selectNone()
  }

  selectAll() {
    this.checkboxTargets.forEach((box) => { box.checked = true })
    this.refresh()
  }

  selectNone() {
    this.checkboxTargets.forEach((box) => { box.checked = false })
    this.refresh()
  }

  // Cards replaced by a broadcast come back unticked, so recount whenever the list changes.
  checkboxTargetConnected() { this.refresh() }
  checkboxTargetDisconnected() { this.refresh() }

  refresh() {
    const count = this.selected.length
    if (this.hasCountTarget) this.countTarget.textContent = count
    this.actionTargets.forEach((button) => { button.disabled = count === 0 })
  }

  confirm(event) {
    if (event.submitter?.value !== "delete") return

    const count = this.selected.length
    if (!window.confirm(`Delete ${count} ${count === 1 ? "result" : "results"} permanently?`)) event.preventDefault()
  }

  get selected() {
    return this.checkboxTargets.filter((box) => box.checked)
  }
}
