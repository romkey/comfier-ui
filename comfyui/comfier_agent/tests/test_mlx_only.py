"""A Mac running the agent with mflux and no ComfyUI at all."""

import os
import sys

import pytest

from comfier_agent.engines import mflux as mflux_engine
from comfier_agent.gpu_lock import GpuLock

FAKE_WORKER = os.path.join(os.path.dirname(__file__), "fake_mflux_worker.py")


@pytest.fixture
def fake_worker(monkeypatch):
    monkeypatch.setattr(mflux_engine, "default_worker_argv", lambda: [sys.executable, FAKE_WORKER])


@pytest.mark.asyncio
async def test_an_mflux_only_agent_connects_and_runs_jobs_without_comfyui(agent, fake_worker, comfier_home):
    await agent.comfy.stop()  # nothing listens where ComfyUI would be
    runtime = await agent.start(engines=["mflux"], work_dir=str(comfier_home / "work"))

    hello = agent.front.of_type("hello")[-1]
    assert hello["engines"]["mflux"]["version"] == "9.9.9"
    assert "comfyui" not in hello["engines"]
    inventory = agent.front.of_type("inventory")[-1]
    assert inventory["engines"]["mflux"]["models"] == ["z-image-turbo"]
    assert inventory["node_types"] == []
    status = agent.front.of_type("status")[-1]
    assert status["accepting"] is True and status["state"] == "idle"

    await agent.front.send(agent.assign("j_1", engine="mflux", inputs=[], requires={}, workflow={
        "command": "mflux-generate-z-image-turbo", "model": "z-image-turbo", "prompt": "a cat"}))
    done = (await agent.front.wait_for_types("job.completed", timeout=10))[0]
    assert done["outputs"][0]["filename"] == "mflux_j_1.png"
    await runtime.engines["mflux"].close()


@pytest.mark.asyncio
async def test_no_jobs_while_another_program_holds_the_gpu_lock(agent, fake_worker, comfier_home):
    other = GpuLock(str(comfier_home / "gpu.lock"))
    assert other.acquire()
    runtime = await agent.start(False, engines=["mflux"], gpu_lock_path=str(comfier_home / "gpu.lock"))
    await agent.front.wait_for(lambda: any(m["state"] == "busy_local" for m in agent.front.of_type("status")))
    status = agent.front.of_type("status")[-1]
    assert status["accepting"] is False
    assert "GPU lock" in status["accepting_reason"]
    assert agent.front.of_type("job.request") == []

    other.release()
    await runtime._publish_status(force=True)
    await agent.front.wait_for_types("job.request", timeout=5)
