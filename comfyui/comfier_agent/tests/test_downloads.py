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


def fp8_safetensors_bytes() -> bytes:
    """One e4m3fn weight [1.0, 2.0] with scale 0.5."""
    header = {"w.weight": {"dtype": "F8_E4M3", "shape": [2], "data_offsets": [0, 2]},
              "w.scale_weight": {"dtype": "F32", "shape": [], "data_offsets": [2, 6]}}
    data = json.dumps(header).encode()
    return len(data).to_bytes(8, "little") + data + bytes([0x38, 0x40]) + (0x3F000000).to_bytes(4, "little")


FP8_PAYLOAD = fp8_safetensors_bytes()


class FileServer:
    """Serves model files, with Range support and a redirect to a different host name."""

    def __init__(self):
        self.requests: list[dict] = []
        self.slow = asyncio.Event()
        app = web.Application()
        app.router.add_get("/file/{name}", self.file)
        app.router.add_get("/fp8/{name}", self.fp8)
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

    async def fp8(self, _request):
        return web.Response(body=FP8_PAYLOAD)

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
        if request.match_info["name"] != "model.safetensors":
            return web.Response(status=404)
        raise web.HTTPFound(self.url("/file/model.safetensors", host="localhost"))


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


async def delete(downloads, mgr, **msg):
    body = {"type": "model.delete", "delete_id": "x_1", "folder": "checkpoints", "filename": "model.safetensors",
            **msg}
    await mgr.delete(body)
    return [m for m in downloads["sent"] if m.get("delete_id") == body["delete_id"]][-1]


@pytest.mark.asyncio
async def test_delete_removes_the_file_and_its_partial_download(downloads):
    (downloads["dir"] / "model.safetensors").write_bytes(PAYLOAD)
    (downloads["dir"] / f"model.safetensors{PART_SUFFIX}").write_bytes(b"x")
    deleted = await delete(downloads, downloads["manager"]())

    assert deleted["type"] == "model.deleted"
    assert (deleted["bytes"], deleted["already_absent"]) == (len(PAYLOAD), False)
    assert not (downloads["dir"] / "model.safetensors").exists()
    assert not (downloads["dir"] / f"model.safetensors{PART_SUFFIX}").exists()


@pytest.mark.asyncio
async def test_deleting_a_file_that_isnt_there_succeeds(downloads):
    deleted = await delete(downloads, downloads["manager"]())
    assert deleted["type"] == "model.deleted" and deleted["already_absent"] is True


@pytest.mark.asyncio
@pytest.mark.parametrize("overrides,msg,reason", [
    ({"allow_model_downloads": False}, {}, "disabled"),
    ({}, {"folder": "../etc"}, "invalid"),
    ({}, {"folder": "custom_nodes"}, "invalid"),
    ({}, {"filename": "../escape.safetensors"}, "invalid"),
    ({}, {"filename": "notes.txt"}, "invalid"),
])
async def test_delete_refusals(downloads, overrides, msg, reason):
    (downloads["dir"] / "model.safetensors").write_bytes(PAYLOAD)
    failed = await delete(downloads, downloads["manager"](**overrides), **msg)
    assert failed["type"] == "model.delete.failed" and failed["reason"] == reason
    assert (downloads["dir"] / "model.safetensors").exists()


@pytest.mark.asyncio
async def test_a_file_being_downloaded_isnt_deleted(downloads):
    mgr = downloads["manager"]()
    await mgr.handle({"type": "model.download", "download_id": "d_slow", "folder": "checkpoints",
                      "filename": "model.safetensors", "url": downloads["server"].url("/slow/model.safetensors")})
    for _ in range(100):
        if mgr.paths_in_progress:
            break
        await asyncio.sleep(0.01)
    failed = await delete(downloads, mgr)
    assert failed["type"] == "model.delete.failed" and failed["reason"] == "busy"
    await mgr.cancel("d_slow")


@pytest.mark.asyncio
async def test_a_delete_right_after_a_cancel_waits_for_the_download_to_stop(downloads):
    mgr = downloads["manager"]()
    await mgr.handle({"type": "model.download", "download_id": "d_same", "folder": "checkpoints",
                      "filename": "model.safetensors", "url": downloads["server"].url("/slow/model.safetensors")})
    for _ in range(100):
        if mgr.paths_in_progress:
            break
        await asyncio.sleep(0.01)

    await mgr.cancel("d_same")
    await mgr.delete({"type": "model.delete", "delete_id": "x_1", "folder": "checkpoints",
                      "filename": "model.safetensors"})
    for _ in range(200):
        if any(m.get("delete_id") == "x_1" for m in downloads["sent"]):
            break
        await asyncio.sleep(0.01)

    types = [m["type"] for m in downloads["sent"] if m.get("download_id") == "d_same" or m.get("delete_id")]
    assert types[-2:] == ["model.download.cancelled", "model.deleted"]
    assert not (downloads["dir"] / f"model.safetensors{PART_SUFFIX}").exists()


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


