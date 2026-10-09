"""Streaming HTTP download and multipart upload helpers."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import AsyncIterator, Awaitable, Callable
from urllib.parse import urljoin, urlparse

import aiohttp

LOG = logging.getLogger("comfier_agent")

CHUNK = 8 * 1024 * 1024
MAX_REDIRECTS = 5
REDIRECT_STATUSES = (301, 302, 303, 307, 308)
# Worth retrying: the frontend is restarting, overloaded, or asked us to slow down.
RETRYABLE_STATUSES = frozenset({408, 425, 429, 500, 502, 503, 504})
UPLOAD_RETRY_S = 600


class UploadError(Exception):
    """An output upload the frontend refused (permanent) or that kept failing (transient)."""

    def __init__(self, message: str, *, status: int | None = None, permanent: bool = False):
        super().__init__(message)
        self.status = status
        self.permanent = permanent


def redirect_target(current: str, location: str | None) -> str:
    if not location:
        raise aiohttp.ClientError("redirect without location")
    return urljoin(current, location)


def same_host(a: str, b: str) -> bool:
    return (urlparse(a).hostname or "").lower() == (urlparse(b).hostname or "").lower()


async def stream_download(
    session: aiohttp.ClientSession,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    max_bytes: int | None = None,
    dest_path: str | None = None,
    resume_from: int = 0,
) -> tuple[int, AsyncIterator[bytes] | None]:
    req_headers = dict(headers or {})
    if resume_from:
        req_headers["Range"] = f"bytes={resume_from}-"
    for _ in range(MAX_REDIRECTS + 1):
        async with session.get(url, headers=req_headers, allow_redirects=False) as resp:
            if resp.status in REDIRECT_STATUSES:
                target = redirect_target(url, resp.headers.get("Location"))
                if not same_host(url, target):
                    # Credentials were meant for the original host only.
                    req_headers = {k: v for k, v in req_headers.items() if k == "Range"}
                url = target
                continue
            return await _read_body(resp, max_bytes=max_bytes, dest_path=dest_path, resume_from=resume_from)
    raise aiohttp.ClientError("too many redirects")


async def _read_body(resp, *, max_bytes, dest_path, resume_from) -> tuple[int, AsyncIterator[bytes] | None]:
    if resp.status not in (200, 206):
        body = await resp.text()
        raise aiohttp.ClientResponseError(resp.request_info, resp.history, status=resp.status, message=body[:200])
    total = int(resp.headers.get("Content-Length") or 0)
    if resume_from and resp.status == 206:
        total += resume_from
    if max_bytes is not None and total and total > max_bytes:
        raise ValueError("file too large")
    if not dest_path:
        return total, resp.content.iter_chunked(CHUNK)

    append = bool(resume_from) and resp.status == 206
    done = resume_from if append else 0
    with open(dest_path, "ab" if append else "wb") as out:
        async for chunk in resp.content.iter_chunked(CHUNK):
            done += len(chunk)
            if max_bytes is not None and done > max_bytes:
                raise ValueError("file too large")
            out.write(chunk)
    return done, None


async def download_to_file(
    session: aiohttp.ClientSession,
    url: str,
    path: str,
    *,
    auth_header: str | None = None,
    max_bytes: int | None = None,
    expected_bytes: int | None = None,
) -> int:
    headers = {"Authorization": auth_header} if auth_header else None
    limit = max_bytes
    if expected_bytes is not None and limit is not None:
        limit = min(limit, expected_bytes)
    size, _ = await stream_download(session, url, headers=headers, max_bytes=limit, dest_path=path)
    if expected_bytes is not None and size != expected_bytes:
        raise ValueError(f"expected {expected_bytes} bytes, got {size}")
    return size


def same_origin(url: str, frontend_url: str) -> bool:
    a = urlparse(url)
    b = urlparse(frontend_url.rstrip("/"))
    return a.scheme == b.scheme and (a.hostname or "").lower() == (b.hostname or "").lower()


async def upload_file_multipart(
    session: aiohttp.ClientSession,
    upload_url: str,
    *,
    auth_header: str,
    fields: dict[str, str],
    file_path: str,
    filename: str,
    mime: str,
    retry_for_s: float = UPLOAD_RETRY_S,
    should_stop: Callable[[], bool] | None = None,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> dict:
    """POST one output, retrying transient failures with backoff for up to retry_for_s.

    Returns the frontend's JSON, which must include an upload_id. Raises UploadError.
    """
    deadline = time.monotonic() + retry_for_s
    attempt = 0
    while True:
        try:
            return await _post_once(session, upload_url, auth_header, fields, file_path, filename, mime)
        except UploadError as exc:
            if exc.permanent:
                raise
            error = exc
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as exc:
            error = UploadError(f"upload failed: {exc}")
        attempt += 1
        wait = min(2**attempt, 60)
        if time.monotonic() + wait > deadline or (should_stop and should_stop()):
            raise error
        LOG.warning("upload of %s failed (%s); retrying in %ss", filename, error, wait)
        await sleep(wait)


async def _post_once(session, upload_url, auth_header, fields, file_path, filename, mime) -> dict:
    data = aiohttp.FormData()
    for key, value in fields.items():
        data.add_field(key, value)
    with open(file_path, "rb") as body:
        data.add_field("file", body, filename=filename, content_type=mime)
        async with session.post(upload_url, data=data, headers={"Authorization": auth_header}) as resp:
            if resp.status >= 400:
                text = (await resp.text())[:500]
                raise UploadError(
                    f"upload HTTP {resp.status}: {text}".strip(),
                    status=resp.status,
                    permanent=resp.status not in RETRYABLE_STATUSES,
                )
            try:
                payload = await resp.json()
            except (aiohttp.ContentTypeError, ValueError) as exc:
                raise UploadError("upload response was not JSON", status=resp.status, permanent=True) from exc
    if not isinstance(payload, dict) or not payload.get("upload_id"):
        raise UploadError("upload response had no upload_id", status=resp.status, permanent=True)
    return payload
