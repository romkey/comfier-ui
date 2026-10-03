/** Comfier agent panel: connection state, the last close reason, and the agent's settings. */
import { app } from "../../scripts/app.js";

const POLL_MS = 5000;

const STATE_LABELS = {
  connected: "Connected",
  connecting: "Connecting…",
  waiting: "Not connected",
  disabled: "Not running",
};

const CSS = `
.comfier-panel { padding: 10px 12px; font-size: 13px; line-height: 1.4; color: var(--fg-color); }
.comfier-panel h3 { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: .65; margin: 14px 0 6px; }
.comfier-panel .row { display: flex; justify-content: space-between; gap: 8px; padding: 2px 0; }
.comfier-panel .muted { opacity: .65; }
.comfier-panel .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-right: 6px; }
.comfier-panel .ok { background: #3fb950; } .comfier-panel .warn { background: #d29922; }
.comfier-panel .bad { background: #f85149; } .comfier-panel .off { background: #6e7681; }
.comfier-panel .notice { border-left: 3px solid #d29922; padding: 6px 8px; margin: 8px 0; background: rgba(210,153,34,.08); }
.comfier-panel .notice.bad { border-color: #f85149; background: rgba(248,81,73,.08); }
.comfier-panel label { display: block; margin: 8px 0 2px; font-size: 12px; opacity: .8; }
.comfier-panel input[type=text], .comfier-panel input[type=password] {
  width: 100%; box-sizing: border-box; padding: 4px 6px; font-size: 13px;
  background: var(--comfy-input-bg); color: var(--input-text); border: 1px solid var(--border-color); border-radius: 4px;
}
.comfier-panel .check { display: flex; align-items: center; gap: 6px; margin-top: 8px; font-size: 12px; }
.comfier-panel button { margin-top: 10px; padding: 4px 10px; font-size: 13px; cursor: pointer; }
`;

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === "class") node.className = value;
    else if (key in node) node[key] = value;
    else node.setAttribute(key, value);
  }
  for (const child of children) {
    if (child != null) node.append(child);
  }
  return node;
}

function dotClass(status) {
  const conn = status.connection || {};
  if (conn.connected) return status.accepting ? "ok" : "warn";
  if (conn.state === "disabled") return "off";
  return conn.last_error ? "bad" : "warn";
}

function stateText(status) {
  const conn = status.connection || {};
  let text = STATE_LABELS[conn.state] || conn.state || "Unknown";
  if (conn.state === "waiting" && conn.retry_at) {
    const seconds = Math.max(0, Math.round(conn.retry_at - Date.now() / 1000));
    text += ` · retrying in ${seconds < 90 ? `${seconds}s` : `${Math.round(seconds / 60)} min`}`;
  }
  return text;
}

function renderStatus(root, status) {
  const conn = status.connection || {};
  const rows = [
    el("div", { class: "row" },
      el("span", {}, el("span", { class: `dot ${dotClass(status)}` }), stateText(status)),
      conn.last_close_code ? el("span", { class: "muted", title: "Last close code" }, String(conn.last_close_code)) : null),
    el("div", { class: "row" }, el("span", { class: "muted" }, "Server name"), el("span", {}, status.backend_name || "—")),
    el("div", { class: "row" }, el("span", { class: "muted" }, "Comfier"), el("span", {}, status.frontend_url || "Not set")),
  ];
  if (conn.connected) {
    rows.push(el("div", { class: "row" }, el("span", { class: "muted" }, "Taking jobs"),
      el("span", {}, status.accepting ? "Yes" : (status.accepting_reason || "No"))));
  }
  const problem = conn.last_close_reason || conn.last_error || status.idle_reason;
  if (problem && !conn.connected) {
    const severe = [4401, 4409, 4426].includes(conn.last_close_code) || /rejected/i.test(problem);
    rows.push(el("div", { class: severe ? "notice bad" : "notice" }, problem));
  }
  root.replaceChildren(...rows);
}

