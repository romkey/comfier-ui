import { Controller } from "@hotwired/stimulus"

// The admin workflow form: ComfyUI workflows take exports and a graph; mflux and MLX video workflows
// take a recipe, which a preset can fill in. The preset list only ever holds the chosen engine's presets
// (rebuilt from a template: Safari ignores hidden on <option>).
export default class extends Controller {
  static targets = ["engine", "comfyui", "recipe", "preset", "presets", "json", "jsonLabel", "kind"]

  connect() {
    this.show()
  }

  // Runs on changed: show its sections and presets, and put the style on the one page it can make.
  toggle() {
    this.show()
    const kinds = this.engineTarget.selectedOptions[0]?.dataset.kinds?.split(",").filter(Boolean)
    if (this.hasKindTarget && kinds?.length === 1) this.kindTarget.value = kinds[0]
  }

  show() {
    const engine = this.engineTarget.value
    const comfyui = engine === "comfyui"
    this.comfyuiTargets.forEach((el) => el.classList.toggle("d-none", !comfyui))
    this.recipeTargets.forEach((el) => el.classList.toggle("d-none", comfyui))
    this.jsonLabelTarget.textContent = comfyui ? "Workflow (API format JSON)" : "Recipe (JSON)"
    if (this.hasPresetTarget && this.hasPresetsTarget) this.fillPresets(engine)
  }

  fillPresets(engine) {
    const choose = this.presetTarget.options[0]
    const matching = Array.from(this.presetsTarget.content.querySelectorAll("option"))
      .filter((option) => option.dataset.engine === engine)
      .map((option) => option.cloneNode(true))
    this.presetTarget.replaceChildren(choose, ...matching)
    this.presetTarget.value = ""
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
    // A preset always runs on its own engine.
    if (option.dataset.engine && this.engineTarget.value !== option.dataset.engine) {
      this.engineTarget.value = option.dataset.engine
      this.show()
    }
  }
}
