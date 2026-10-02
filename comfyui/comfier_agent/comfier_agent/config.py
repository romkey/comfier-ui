"""Load and validate agent configuration."""

from __future__ import annotations

import json
import os
import socket
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from comfier_agent import __version__

LOG = __import__("logging").getLogger("comfier_agent")

BOOL_TRUE = frozenset({"1", "true", "yes", "on"})


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in BOOL_TRUE


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _parse_hosts(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [h.strip().lower() for h in raw.split(",") if h.strip()]


def detect_comfyui_url() -> str:
    try:
        from comfy.cli_args import args  # type: ignore

        port = getattr(args, "port", 8188)
        tls = getattr(args, "tls_keyfile", None)
        scheme = "https" if tls else "http"
        return f"{scheme}://127.0.0.1:{port}"
    except Exception:
        return "http://127.0.0.1:8188"


def default_config_path() -> Path:
    try:
        import folder_paths  # type: ignore

        user = getattr(folder_paths, "get_user_directory", None)
        if user:
            base = Path(user())
        else:
            base = Path(__file__).resolve().parent.parent
    except Exception:
        base = Path(__file__).resolve().parent.parent
    return base / "comfier_agent.json"


def _validate_url(url: str, allow_insecure: bool) -> str | None:
    if not url:
        return "frontend URL is required"
    parsed = urlparse(url)
    if parsed.scheme == "https":
        return None
    if parsed.scheme == "http" and allow_insecure:
        return None
    if parsed.scheme == "http":
        return "frontend URL must be https (set COMFIER_ALLOW_INSECURE=true for development)"
    return "frontend URL must be http or https"


def _redact_key(key: str | None) -> dict[str, Any]:
    if not key:
        return {"api_key_set": False, "api_key_suffix": None}
    return {"api_key_set": True, "api_key_suffix": key[-4:] if len(key) >= 4 else "****"}


@dataclass
class AgentConfig:
    frontend_url: str = ""
    api_key: str = ""
    backend_name: str = field(default_factory=socket.gethostname)
    comfyui_url: str = field(default_factory=detect_comfyui_url)
    enabled: bool = True
    accept_when_local_busy: bool = False
    heartbeat_seconds: int = 10
    inventory_poll_seconds: int = 60
    max_download_mb: int = 200
    upload_retry_s: int = 600
    allow_insecure: bool = False
    keep_outputs: bool = False
    comfyui_input_dir: str | None = None
    comfyui_output_dir: str | None = None
    comfyui_models_dir: str | None = None
    allow_model_downloads: bool = True
    model_download_hosts: list[str] = field(default_factory=list)
    max_model_download_gb: float = 50.0
    min_free_disk_gb: float = 10.0
    max_concurrent_downloads: int = 1
    allow_pickle_formats: bool = True
    hf_endpoint: str | None = None
    hf_proxy_token: str | None = None
    hf_proxy_token_header: str = "X-Proxy-Token"
    agent_version: str = __version__
    config_path: Path | None = None

    ok: bool = True
    idle_reason: str = ""

    @property
    def frontend_origin(self) -> tuple[str, str, int, str]:
        p = urlparse(self.frontend_url.rstrip("/"))
        return (p.scheme, p.hostname or "", p.port or (443 if p.scheme == "https" else 80), p.path.rstrip("/"))

    def ws_url(self) -> str:
        p = urlparse(self.frontend_url.rstrip("/"))
        scheme = "wss" if p.scheme == "https" else "ws"
        if not self.allow_insecure and p.scheme != "https":
            scheme = "wss"
        host = p.netloc
        path = (p.path.rstrip("/") + "/api/agent/ws").replace("//", "/")
        return f"{scheme}://{host}{path}"

    def public_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d.pop("api_key", None)
        d.update(_redact_key(self.api_key))
        d["config_path"] = str(self.config_path) if self.config_path else None
        d.pop("ok", None)
        d.pop("idle_reason", None)
        return d


def _merge_file(data: dict[str, Any], cfg: AgentConfig) -> None:
    mapping = {
        "frontend_url": "frontend_url",
        "api_key": "api_key",
        "backend_name": "backend_name",
        "comfyui_url": "comfyui_url",
        "enabled": "enabled",
        "accept_when_local_busy": "accept_when_local_busy",
        "heartbeat_seconds": "heartbeat_seconds",
        "inventory_poll_seconds": "inventory_poll_seconds",
        "max_download_mb": "max_download_mb",
        "upload_retry_s": "upload_retry_s",
        "allow_insecure": "allow_insecure",
        "keep_outputs": "keep_outputs",
        "comfyui_input_dir": "comfyui_input_dir",
        "comfyui_output_dir": "comfyui_output_dir",
        "comfyui_models_dir": "comfyui_models_dir",
        "allow_model_downloads": "allow_model_downloads",
        "model_download_hosts": "model_download_hosts",
        "max_model_download_gb": "max_model_download_gb",
        "min_free_disk_gb": "min_free_disk_gb",
        "max_concurrent_downloads": "max_concurrent_downloads",
        "allow_pickle_formats": "allow_pickle_formats",
    }
    for key, attr in mapping.items():
        if key in data and data[key] is not None:
            setattr(cfg, attr, data[key])


def load_config(*, sidecar: bool = False, overrides: dict[str, Any] | None = None) -> AgentConfig:
    cfg = AgentConfig()
    path = default_config_path()
    cfg.config_path = path
    if path.is_file():
        try:
            _merge_file(json.loads(path.read_text(encoding="utf-8")), cfg)
        except (OSError, json.JSONDecodeError) as exc:
            LOG.warning("Could not read config file %s: %s", path, exc)

    if overrides:
        if overrides.get("config_path") is not None:
            cfg.config_path = Path(overrides["config_path"])
            path = cfg.config_path
            if path.is_file():
                try:
                    _merge_file(json.loads(path.read_text(encoding="utf-8")), cfg)
                except (OSError, json.JSONDecodeError):
                    pass
        for key, value in overrides.items():
            if key == "config_path":
                continue
            if value is not None and hasattr(cfg, key):
                setattr(cfg, key, value)

    if os.environ.get("COMFIER_URL"):
        cfg.frontend_url = os.environ["COMFIER_URL"].strip()
    if os.environ.get("COMFIER_API_KEY"):
        cfg.api_key = os.environ["COMFIER_API_KEY"].strip()
    if os.environ.get("COMFIER_BACKEND_NAME"):
        cfg.backend_name = os.environ["COMFIER_BACKEND_NAME"].strip()
    if os.environ.get("COMFIER_COMFYUI_URL"):
        cfg.comfyui_url = os.environ["COMFIER_COMFYUI_URL"].strip()
    cfg.enabled = _env_bool("COMFIER_ENABLED", cfg.enabled)
    cfg.accept_when_local_busy = _env_bool("COMFIER_SHARE_QUEUE", cfg.accept_when_local_busy)
    cfg.allow_insecure = _env_bool("COMFIER_ALLOW_INSECURE", cfg.allow_insecure)
    cfg.keep_outputs = _env_bool("COMFIER_KEEP_OUTPUTS", cfg.keep_outputs)
    cfg.allow_model_downloads = _env_bool("COMFIER_ALLOW_MODEL_DOWNLOADS", cfg.allow_model_downloads)
    if os.environ.get("COMFIER_INPUT_DIR"):
        cfg.comfyui_input_dir = os.environ["COMFIER_INPUT_DIR"]
    if os.environ.get("COMFIER_OUTPUT_DIR"):
        cfg.comfyui_output_dir = os.environ["COMFIER_OUTPUT_DIR"]
    if os.environ.get("COMFIER_MODELS_DIR"):
        cfg.comfyui_models_dir = os.environ["COMFIER_MODELS_DIR"]
    hosts = os.environ.get("COMFIER_MODEL_HOSTS")
    if hosts is not None:
        cfg.model_download_hosts = _parse_hosts(hosts)
    cfg.heartbeat_seconds = _env_int("COMFIER_HEARTBEAT_SECONDS", cfg.heartbeat_seconds)
    cfg.inventory_poll_seconds = _env_int("COMFIER_INVENTORY_POLL_SECONDS", cfg.inventory_poll_seconds)
    cfg.max_download_mb = _env_int("COMFIER_MAX_DOWNLOAD_MB", cfg.max_download_mb)
    cfg.upload_retry_s = _env_int("COMFIER_UPLOAD_RETRY_SECONDS", cfg.upload_retry_s)
    if os.environ.get("HF_ENDPOINT"):
        cfg.hf_endpoint = os.environ["HF_ENDPOINT"].strip()
    if os.environ.get("HF_PROXY_TOKEN"):
        cfg.hf_proxy_token = os.environ["HF_PROXY_TOKEN"].strip()
    if os.environ.get("HF_PROXY_TOKEN_HEADER"):
        cfg.hf_proxy_token_header = os.environ["HF_PROXY_TOKEN_HEADER"].strip()

    if sidecar and not cfg.comfyui_url:
        cfg.comfyui_url = detect_comfyui_url()

    if not cfg.enabled:
        cfg.ok = False
        cfg.idle_reason = "Comfier agent is disabled (COMFIER_ENABLED=false)"
        return cfg
    if not cfg.frontend_url or not cfg.api_key:
        cfg.ok = False
        cfg.idle_reason = "Comfier agent idle: set COMFIER_URL and COMFIER_API_KEY"
        return cfg
    err = _validate_url(cfg.frontend_url, cfg.allow_insecure)
    if err:
        cfg.ok = False
        cfg.idle_reason = f"Comfier agent idle: {err}"
    return cfg


def save_config(cfg: AgentConfig, updates: dict[str, Any]) -> None:
    path = cfg.config_path or default_config_path()
    existing: dict[str, Any] = {}
    if path.is_file():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            existing = {}
    for key, value in updates.items():
        if key == "api_key" and not value:
            continue
        if value is not None:
            existing[key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(existing, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
