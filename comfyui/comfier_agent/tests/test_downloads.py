import asyncio
import hashlib
import json
import sys

import pytest
from aiohttp import ClientSession, web
from fake_frontend import schema_errors

from comfier_agent.config import AgentConfig
from comfier_agent.models import PART_SUFFIX, ModelDownloadManager


def safetensors_bytes(size: int = 4096) -> bytes:
    header = json.dumps({"__metadata__": {}}).encode()
    body = len(header).to_bytes(8, "little") + header
    return body + b"\0" * (size - len(body))


PAYLOAD = safetensors_bytes()
SHA = hashlib.sha256(PAYLOAD).hexdigest()


class FileServer:
    """Serves model files, with Range support and a redirect to a different host name."""

    def __init__(self):
        self.requests: list[dict] = []
        self.slow = asyncio.Event()
        app = web.Application()
        app.router.add_get("/file/{name}", self.file)
        app.router.add_get("/slow/{name}", self.slow_file)
        app.router.add_get("/missing/{name}", self.missing)
        app.router.add_get("/redirect/{name}", self.redirect)
        app.router.add_get("/{path:.*}", self.hub_path)
        self.runner = web.AppRunner(app)
        self.port = 0

    async def start(self):
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        self.port = site._server.sockets[0].getsockname()[1]  # noqa: SLF001

    def url(self, path: str, host: str = "127.0.0.1") -> str:
        return f"http://{host}:{self.port}{path}"

    async def hub_path(self, request):
        if request.path.endswith(".safetensors"):
            return await self.file(request)
        return web.Response(status=404)

    async def file(self, request):
        self.requests.append({"path": request.path, "headers": dict(request.headers)})
        rng = request.headers.get("Range")
        if rng:
            start = int(rng.split("=")[1].rstrip("-"))
            return web.Response(status=206, body=PAYLOAD[start:])
        return web.Response(body=PAYLOAD)

    async def missing(self, _request):
        return web.Response(status=404)

    async def slow_file(self, request):
        resp = web.StreamResponse(headers={"Content-Length": str(len(PAYLOAD) * 1000)})
        await resp.prepare(request)
        await resp.write(PAYLOAD)
        await self.slow.wait()
        return resp

    async def redirect(self, request):
        self.requests.append({"path": request.path, "headers": dict(request.headers)})
        raise web.HTTPFound(self.url(f"/file/{request.match_info['name']}", host="localhost"))


@pytest.fixture
async def downloads(tmp_path, monkeypatch):
    monkeypatch.delitem(sys.modules, "folder_paths", raising=False)
    (tmp_path / "checkpoints").mkdir()
    server = FileServer()
    await server.start()
    session = ClientSession()
    sent: list[dict] = []

    async def send(msg):
        assert not schema_errors(msg), schema_errors(msg)
        sent.append(msg)

    async def rescan():
        pass

    def manager(**overrides):
        settings = {"min_free_disk_gb": 0, **overrides}
        cfg = AgentConfig(
            frontend_url="https://comfier.example.com",
            api_key="agent-key",
            allow_insecure=True,
            comfyui_models_dir=str(tmp_path),
            **settings,
        )
        return ModelDownloadManager(cfg, session, send, rescan)

    async def run(mgr, **msg):
        body = {"type": "model.download", "download_id": "d_1", "folder": "checkpoints",
                "filename": "model.safetensors", "url": server.url("/file/model.safetensors"), **msg}
        await mgr.handle(body)
        task = mgr.active[body["download_id"]].task
        await task
        return [m for m in sent if m["download_id"] == body["download_id"]]

    ctx = {"server": server, "sent": sent, "manager": manager, "run": run, "dir": tmp_path / "checkpoints"}
    try:
        yield ctx
    finally:
        server.slow.set()
        await session.close()
        await server.runner.cleanup()


def terminal(messages):
    return messages[-1]


