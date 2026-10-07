import asyncio

import pytest

from comfier_agent import jobs
from comfier_agent.jobs import failure_message, output_kind, split_allowed, validation_error_text
from comfier_agent.transfer import UploadError, upload_file_multipart


def test_output_allowlist_matches_the_frontend():
    assert output_kind("a.PNG") == "image"
    assert output_kind("clip.mov") == "video"
    assert output_kind("voice.flac") == "audio"
    assert output_kind("mesh.fbx") == "3d"
    for name in ("page.html", "vector.svg", "notes.txt", "data.json", "shape.stl", "old.bmp"):
        assert output_kind(name) is None


def test_split_allowed_skips_unsupported_files():
    allowed, skipped = split_allowed([
        {"filename": "a.png", "node": "9"},
        {"filename": "b.html", "node": "9"},
    ])
    assert [f["filename"] for f in allowed] == ["a.png"]
    assert skipped == ["b.html"]


def test_failure_message_drops_empty_fields_and_stringifies_node():
    msg = failure_message("j_1", "execute", "boom", {}, node=7, exception_type=None, node_errors={})
    assert msg["node"] == "7"
    assert "exception_type" not in msg
    assert "node_errors" not in msg


def test_failure_message_names_oom_consistently():
    msg = failure_message("j_1", "execute", "Allocation on device failed", {},
                          exception_type="torch.OutOfMemoryError")
    assert msg["error"].startswith("Out of memory")
    same = failure_message("j_1", "execute", "CUDA out of memory. Tried to allocate 2 GiB", {})
    assert same["error"] == "CUDA out of memory. Tried to allocate 2 GiB"


def test_failure_message_keeps_the_traceback_tail_bounded():
    msg = failure_message("j_1", "execute", "x", {}, traceback_tail="line\n" * 5000)
    assert len(msg["traceback_tail"]) == 8000


def test_validation_error_text_reads_comfyui_errors():
    error = {"type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation",
             "details": "KSampler: sampler_name not in list"}
    assert validation_error_text(error) == "Prompt outputs failed validation: KSampler: sampler_name not in list"
    assert validation_error_text("bad") == "bad"
    assert validation_error_text(True) == "invalid prompt"


@pytest.mark.asyncio
async def test_completed_job_sends_kind_and_skips_unsupported_outputs(agent):
    await agent.start()
    prompt_id = await agent.run_to_execution()
    await agent.finish(prompt_id, {"out.png": b"PNG", "report.html": b"<html>"})
    (done,) = await agent.front.wait_for_types("job.completed", timeout=8)
    assert [o["filename"] for o in done["outputs"]] == ["out.png"]
    assert done["outputs"][0]["upload_id"] == "u_test_1"
    assert "report.html" in done["warning"]
    assert agent.front.uploads[0]["kind"] == "image"


@pytest.mark.asyncio
async def test_waits_for_history_written_after_execution_success(agent, monkeypatch):
    monkeypatch.setattr(jobs, "HISTORY_POLL_S", 0.05)
    await agent.start()
    prompt_id = await agent.run_to_execution()
    agent.comfy.output_files["clip.mp4"] = b"MP4"
    await agent.comfy.push_ws({"type": "execution_start", "prompt_id": prompt_id})
    await agent.comfy.push_ws({"type": "execution_success", "prompt_id": prompt_id})
    await asyncio.sleep(0.3)
    assert not agent.front.of_type("job.completed")
    agent.comfy.history[prompt_id] = {
        "outputs": {"9": {"images": [{"filename": "clip.mp4", "type": "output", "subfolder": ""}]}},
    }
    (done,) = await agent.front.wait_for_types("job.completed", timeout=8)
    assert [o["filename"] for o in done["outputs"]] == ["clip.mp4"]


@pytest.mark.asyncio
async def test_history_that_never_appears_fails_at_outputs(agent, monkeypatch):
    monkeypatch.setattr(jobs, "HISTORY_POLL_S", 0.05)
    monkeypatch.setattr(jobs, "HISTORY_WAIT_S", 0.2)
    await agent.start()
    prompt_id = await agent.run_to_execution()
    await agent.comfy.push_ws({"type": "execution_success", "prompt_id": prompt_id})
    (failed,) = await agent.front.wait_for_types("job.failed", timeout=8)
    assert failed["stage"] == "outputs"
    assert "history" in failed["error"]
    assert not agent.front.of_type("job.completed")


