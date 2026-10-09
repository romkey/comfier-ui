"""The job slot is shared by every engine, and engines hand the memory to each other."""

import os

import pytest

from comfier_agent.engines.base import Engine, JobCancelled


class FakeEngine(Engine):
    """Writes one PNG per job; `block` makes execute wait until cancelled."""

    name = "fake"

    def __init__(self, tmp_path, *, block=False):
        self.tmp_path = tmp_path
        self.block = block
        self.staged: list[str] = []
        self.ran: list[dict] = []
        self.freed = 0
        self.cancelled = False

    def validate(self, workflow):
        if not isinstance(workflow, dict) or "prompt" not in workflow:
            raise ValueError("recipe needs a prompt")

    async def stage_input(self, ctx, path, filename):
        dest = self.tmp_path / filename
        os.replace(path, dest)
        self.staged.append(str(dest))
        return str(dest)

    async def execute(self, ctx, workflow, *, timeout_s, progress):
        import asyncio

        self.ran.append(workflow)
        await progress(ctx, "running", 0.5)
        while self.block:
            if ctx.cancel_requested:
                raise JobCancelled()
            await asyncio.sleep(0.02)
        out = self.tmp_path / f"{ctx.job_id}.png"
        out.write_bytes(b"\x89PNG fake")
        return [{"node": "fake", "filename": out.name, "path": str(out)}]

    async def fetch_output(self, fdesc):
        return fdesc["path"]

    async def free_memory(self):
        self.freed += 1


def recipe_assign(agent, job_id="j_1", **extra):
    msg = agent.assign(job_id, engine="fake", workflow={"prompt": "a cat", "image": "comfier-input://in_0"},
                       requires={})
    msg.update(extra)
    return msg


@pytest.mark.asyncio
async def test_unknown_engine_is_rejected(agent):
    await agent.start()
    await agent.front.send(agent.assign("j_1", engine="nope"))
    rejected = (await agent.front.wait_for_types("job.rejected", timeout=5))[0]
    assert rejected["reason"] == "missing_engine"
    assert "nope" in rejected["detail"]


@pytest.mark.asyncio
async def test_job_runs_on_the_engine_it_names(agent, tmp_path):
    runtime = await agent.start()
    fake = FakeEngine(tmp_path)
    runtime.jobs.engines["fake"] = fake

    await agent.front.send(recipe_assign(agent))
    done = (await agent.front.wait_for_types("job.completed", timeout=8))[0]

    assert done["outputs"][0]["filename"] == "j_1.png"
    assert agent.front.uploads[-1]["filename"] == "j_1.png"
    # The input was handed to the engine as a local path, not uploaded to ComfyUI.
    assert fake.ran[0]["image"] == fake.staged[0]
    assert agent.comfy.uploads == []
    assert not os.path.exists(tmp_path / "j_1.png")


@pytest.mark.asyncio
async def test_switching_engines_frees_the_other_engines_memory(agent, tmp_path):
    runtime = await agent.start()
    fake = FakeEngine(tmp_path)
    runtime.jobs.engines["fake"] = fake

    await agent.front.send(recipe_assign(agent))
    await agent.front.wait_for_types("job.completed", timeout=8)
    # Nothing was known to be warm, so ComfyUI is asked to let go before the first MLX job...
    assert agent.comfy.frees == [{"unload_models": True, "free_memory": True}]

    await agent.front.wait_for(lambda: runtime.jobs.open_request_id is not None)
    await agent.front.send(recipe_assign(agent, "j_2"))
    await agent.front.wait_for(lambda: len(agent.front.of_type("job.completed")) == 2, timeout=8)
    # ...but not again while the same engine stays warm.
    assert len(agent.comfy.frees) == 1
    assert fake.freed == 0

    await agent.front.wait_for(lambda: runtime.jobs.open_request_id is not None)
    prompt_id = await agent.run_to_execution("j_3")
    await agent.finish(prompt_id, {"out.png": b"PNG"})
    await agent.front.wait_for(lambda: len(agent.front.of_type("job.completed")) == 3, timeout=8)
    assert fake.freed == 1


@pytest.mark.asyncio
async def test_one_job_at_a_time_across_engines(agent, tmp_path):
    runtime = await agent.start()
    fake = FakeEngine(tmp_path, block=True)
    runtime.jobs.engines["fake"] = fake

    await agent.front.send(recipe_assign(agent))
    await agent.front.wait_for_types("job.accepted", timeout=5)
    # A ComfyUI job assigned while the MLX job runs is turned away.
    await agent.front.send(agent.assign("j_2"))
    rejected = (await agent.front.wait_for_types("job.rejected", timeout=5))[0]
    assert rejected["job_id"] == "j_2" and rejected["reason"] == "busy"

    await agent.front.send({"type": "job.cancel", "job_id": "j_1"})
    await agent.front.wait_for_types("job.cancelled", timeout=5)
    assert runtime.jobs.active is None


@pytest.mark.asyncio
async def test_bad_recipe_fails_validation(agent, tmp_path):
    runtime = await agent.start()
    runtime.jobs.engines["fake"] = FakeEngine(tmp_path)
    await agent.front.send(agent.assign("j_1", engine="fake", workflow={"steps": 4}, requires={}))
    failed = (await agent.front.wait_for_types("job.failed", timeout=5))[0]
    assert "prompt" in failed["error"]