function renderForm(root, status, onSaved) {
  const cfg = status.config || {};
  const url = el("input", { type: "text", value: cfg.frontend_url || "", placeholder: "https://comfier.example.com" });
  const key = el("input", {
    type: "password",
    autocomplete: "off",
    placeholder: cfg.api_key_set ? `Saved key ending ${cfg.api_key_suffix} (leave blank to keep)` : "Paste the key from Comfier",
  });
  const name = el("input", { type: "text", value: cfg.backend_name || "" });
  const share = el("input", { type: "checkbox", checked: !!cfg.accept_when_local_busy });
  const hfCli = el("input", { type: "checkbox", checked: cfg.use_hf_cli !== false });
  const concurrency = el("input", {
    type: "number",
    min: "0",
    max: "32",
    value: cfg.max_concurrent_downloads ?? 1,
    style: "max-width: 5rem",
  });
  const result = el("div", { class: "muted" });
  const save = el("button", { type: "button" }, "Save and reconnect");
  save.addEventListener("click", async () => {
    save.disabled = true;
    result.textContent = "";
    try {
      const body = {
        frontend_url: url.value.trim(),
        backend_name: name.value.trim(),
        accept_when_local_busy: share.checked,
        use_hf_cli: hfCli.checked,
        max_concurrent_downloads: parseInt(concurrency.value, 10) || 0,
      };
      if (key.value.trim()) body.api_key = key.value.trim();
      const resp = await fetch("/comfier-agent/config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      key.value = "";
      result.textContent = data.restart_needed ? "Saved. Restart ComfyUI to start the agent." : "Saved.";
      onSaved();
    } catch (err) {
      result.textContent = `Couldn't save: ${err}`;
    } finally {
      save.disabled = false;
    }
  });
  root.replaceChildren(
    el("label", {}, "Comfier address"), url,
    el("label", {}, "API key"), key,
    el("label", {}, "Server name"), name,
    el("div", { class: "check" }, share, "Take Comfier jobs while my own ComfyUI queue is busy"),
    el("h3", {}, "Model downloads"),
    el("div", { class: "check" }, hfCli, "Use the Hugging Face CLI when a link is from the Hub"),
    el("label", {}, "Downloads at once (0 = no limit)"),
    concurrency,
    save, result,
  );
}

function mountPanel(container) {
  const statusBox = el("div");
  const formBox = el("div");
  container.replaceChildren(
    el("style", {}, CSS),
    el("div", { class: "comfier-panel" }, el("h3", {}, "Connection"), statusBox, el("h3", {}, "Settings"), formBox),
  );
  let formDrawn = false;
  const refresh = async () => {
    try {
      const resp = await fetch("/comfier-agent/status");
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const status = await resp.json();
      renderStatus(statusBox, status);
      if (!formDrawn) {
        renderForm(formBox, status, refresh);
        formDrawn = true;
      }
    } catch (err) {
      statusBox.replaceChildren(el("div", { class: "notice" }, `The agent isn't responding (${err.message}).`));
    }
  };
  refresh();
  const timer = setInterval(() => (container.isConnected ? refresh() : clearInterval(timer)), POLL_MS);
}

app.registerExtension({
  name: "Comfier.Agent",
  async setup() {
    const manager = app.extensionManager;
    if (manager?.registerSidebarTab) {
      manager.registerSidebarTab({
        id: "comfier-agent",
        icon: "pi pi-server",
        title: "Comfier",
        tooltip: "Comfier agent",
        type: "custom",
        render: (container) => mountPanel(container),
      });
      return;
    }
    try {
      const resp = await fetch("/comfier-agent/status");
      if (!resp.ok) return;
      const data = await resp.json();
      console.info("[Comfier] agent:", data.connection?.state, data.connection?.last_close_reason || "");
    } catch (_err) {
      // routes unavailable in sidecar mode
    }
  },
});