@pytest.mark.asyncio
async def test_missing_upload_id_fails_the_job_at_outputs(agent):
    await agent.start()
    agent.front.upload_replies = [(200, {"ok": True})]
    prompt_id = await agent.run_to_execution()
    await agent.finish(prompt_id, {"out.png": b"PNG"})
    (failed,) = await agent.front.wait_for_types("job.failed", timeout=8)
    assert failed["stage"] == "outputs"
    assert "upload_id" in failed["error"]
    assert not agent.front.of_type("job.completed")


@pytest.mark.asyncio
async def test_415_is_permanent(agent):
    await agent.start()
    agent.front.upload_replies = [(415, {"error": "not an image"})]
    prompt_id = await agent.run_to_execution()
    await agent.finish(prompt_id, {"out.png": b"PNG"})
    (failed,) = await agent.front.wait_for_types("job.failed", timeout=8)
    assert failed["stage"] == "outputs"
    assert "415" in failed["error"]
    assert agent.front.upload_attempts == 1


@pytest.mark.asyncio
async def test_execution_error_reports_node_and_exception(agent):
    await agent.start()
    prompt_id = await agent.run_to_execution()
    await agent.comfy.push_ws({"type": "execution_start", "prompt_id": prompt_id})
    await agent.comfy.push_ws({
        "type": "execution_error",
        "prompt_id": prompt_id,
        "node_id": "3",
        "node_type": "KSampler",
        "exception_type": "RuntimeError",
        "exception_message": "shape mismatch",
        "traceback": ["Traceback (most recent call last):", "RuntimeError: shape mismatch"],
    })
    (failed,) = await agent.front.wait_for_types("job.failed", timeout=8)
    assert failed["stage"] == "execute"
    assert failed["node"] == "3"
    assert failed["exception_type"] == "RuntimeError"
    assert "shape mismatch" in failed["traceback_tail"]


@pytest.mark.asyncio
async def test_validation_failure_reports_node_errors(agent):
    await agent.start()
    agent.comfy.reject_prompt = {
        "error": {"message": "Prompt outputs failed validation", "details": ""},
        "node_errors": {"3": {"class_type": "KSampler", "errors": [{"message": "Value not in list"}]}},
    }
    await agent.front.send(agent.assign())
    (failed,) = await agent.front.wait_for_types("job.failed", timeout=8)
    assert failed["stage"] == "validate"
    assert failed["error"] == "Prompt outputs failed validation"
    assert failed["node_errors"]["3"]["class_type"] == "KSampler"


@pytest.mark.asyncio
async def test_upload_retries_transient_errors_with_a_fresh_body(tmp_path):
    from aiohttp import ClientSession, web

    bodies = []

    async def handler(request):
        data = await request.post()
        bodies.append(data["file"].file.read())
        if len(bodies) < 3:
            return web.json_response({"error": "restarting"}, status=503)
        return web.json_response({"upload_id": "u_1"})

    app = web.Application()
    app.router.add_post("/up", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # noqa: SLF001
    path = tmp_path / "out.png"
    path.write_bytes(b"PNGDATA")
    waits = []

    async def fake_sleep(seconds):
        waits.append(seconds)

    try:
        async with ClientSession() as session:
            resp = await upload_file_multipart(
                session, f"http://127.0.0.1:{port}/up", auth_header="Bearer k", fields={"node": "9"},
                file_path=str(path), filename="out.png", mime="image/png", sleep=fake_sleep,
            )
            assert resp["upload_id"] == "u_1"
            assert bodies == [b"PNGDATA"] * 3
            assert waits == [2, 4]

            bodies.clear()
            with pytest.raises(UploadError) as exc:
                await upload_file_multipart(
                    session, f"http://127.0.0.1:{port}/up", auth_header="Bearer k", fields={},
                    file_path=str(path), filename="out.png", mime="image/png", retry_for_s=1, sleep=fake_sleep,
                )
            assert not exc.value.permanent
            assert len(bodies) == 1
    finally:
        await runner.cleanup()
    await asyncio.sleep(0)
