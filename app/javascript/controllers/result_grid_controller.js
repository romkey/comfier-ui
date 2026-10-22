import { Controller } from "@hotwired/stimulus"

// Picks a column count so result rows come out full instead of e.g. five then three.
// With a rows value (Recent) it shows exactly that many full rows and hides the overflow;
// otherwise (paged lists) it narrows the grid a little when that divides the cards evenly.
export default class extends Controller {
  static values = { rows: Number }

  connect() {
    this.layout = this.layout.bind(this)
    this.resizeObserver = new ResizeObserver(this.layout)
    this.resizeObserver.observe(this.element)
    this.mutationObserver = new MutationObserver(this.layout)
    this.mutationObserver.observe(this.element, { childList: true })
    this.layout()
  }

  disconnect() {
    this.resizeObserver.disconnect()
    this.mutationObserver.disconnect()
    this.element.classList.remove("result-grid-fitted")
    this.element.style.removeProperty("--result-cols")
  }

  layout() {
    const style = getComputedStyle(this.element)
    const minWidth = parseFloat(style.getPropertyValue("--result-min")) || 170
    const gap = parseFloat(style.columnGap) || 0
    const fit = Math.max(1, Math.floor((this.element.clientWidth + gap) / (minWidth + gap)))
    const cards = Array.from(this.element.children)

    let shown = cards.length
    if (this.rowsValue > 0 && shown > this.rowsValue * fit) shown = this.rowsValue * fit
    cards.forEach((card, index) => { card.hidden = index >= shown })

    this.element.style.setProperty("--result-cols", this.columnsFor(shown, fit))
    this.element.classList.add("result-grid-fitted")
  }

  // Fewest empty cells in the last row, without shrinking below two thirds of what fits.
  columnsFor(count, fit) {
    if (count <= fit) return fit

    let best = fit
    let bestEmpty = Infinity
    for (let cols = fit; cols >= Math.max(1, Math.ceil(fit * 2 / 3)); cols--) {
      const empty = (cols - (count % cols)) % cols
      if (empty < bestEmpty) [best, bestEmpty] = [cols, empty]
    }
    return best
  }
}
