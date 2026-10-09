"""A standalone agent connects whether or not ComfyUI is up, and follows it going and coming back."""

import os
import sys
from urllib.parse import urlparse

import pytest

from comfier_agent import runtime as runtime_module
from comfier_agent.engines import mflux as mflux_engine

FAKE_WORKER = os.path.join(os.path.dirname(__file__), "fake_mflux_worker.py")


@pytest.fixture
def quick_checks(monkeypatch):
    monkeypatch.setattr(runtime_module, "COMFY_RETRY_S", 0.1)
    monkeypatch.setattr(runtime_module, "COMFY_CHECK_S", 0.1)
    monkeypatch.setattr(mflux_engine, "default_worker_argv", lambda: [sys.executable, FAKE_WORKER])


@pytest.mark.asyncio
async def test_connects_without_comfyui_and_picks_it_up_when_it_starts(agent, quick_checks, comfier_home):
    port = urlparse(agent.comfy.base_url).port
    await agent.comfy.stop()
    runtime = await agent.start(engines=["comfyui", "mflux"], work_dir=str(comfier_home / "work"))

    assert set(agent.front.of_type("hello")[-1]["engines"]) == {"mflux"}
    assert set(agent.front.of_type("inventory")[-1]["engines"]) == {"mflux"}
    assert agent.front.of_type("status")[-1]["accepting"] is True

    # A ComfyUI job that arrives anyway is turned away; mflux jobs still run.
    await agent.front.send(agent.assign("j_1"))
    rejected = (await agent.front.wait_for_types("job.rejected", timeout=5))[0]
    assert rejected["reason"] == "missing_engine" and "isn't reachable" in rejected["detail"]

    await agent.comfy.start(port)
    await agent.front.wait_for(lambda: "comfyui" in agent.front.of_type("inventory")[-1]["engines"], timeout=5)
    assert runtime.comfy_ready
    await runtime.engines["mflux"].close()


@pytest.mark.asyncio
async def test_comfyui_going_away_takes_it_out_of_the_engines(agent, quick_checks, comfier_home):
    runtime = await agent.start(engines=["comfyui", "mflux"], work_dir=str(comfier_home / "work"))
    assert "comfyui" in agent.front.of_type("inventory")[-1]["engines"]

    models = agent.front.of_type("inventory")[-1]["models"]
    await agent.comfy.stop()
    await agent.front.wait_for(lambda: "comfyui" not in agent.front.of_type("inventory")[-1]["engines"], timeout=5)
    assert agent.front.of_type("status")[-1]["accepting"] is True
    # An outage doesn't wipe ComfyUI's models from Comfier; only the engine goes.
    assert agent.front.of_type("inventory")[-1]["models"] == models != {}
    await runtime.engines["mflux"].close()


@pytest.mark.asyncio
async def test_a_comfyui_only_agent_still_connects_and_says_why_it_cant_work(agent, quick_checks):
    await agent.comfy.stop()
    await agent.start(False)

    status = (await agent.front.wait_for_types("status", timeout=5))[0]
    assert agent.front.of_type("hello")
    assert status["accepting"] is False and status["state"] == "error"
    assert "ComfyUI is unreachable" in status["accepting_reason"]
    # An empty map, so Comfier stops routing ComfyUI jobs here.
    assert agent.front.of_type("inventory")[-1]["engines"] == {}

    # A ComfyUI job that arrives anyway is sent elsewhere, not back here as "busy".
    assert agent.front.of_type("job.request") == []
    await agent.front.send(_assign_without_request(agent))
    rejected = (await agent.front.wait_for_types("job.rejected", timeout=5))[0]
    assert rejected["reason"] == "missing_engine"


def _assign_without_request(agent):
    base = agent.front.base_url
    return {"type": "job.assign", "request_id": "r_none", "job_id": "j_1",
            "workflow": {"3": {"class_type": "LoadImage", "inputs": {}}}, "inputs": [],
            "upload_url": f"{base}/api/agent/jobs/j_1/outputs", "requires": {}}