@pytest.mark.asyncio
async def test_completes_with_hash_and_reports_bytes_total(downloads):
    msgs = await downloads["run"](downloads["manager"](), sha256=SHA, bytes=len(PAYLOAD))
    done = terminal(msgs)
    assert done["type"] == "model.download.completed"
    assert done["already_present"] is False
    assert (downloads["dir"] / "model.safetensors").read_bytes() == PAYLOAD
    progress = [m for m in msgs if m["type"] == "model.download.progress"]
    assert progress and progress[0]["bytes_total"] == len(PAYLOAD)


@pytest.mark.asyncio
@pytest.mark.parametrize("overrides,msg,reason", [
    ({"allow_model_downloads": False}, {}, "disabled"),
    ({"model_download_hosts": ["huggingface.co"]}, {}, "host_not_allowed"),
    ({}, {"filename": "tool.exe"}, "extension_not_allowed"),
    ({}, {"folder": "../etc"}, "invalid"),
    ({}, {"filename": "../escape.safetensors"}, "invalid"),
    ({"min_free_disk_gb": 10**9}, {"bytes": len(PAYLOAD)}, "disk_full"),
    ({}, {"sha256": "0" * 64}, "hash_mismatch"),
    ({}, {"bytes": len(PAYLOAD) + 1}, "size_mismatch"),
    ({"max_model_download_gb": 1e-9}, {}, "too_large"),
])
async def test_refusals_and_verification_failures(downloads, overrides, msg, reason):
    failed = terminal(await downloads["run"](downloads["manager"](**overrides), **msg))
    assert failed["type"] == "model.download.failed"
    assert failed["reason"] == reason
    assert not (downloads["dir"] / "model.safetensors").exists()
    assert not (downloads["dir"] / f"model.safetensors{PART_SUFFIX}").exists()


@pytest.mark.asyncio
async def test_http_error(downloads):
    url = downloads["server"].url("/missing/model.safetensors")
    failed = terminal(await downloads["run"](downloads["manager"](), url=url))
    assert (failed["reason"], failed["detail"]) == ("http_error", "HTTP 404")


@pytest.mark.asyncio
async def test_existing_file_with_other_contents(downloads):
    (downloads["dir"] / "model.safetensors").write_bytes(b"different")
    failed = terminal(await downloads["run"](downloads["manager"](), sha256=SHA))
    assert failed["reason"] == "exists"
    assert (downloads["dir"] / "model.safetensors").read_bytes() == b"different"


@pytest.mark.asyncio
async def test_already_present(downloads):
    (downloads["dir"] / "model.safetensors").write_bytes(PAYLOAD)
    done = terminal(await downloads["run"](downloads["manager"](), sha256=SHA))
    assert done["type"] == "model.download.completed"
    assert done["already_present"] is True
    assert not downloads["server"].requests


@pytest.mark.asyncio
async def test_resumes_a_partial_file(downloads):
    part = downloads["dir"] / f"model.safetensors{PART_SUFFIX}"
    part.write_bytes(PAYLOAD[:1000])
    done = terminal(await downloads["run"](downloads["manager"](), sha256=SHA))
    assert done["type"] == "model.download.completed"
    assert downloads["server"].requests[0]["headers"]["Range"] == "bytes=1000-"
    assert (downloads["dir"] / "model.safetensors").read_bytes() == PAYLOAD


@pytest.mark.asyncio
async def test_cancel_sends_one_cancelled_and_removes_the_part_file(downloads):
    mgr = downloads["manager"]()
    url = downloads["server"].url("/slow/model.safetensors")
    await mgr.handle({"type": "model.download", "download_id": "d_1", "folder": "checkpoints",
                      "filename": "model.safetensors", "url": url})
    task = mgr.active["d_1"].task
    part = downloads["dir"] / f"model.safetensors{PART_SUFFIX}"
    for _ in range(100):
        if part.exists() and part.stat().st_size:
            break
        await asyncio.sleep(0.02)
    await mgr.cancel("d_1")
    await task
    cancelled = [m for m in downloads["sent"] if m["type"] == "model.download.cancelled"]
    assert len(cancelled) == 1
    assert not part.exists()
    assert "d_1" not in mgr.active


