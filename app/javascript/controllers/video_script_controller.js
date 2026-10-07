import { Controller } from "@hotwired/stimulus"

// "Write a script" on the Video page. Starts a VideoScriptJob, polls it while chat writes, and
// replaces the description with the script. The server retries once on failure; Cancel stops waiting
// and tells the server to drop the reply; Undo puts the original description back.
//
// Each click is a run. Cancel ends the current run, and any response that comes back for an ended
// run is ignored, including the create response when Cancel lands before the request has an id.
export default class extends Controller {
  static targets = ["prompt", "start", "spinner", "status", "cancel", "undo"]
  static values = { url: String }

  static POLL_MS = 1500

  connect() {
    this.form = this.element.closest("form")
    this.idleText = this.statusTarget.textContent.trim()
    this.run = 0
  }

  disconnect() {
    this.endRun()
  }

  async start() {
    const prompt = this.promptTarget.value.trim()
    if (!prompt) {
      this.show("idle", "Describe the video first, then ask for a script.")
      this.promptTarget.focus()
      return
    }

    const run = this.endRun() // a fresh run; responses for any earlier one are ignored
    this.original = this.promptTarget.value
    this.show("working", "Asking chat to write a script…")
    try {
      const response = await this.request(this.urlValue, { method: "POST", body: this.specs() })
      const data = await response.json()
      if (run !== this.run) return this.drop(response.ok && data.id)
      if (!response.ok) return this.show("idle", data.error || "Couldn't start the script.")
      this.id = data.id
      this.poll(run)
    } catch {
      if (run === this.run) this.show("idle", "Couldn't reach Comfier. Try again.")
    }
  }

  cancel() {
    const id = this.id
    this.endRun()
    this.show("idle", "Cancelled. Your description is unchanged.")
    this.drop(id)
  }

  undo() {
    if (this.original === undefined) return
    this.setPrompt(this.original)
    this.original = undefined
    this.show("idle", "Restored your original description.")
  }

  poll(run) {
    this.timer = setTimeout(() => this.check(run), this.constructor.POLL_MS)
  }

  async check(run) {
    let data
    try {
      const response = await this.request(`${this.urlValue}/${this.id}`)
      if (!response.ok) throw new Error(response.statusText)
      data = await response.json()
    } catch {
      if (run === this.run) this.poll(run)
      return
    }
    if (run !== this.run) return // cancelled or restarted while this check was in flight

    switch (data.status) {
      case "pending":
        return this.poll(run)
      case "retrying":
        this.show("working", "Chat couldn't write the script. Trying once more…")
        return this.poll(run)
      case "succeeded":
        this.id = undefined
        this.setPrompt(data.script)
        return this.show("done", "Script written into your description.")
      case "failed":
        this.id = undefined
        return this.show("idle", `Chat couldn't write a script after two tries${data.error ? `: ${data.error}` : "."}`)
      default:
        this.id = undefined
        return this.show("idle", this.idleText)
    }
  }

  // Ends the current run and returns the number of the next one.
  endRun() {
    clearTimeout(this.timer)
    this.id = undefined
    return ++this.run
  }

  // Tells the server to throw away a request's reply.
  drop(id) {
    if (id) this.request(`${this.urlValue}/${id}`, { method: "DELETE" }).catch(() => {})
  }

  // idle: button ready · working: spinner + Cancel, description locked · done: Undo offered
  show(state, message) {
    const working = state === "working"
    this.startTarget.disabled = working
    this.spinnerTarget.classList.toggle("d-none", !working)
    this.cancelTarget.classList.toggle("d-none", !working)
    this.undoTarget.classList.toggle("d-none", state !== "done")
    this.promptTarget.readOnly = working
    this.submitButtons().forEach((button) => { button.disabled = working })
    this.statusTarget.textContent = message
  }

  setPrompt(text) {
    this.promptTarget.value = text
    this.promptTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  specs() {
    const body = new FormData()
    for (const [key, value] of new FormData(this.form)) {
      if (/^generation\[(workflow_id|prompt|aspect_ratio|duration)\]$/.test(key)) body.append(key, value)
    }
    return body
  }

  submitButtons() {
    return this.form ? [...this.form.querySelectorAll("[type=submit]")] : []
  }

  request(url, options = {}) {
    const token = document.querySelector("meta[name=csrf-token]")?.content
    return fetch(url, {
      ...options,
      headers: { Accept: "application/json", ...(token ? { "X-CSRF-Token": token } : {}) },
      credentials: "same-origin"
    })
  }
}
