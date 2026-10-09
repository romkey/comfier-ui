import { Controller } from "@hotwired/stimulus"

// The admin workflow form: ComfyUI workflows take exports and a graph; mflux and MLX video workflows
// take a recipe, which a preset can fill in.
export default class extends Controller {
  static targets = ["engine", "comfyui", "recipe", "preset", "json", "jsonLabel", "kind"]

  connect() {
    this.toggle()
  }

  toggle() {
    const engine = this.engineTarget.value
    const comfyui = engine === "comfyui"
    this.comfyuiTargets.forEach((el) => el.classList.toggle("d-none", !comfyui))
    this.recipeTargets.forEach((el) => el.classList.toggle("d-none", comfyui))
    this.jsonLabelTarget.textContent = comfyui ? "Workflow (API format JSON)" : "Recipe (JSON)"
    if (!this.hasPresetTarget) return

    Array.from(this.presetTarget.options).forEach((option) => {
      if (!option.value) return
      option.hidden = option.dataset.engine !== engine
    })
    if (this.presetTarget.selectedOptions[0]?.hidden) this.presetTarget.value = ""
  }

  applyPreset() {
    const option = this.presetTarget.selectedOptions[0]
    if (!option?.value) return

    const current = this.jsonTarget.value.trim()
    if (current && !confirm("Replace the recipe with this preset?")) {
      this.presetTarget.value = ""
      return
    }
    this.jsonTarget.value = option.dataset.recipe
    if (this.hasKindTarget && option.dataset.kind) this.kindTarget.value = option.dataset.kind
  }
}