@pytest.mark.asyncio
async def test_a_comfyui_folder_the_models_dir_doesnt_have_yet_takes_downloads(downloads, tmp_path):
    # LTX's latent upscalers go in latent_upscale_models, which older models folders don't have.
    msgs = await downloads["run"](downloads["manager"](), folder="latent_upscale_models", sha256=SHA)
    assert terminal(msgs)["type"] == "model.download.completed"
    assert (tmp_path / "latent_upscale_models" / "model.safetensors").read_bytes() == PAYLOAD


@pytest.mark.asyncio
async def test_folders_that_hold_code_or_settings_are_refused(downloads):
    failed = terminal(await downloads["run"](downloads["manager"](), folder="custom_nodes"))
    assert (failed["reason"], failed["detail"]) == ("invalid", "unknown folder custom_nodes")


@pytest.mark.asyncio
async def test_convert_saves_the_fp8_download_as_fp16(downloads):
    url = downloads["server"].url("/fp8/model_fp8_scaled.safetensors")
    msgs = await downloads["run"](downloads["manager"](), url=url,
                                  filename="model_fp16_from_fp8.safetensors", convert="fp8_to_fp16",
                                  sha256=hashlib.sha256(FP8_PAYLOAD).hexdigest(), bytes=len(FP8_PAYLOAD))
    done = terminal(msgs)
    assert done["type"] == "model.download.completed"
    assert "sha256" not in done
    out = (downloads["dir"] / "model_fp16_from_fp8.safetensors").read_bytes()
    length = int.from_bytes(out[:8], "little")
    assert json.loads(out[8:8 + length]) == {"w.weight": {"dtype": "F16", "shape": [2], "data_offsets": [0, 4]}}
    assert out[8 + length:] == bytes.fromhex("0038003c")  # fp16 0.5, 1.0
    assert sorted(p.name for p in downloads["dir"].iterdir()) == ["model_fp16_from_fp8.safetensors"]

    again = terminal(await downloads["run"](downloads["manager"](), download_id="d_2", url=url,
                                            filename="model_fp16_from_fp8.safetensors", convert="fp8_to_fp16",
                                            sha256=hashlib.sha256(FP8_PAYLOAD).hexdigest()))
    assert again["already_present"] is True


@pytest.mark.asyncio
async def test_convert_failure_removes_the_download(downloads):
    failed = terminal(await downloads["run"](downloads["manager"](), convert="fp8_to_fp16"))
    assert failed["type"] == "model.download.failed"
    assert "couldn't convert to fp16" in failed["detail"]
    assert list(downloads["dir"].iterdir()) == []


@pytest.mark.asyncio
async def test_cancelling_a_conversion_removes_its_files(downloads, monkeypatch):
    """Even when the converter thread ignores the cancel and finishes, nothing is left behind."""
    import time as _time

    import comfier_agent.models as models_mod

    def slow_convert(_src, dst, _cancelled):
        with open(dst, "wb") as out:
            out.write(b"partial fp16")
        _time.sleep(0.3)
        return 12

    monkeypatch.setattr(models_mod, "convert_fp8_to_fp16", slow_convert)
    mgr = downloads["manager"]()
    await mgr.handle({"type": "model.download", "download_id": "d_1", "folder": "checkpoints",
                      "filename": "m_fp16_from_fp8.safetensors", "convert": "fp8_to_fp16",
                      "url": downloads["server"].url("/fp8/m_fp8_scaled.safetensors")})
    task = mgr.active["d_1"].task
    converting = downloads["dir"] / ("m_fp16_from_fp8.safetensors" + models_mod.CONVERTING_SUFFIX)
    for _ in range(100):
        if converting.exists():
            break
        await asyncio.sleep(0.02)
    assert converting.exists()

    task.cancel()  # as at agent shutdown: no user cancel flag
    await task
    await asyncio.sleep(0.4)

    assert terminal(downloads["sent"])["type"] == "model.download.cancelled"
    assert list(downloads["dir"].iterdir()) == []
