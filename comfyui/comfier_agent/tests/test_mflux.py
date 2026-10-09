"""The mflux engine, against a fake worker that speaks the real worker's protocol."""

import os
import sys

import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.engines.base import JobError
from comfier_agent.engines.mflux import MfluxEngine
from comfier_agent.engines.mlx import recipe_argv

FAKE_WORKER = os.path.join(os.path.dirname(__file__), "fake_mflux_worker.py")
RECIPE = {"command": "mflux-generate-z-image-turbo", "model": "z-image-turbo", "quantize": 8, "steps": 4,
          "prompt": "a cat", "width": 512, "height": 512, "seed": 7, "min_memory_gb": 16}


def make_engine(**config):
    return MfluxEngine(AgentConfig(**config), worker_argv=[sys.executable, FAKE_WORKER])


@pytest.fixture
async def mflux_agent(agent, comfier_home):
    runtime = await agent.start()
    engine = make_engine(work_dir=str(comfier_home / "work"))
    runtime.jobs.engines["mflux"] = engine
    yield agent, runtime, engine
    await engine.close()


def mflux_assign(agent, job_id="j_1", **recipe):
    return agent.assign(job_id, engine="mflux", workflow={**RECIPE, **recipe}, inputs=[], requires={})


async def run(agent, job_id="j_1", **recipe):
    start = len(agent.front.messages)
    await agent.front.send(mflux_assign(agent, job_id, **recipe))
    return start


async def next_request(agent, runtime):
    await agent.front.wait_for(lambda: runtime.jobs.open_request_id is not None)


def test_recipe_options_become_flags():
    argv = recipe_argv({"command": "mflux-generate", "model": "dev", "image_strength": 0.4, "vae_tiling": True,
                        "low_ram": False, "image": ["/in.png", 0.6], "negative_prompt": None, "min_memory_gb": 24})
    assert argv == ["--model", "dev", "--image-strength", "0.4", "--vae-tiling", "--image", "/in.png", "0.6"]


@pytest.mark.parametrize("recipe, message", [
    ({"command": "mflux-generate", "output": "/etc/x"}, '"output" is set by the agent'),
    ({"command": "rm"}, "isn't a mflux command"),
    ({"command": "mflux-generate", "prompt": "{{prompt}}"}, "unreplaced placeholders"),
])
def test_bad_recipes_fail_validation(recipe, message):
    with pytest.raises(JobError, match=message):
        make_engine().validate(recipe)


@pytest.mark.asyncio
async def test_refresh_reads_version_and_downloaded_models():
    engine = make_engine()
    await engine.refresh()
    assert engine.info() == {"version": "9.9.9", "models": ["z-image-turbo"], "catalog": ["dev", "z-image-turbo"]}


@pytest.mark.asyncio
async def test_a_job_runs_reports_progress_and_uploads_the_image(mflux_agent):
    agent, runtime, engine = mflux_agent
    start = await run(agent)
    done = (await agent.front.wait_for_types("job.completed", timeout=10, after=start))[0]

    phases = [m["phase"] for m in agent.front.of_type("job.progress")]
    assert "loading_model" in phases and "running" in phases
    upload = agent.front.uploads[-1]
    assert upload["filename"] == "mflux_j_1.png"
    assert done["outputs"][0]["kind"] == "image"
    assert done["timings"]["execute_ms"] >= 0
    # The result was deleted after upload, and the job's folder with it.
    assert not os.path.exists(engine.job_path("j_1"))


@pytest.mark.asyncio
async def test_the_worker_and_its_model_stay_up_between_jobs(mflux_agent):
    agent, runtime, engine = mflux_agent
    await run(agent)
    await agent.front.wait_for_types("job.completed", timeout=10)
    pid = engine.worker.proc.pid

    await next_request(agent, runtime)
    start = await run(agent, "j_2")
    await agent.front.wait_for_types("job.completed", timeout=10, after=start)
    assert engine.worker.proc.pid == pid
    phases = [m["phase"] for m in agent.front.messages[start:] if m["type"] == "job.progress"]
    assert phases.count("loading_model") == 1  # sent before the worker says it's already loaded


@pytest.mark.asyncio
async def test_cancel_kills_the_worker_and_the_next_job_gets_a_new_one(mflux_agent):
    agent, runtime, engine = mflux_agent
    await run(agent, prompt="hang")
    await agent.front.wait_for(lambda: any(m.get("phase") == "running" for m in agent.front.of_type("job.progress")))
    pid = engine.worker.proc.pid

    await agent.front.send({"type": "job.cancel", "job_id": "j_1"})
    await agent.front.wait_for_types("job.cancelled", timeout=10)
    assert not engine.worker.running

    await next_request(agent, runtime)
    start = await run(agent, "j_2")
    await agent.front.wait_for_types("job.completed", timeout=10, after=start)
    assert engine.worker.proc.pid != pid


@pytest.mark.asyncio
async def test_an_mflux_error_fails_the_job_and_reads_as_out_of_memory(mflux_agent):
    agent, _runtime, _engine = mflux_agent
    await run(agent, prompt="boom")
    failed = (await agent.front.wait_for_types("job.failed", timeout=10))[0]
    assert failed["stage"] == "execute"
    assert "out of memory" in failed["error"]
    assert failed["exception_type"] == "RuntimeError"


@pytest.mark.asyncio
async def test_a_worker_crash_fails_the_job_with_what_it_printed(mflux_agent):
    agent, _runtime, engine = mflux_agent
    await run(agent, prompt="crash")
    failed = (await agent.front.wait_for_types("job.failed", timeout=10))[0]
    assert "mflux stopped unexpectedly" in failed["error"]
    assert "something awful" in failed["error"]


@pytest.mark.asyncio
async def test_a_comfyui_job_after_mflux_stops_the_worker(mflux_agent):
    agent, runtime, engine = mflux_agent
    await run(agent)
    await agent.front.wait_for_types("job.completed", timeout=10)
    assert engine.worker.running
    assert len(agent.comfy.frees) == 1

    await next_request(agent, runtime)
    prompt_id = await agent.run_to_execution("j_2")
    assert not engine.worker.running
    await agent.finish(prompt_id, {"out.png": b"PNG"})
    await agent.front.wait_for(lambda: len(agent.front.of_type("job.completed")) == 2, timeout=10)


@pytest.mark.asyncio
async def test_idle_worker_is_unloaded(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"), mlx_idle_unload_minutes=0.001)
    await engine._ensure_worker()
    engine._schedule_idle_unload()
    import asyncio

    for _ in range(50):
        if not engine.worker.running:
            break
        await asyncio.sleep(0.05)
    assert not engine.worker.running
