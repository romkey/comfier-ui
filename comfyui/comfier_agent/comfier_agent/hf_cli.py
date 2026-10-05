"""Download Hugging Face Hub files via the ``hf`` / ``huggingface-cli`` CLI."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from typing import TYPE_CHECKING
from urllib.parse import urlparse, urlunparse

if TYPE_CHECKING:
    from comfier_agent.config import AgentConfig

LOG = logging.getLogger("comfier_agent")

HF_RESOLVE = re.compile(
    r"^https://(?:(?:www\.)?huggingface\.co|hf\.co)/"
    r"(?:(datasets|spaces)/)?([^/]+/[^/]+)/resolve/([^/?#]+)/([^?#]+)$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class HfFileSpec:
    repo_id: str
    revision: str
    filename: str


class HfCliError(Exception):
    pass


class HfCliUnavailable(HfCliError):
    pass


class HfCliCancelled(HfCliError):
    pass


def parse_hf_resolve_url(url: str) -> HfFileSpec | None:
    cleaned = (url or "").strip()
    parsed = urlparse(cleaned)
    if parsed.query or parsed.fragment:
        cleaned = urlunparse(parsed._replace(query="", fragment=""))
    match = HF_RESOLVE.match(cleaned)
    if not match:
        return None
    kind, repo, revision, filename = match.groups()
    repo_id = f"{kind}/{repo}" if kind else repo
    return HfFileSpec(repo_id=repo_id, revision=revision, filename=filename)


def hf_cli_executable() -> str | None:
    return shutil.which("hf") or shutil.which("huggingface-cli")


def token_from_headers(headers: dict[str, str]) -> str | None:
    auth = (headers.get("Authorization") or "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    return None


def cli_env(cfg: AgentConfig, headers: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    endpoint = (cfg.hf_endpoint or env.get("HF_ENDPOINT") or "").strip()
    if endpoint:
        env["HF_ENDPOINT"] = endpoint
    token = token_from_headers(headers) or (env.get("HF_TOKEN") or "").strip()
    if token:
        env["HF_TOKEN"] = token
    return env


async def download_file(
    cfg: AgentConfig,
    *,
    url: str,
    dest_path: str,
    headers: dict[str, str],
    cancel_check,
) -> int:
    spec = parse_hf_resolve_url(url)
    if not spec:
        raise HfCliUnavailable("not a Hugging Face resolve URL")
    cli = hf_cli_executable()
    if not cli:
        raise HfCliUnavailable("hf CLI not found on PATH")

    os.makedirs(os.path.dirname(dest_path) or ".", exist_ok=True)
    env = cli_env(cfg, headers)
    with tempfile.TemporaryDirectory(prefix="comfier-hf-") as tmp:
        cmd = [
            cli,
            "download",
            spec.repo_id,
            spec.filename,
            "--revision",
            spec.revision,
            "--local-dir",
            tmp,
        ]
        LOG.info("HF CLI download %s (%s) -> %s", spec.repo_id, spec.filename, dest_path)
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            while proc.returncode is None:
                if cancel_check():
                    proc.kill()
                    await proc.wait()
                    raise HfCliCancelled()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=0.5)
                except asyncio.TimeoutError:
                    continue
        except asyncio.CancelledError:
            proc.kill()
            await proc.wait()
            raise

        stderr = (await proc.stderr.read()).decode("utf-8", errors="replace") if proc.stderr else ""
        if proc.returncode != 0:
            detail = stderr.strip().splitlines()[-1] if stderr.strip() else f"exit {proc.returncode}"
            raise HfCliError(detail[:500])

        src = os.path.join(tmp, *spec.filename.split("/"))
        if not os.path.isfile(src):
            raise HfCliError("CLI finished but the file is missing")
        size = os.path.getsize(src)
        if os.path.exists(dest_path):
            os.remove(dest_path)
        shutil.move(src, dest_path)
        return size


def endpoint_host(url: str) -> str | None:
    return (urlparse(url).hostname or "").lower() or None
