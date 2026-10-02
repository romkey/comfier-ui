"""Rewrite Hugging Face Hub URLs through HF_ENDPOINT (caching proxy / mirror)."""

from __future__ import annotations

import logging
import os
from typing import TYPE_CHECKING
from urllib.parse import urlparse, urlunparse

if TYPE_CHECKING:
    from comfier_agent.config import AgentConfig

LOG = logging.getLogger("comfier_agent")

HF_HUB_HOSTS = frozenset({"huggingface.co", "www.huggingface.co", "hf.co"})
HF_ALLOWLIST_HOSTS = frozenset({"huggingface.co", "www.huggingface.co", "hf.co"})


def is_hf_hub_url(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return host in HF_HUB_HOSTS


def endpoint_hostname(endpoint: str | None) -> str | None:
    if not endpoint:
        return None
    return (urlparse(endpoint.rstrip("/")).hostname or "").lower()


def rewrite_url(url: str, endpoint: str | None) -> tuple[str, bool]:
    if not endpoint or not is_hf_hub_url(url):
        return url, False
    ep = urlparse(endpoint.rstrip("/"))
    orig = urlparse(url)
    ep_path = ep.path.rstrip("/")
    path = f"{ep_path}{orig.path}" if ep_path else orig.path
    rewritten = urlunparse((ep.scheme, ep.netloc, path, orig.params, orig.query, orig.fragment))
    LOG.info("HF_ENDPOINT rewrite: %s -> %s", url, rewritten)
    return rewritten, True


def proxy_headers(cfg: AgentConfig) -> dict[str, str]:
    if not cfg.hf_endpoint or not cfg.hf_proxy_token:
        return {}
    name = (cfg.hf_proxy_token_header or "X-Proxy-Token").strip()
    return {name: cfg.hf_proxy_token}


def local_hf_authorization() -> str | None:
    token = os.environ.get("HF_TOKEN")
    if not token:
        return None
    return f"Bearer {token.strip()}"


def ensure_hf_authorization(headers: dict[str, str], original_url: str) -> None:
    if headers.get("Authorization"):
        return
    if not is_hf_hub_url(original_url):
        return
    auth = local_hf_authorization()
    if auth:
        headers["Authorization"] = auth


def host_matches_allowlist(host: str, allowed_hosts: list[str]) -> bool:
    return any(host == h or host.endswith("." + h) for h in allowed_hosts)


def hf_endpoint_host_allowed(host: str, allowed_hosts: list[str], endpoint: str | None) -> bool:
    ep_host = endpoint_hostname(endpoint)
    if not ep_host or host != ep_host:
        return False
    return any(h in HF_ALLOWLIST_HOSTS for h in allowed_hosts)
