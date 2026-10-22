"""Comfier asks an mflux or mlx-video server to fetch a model ahead of its first job."""

import json
import os
import subprocess
import sys

import pytest

from comfier_agent.engines import mflux as mflux_engine

FAKE_WORKER = os.path.join(os.path.dirname(__file__), "fake_mflux_worker.py")


@pytest.fixture
async def mac(agent, comfier_home, monkeypatch, tmp_path):
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hf"))
    monkeypatch.setattr(mflux_engine, "default_worker_argv", lambda: [sys.executable, FAKE_WORKER])
    runtime = await agent.start(engines=["mflux"], work_dir=str(comfier_home / "work"))
    yield agent, runtime
    await runtime.engines["mflux"].close()


def download(download_id, model, engine="mflux"):
    return {"type": "model.download", "download_id": download_id, "engine": engine, "model": model}


@pytest.mark.asyncio
async def test_a_model_is_fetched_and_reported_as_completed(mac):
    agent, _runtime = mac
    start = len(agent.front.messages)
    await agent.front.send(download("d_1", "qwen-image"))
    done = (await agent.front.wait_for_types("model.download.completed", timeout=10, after=start))[0]

    assert done["download_id"] == "d_1"
    assert done["folder"] == "mflux" and done["filename"] == "qwen-image"
    assert done["bytes"] == 2000
    # The engine is asked again what's downloaded, and a fresh inventory goes to Comfier.
    completed_at = agent.front.messages.index(done)
    inventory = (await agent.front.wait_for_types("inventory", timeout=10, after=completed_at))[0]
    assert "qwen-image" in inventory["engines"]["mflux"]["models"]


@pytest.mark.asyncio
async def test_a_failure_says_why(mac):
    agent, _runtime = mac
    await agent.front.send(download("d_2", "broken"))
    failed = (await agent.front.wait_for_types("model.download.failed", timeout=10))[0]
    assert failed["reason"] == "network" and "huggingface.co" in failed["detail"]


@pytest.mark.asyncio
async def test_a_download_can_be_cancelled(mac):
    agent, _runtime = mac
    await agent.front.send(download("d_3", "slow"))
    progressed = lambda: any(m.get("download_id") == "d_3" for m in agent.front.of_type("model.download.progress"))  # noqa: E731
    await agent.front.wait_for(progressed, timeout=10)
    await agent.front.send({"type": "model.download.cancel", "download_id": "d_3"})
    cancelled = (await agent.front.wait_for_types("model.download.cancelled", timeout=10))[0]
    assert cancelled["download_id"] == "d_3"


@pytest.mark.asyncio
async def test_an_engine_this_server_doesnt_run_is_refused(mac):
    agent, _runtime = mac
    await agent.front.send(download("d_4", "prince-canuma/LTX-2.3-distilled", engine="mlx_video"))
    failed = (await agent.front.wait_for_types("model.download.failed", timeout=10))[0]
    assert failed["reason"] == "invalid" and "mlx_video" in failed["detail"]


@pytest.mark.asyncio
async def test_a_downloaded_model_can_be_deleted(mac, tmp_path):
    agent, _runtime = mac
    await agent.front.send(download("d_5", "qwen-image"))
    listed = lambda: any("qwen-image" in m["engines"]["mflux"]["models"] for m in agent.front.of_type("inventory"))  # noqa: E731
    await agent.front.wait_for(listed, timeout=10)
    start = len(agent.front.messages)
    await agent.front.send({"type": "model.delete", "delete_id": "x_1", "engine": "mflux", "model": "qwen-image"})
    deleted = (await agent.front.wait_for_types("model.deleted", timeout=10, after=start))[0]

    assert deleted["bytes"] == 2000 and deleted["already_absent"] is False
    assert not (tmp_path / "hf" / "models--fake--qwen-image").exists()
    inventory = (await agent.front.wait_for_types("inventory", timeout=10, after=start))[0]
    assert "qwen-image" not in inventory["engines"]["mflux"]["models"]


@pytest.mark.asyncio
async def test_deleting_a_model_mflux_doesnt_know_is_refused(mac):
    agent, _runtime = mac
    await agent.front.send({"type": "model.delete", "delete_id": "x_2", "engine": "mflux", "model": "nope"})
    failed = (await agent.front.wait_for_types("model.delete.failed", timeout=10))[0]
    assert failed["reason"] == "invalid" and "nope" in failed["detail"]


def test_the_hf_download_worker_refuses_something_that_isnt_a_repo():
    out = subprocess.run([sys.executable, "-m", "comfier_agent.workers.hf_download", "../etc"], capture_output=True,
                         text=True, cwd=os.path.dirname(os.path.dirname(FAKE_WORKER)))
    assert out.returncode == 1
    assert "isn't a Hugging Face repo" in json.loads(out.stdout.splitlines()[-1])["message"]


def test_ltx_25_fetches_only_what_the_distilled_pipeline_reads():
    from comfier_agent.workers import hf_download

    files = hf_download.patterns_for("Lightricks/LTX-2.5")
    assert "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors" in files
    assert not any("dev" in f or "int8" in f or "loras/" in f for f in files)
    assert hf_download.patterns_for("prince-canuma/LTX-2.3-distilled") == hf_download.PATTERNS


def test_a_gated_repo_says_how_to_get_access():
    from comfier_agent.workers import hf_download

    class GatedRepoError(Exception):
        pass

    message = hf_download.failure_message("Lightricks/LTX-2.5", GatedRepoError("401 Client Error"))
    assert "accept its terms" in message and "hf auth login" in message
