import { Controller } from "@hotwired/stimulus"

// Switching styles on a studio page keeps what's been filled in. A style chip sends the form's
// settings along (carry[...]); the page comes back with them applied, and this swaps in just the form,
// keeping a picked reference image, which can't travel in a URL. Without JavaScript the chip is still a
// plain link that keeps the Tweak source.
const CARRIED = ["prompt", "negative_prompt", "aspect_ratio", "duration", "quality", "cfg_level", "denoise",
  "lyrics", "batch_size", "seed", "pinned_backend_id"]

export default class extends Controller {
  static targets = ["image", "note"]

  async switch(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return
    event.preventDefault()
    // currentTarget is gone once the event has been handled, so the link is read before awaiting.
    const href = event.currentTarget.href
    const url = this.carryUrl(href)
    try {
      const response = await fetch(url, { headers: { Accept: "text/html" }, credentials: "same-origin" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const page = new DOMParser().parseFromString(await response.text(), "text/html")
      const replacement = page.querySelector("form.studio-form")
      if (!replacement) throw new Error("no form in response")
      this.swapIn(replacement)
      window.history.replaceState({}, "", href)
    } catch (_error) {
      window.location.assign(url)
    }
  }

  carryUrl(href) {
    const url = new URL(href, window.location.href)
    const data = new FormData(this.element)
    for (const name of CARRIED) {
      const value = data.get(`generation[${name}]`)
      if (value !== null && value !== "") url.searchParams.set(`carry[${name}]`, value)
    }
    // Always present, so the page knows this is a switch and points out what's still needed.
    url.searchParams.set("carry[prompt]", data.get("generation[prompt]") ?? "")
    const reference = data.get("generation[reference_source]")
    if (reference) url.searchParams.set("reference", reference)
    return url.toString()
  }

  swapIn(replacement) {
    const files = this.element.querySelector('input[type="file"][name="generation[input_image]"]')?.files
    const shares = this.checkedShares()
    const form = document.importNode(replacement, true)
    this.element.replaceWith(form)

    const input = form.querySelector('input[type="file"][name="generation[input_image]"]')
    if (input && files?.length) {
      input.files = files
      input.required = false
      input.closest(".studio-needs-input")?.classList.remove("studio-needs-input")
    }
    for (const [name, checked] of shares) {
      const box = form.querySelector(`input[type="checkbox"][name="${name}"]`)
      if (box && !box.disabled) box.checked = checked
    }
    if (!form.querySelector(".studio-needs-input")) form.querySelector('[data-style-switch-target="note"]')?.remove()
    form.querySelector(".studio-needs-input textarea, .studio-needs-input input")?.focus()
  }

  checkedShares() {
    return Array.from(this.element.querySelectorAll('input[type="checkbox"][name^="generation[share"]'))
      .map((box) => [box.name, box.checked])
  }
}