@pytest.mark.asyncio
async def test_cross_host_redirect_drops_credentials(downloads):
    url = downloads["server"].url("/redirect/model.safetensors")
    headers = {"Authorization": "Bearer hf_secret", "X-Api-Key": "civitai"}
    done = terminal(await downloads["run"](downloads["manager"](), url=url, headers=headers, sha256=SHA))
    assert done["type"] == "model.download.completed"
    first, second = downloads["server"].requests
    assert first["headers"]["Authorization"] == "Bearer hf_secret"
    assert "Authorization" not in second["headers"]
    assert "X-Api-Key" not in second["headers"]


@pytest.mark.asyncio
async def test_redirect_to_a_host_outside_the_allowlist_fails(downloads):
    url = downloads["server"].url("/redirect/model.safetensors")
    failed = terminal(await downloads["run"](downloads["manager"](model_download_hosts=["127.0.0.1"]), url=url))
    assert (failed["reason"], failed["detail"]) == ("host_not_allowed", "localhost")


@pytest.mark.asyncio
async def test_hf_endpoint_rewrite_forwards_credentials(downloads):
    port = downloads["server"].port
    endpoint = f"http://127.0.0.1:{port}"
    hf_url = "https://huggingface.co/acme/model/resolve/main/model.safetensors"
    headers = {"Authorization": "Bearer comfier_hf"}
    done = terminal(await downloads["run"](
        downloads["manager"](hf_endpoint=endpoint, hf_proxy_token="proxy-secret"),
        url=hf_url,
        headers=headers,
        sha256=SHA,
    ))
    assert done["type"] == "model.download.completed"
    req = downloads["server"].requests[0]
    assert req["path"] == "/acme/model/resolve/main/model.safetensors"
    assert req["headers"]["Authorization"] == "Bearer comfier_hf"
    assert req["headers"]["X-Proxy-Token"] == "proxy-secret"


@pytest.mark.asyncio
async def test_hf_endpoint_uses_local_hf_token_when_comfier_sent_none(downloads, monkeypatch):
    port = downloads["server"].port
    endpoint = f"http://127.0.0.1:{port}"
    hf_url = "https://huggingface.co/acme/model/resolve/main/model.safetensors"
    monkeypatch.setenv("HF_TOKEN", "local_hf")
    done = terminal(await downloads["run"](
        downloads["manager"](hf_endpoint=endpoint),
        url=hf_url,
        sha256=SHA,
    ))
    assert done["type"] == "model.download.completed"
    assert downloads["server"].requests[0]["headers"]["Authorization"] == "Bearer local_hf"


@pytest.mark.asyncio
async def test_hf_endpoint_with_hub_allowlist(downloads):
    port = downloads["server"].port
    endpoint = f"http://127.0.0.1:{port}"
    hf_url = "https://huggingface.co/acme/model/resolve/main/model.safetensors"
    done = terminal(await downloads["run"](
        downloads["manager"](hf_endpoint=endpoint, model_download_hosts=["huggingface.co"]),
        url=hf_url,
        sha256=SHA,
    ))
    assert done["type"] == "model.download.completed"


@pytest.mark.asyncio
async def test_input_download_drops_auth_on_cross_host_redirect(downloads, tmp_path):
    from comfier_agent.transfer import download_to_file

    async with ClientSession() as session:
        url = downloads["server"].url("/redirect/model.safetensors")
        size = await download_to_file(session, url, str(tmp_path / "in.bin"), auth_header="Bearer agent-key")
    assert size == len(PAYLOAD)
    first, second = downloads["server"].requests
    assert first["headers"]["Authorization"] == "Bearer agent-key"
    assert "Authorization" not in second["headers"]
