"""The mlx-video engine, against a stand-in for its command-line tool."""

import os
import sys

import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.engines.mlx_video import MlxVideoEngine, denoising_fraction

FAKE = os.path.join(os.path.dirname(__file__), "fake_mlx_video.py")
RECIPE = {"command": "mlx_video.ltx_2.generate", "pipeline": "distilled",
          "model_repo": "prince-canuma/LTX-2.3-distilled", "prompt": "waves", "width": 768, "height": 512,
          "num_frames": 121, "fps": 24, "seed": 7, "min_memory_gb": 64}


def make_engine(**config):
    return MlxVideoEngine(AgentConfig(**config), runner_argv=[sys.executable, FAKE],
                          probe_argv=[sys.executable, FAKE, "--probe"])


@pytest.fixture
async def video_agent(agent, comfier_home):
    runtime = await agent.start()
    engine = make_engine(work_dir=str(comfier_home / "work"))
    runtime.jobs.engines["mlx_video"] = engine
    yield agent, runtime, engine
    await engine.close()


async def run(agent, job_id="j_1", **recipe):
    await agent.front.send(agent.assign(job_id, engine="mlx_video", workflow={**RECIPE, **recipe}, inputs=[],
                                        requires={}))


@pytest.mark.parametrize("line, fraction", [
    ("Denoising (distilled) ━━━━ 45% 4/9", 0.45),
    ("Sampling 3/8 [00:04<00:07]", 0.375),
    ("Downloading model.safetensors 45%", None),
    ("Loading model", None),
])
def test_progress_comes_from_the_denoising_bar(line, fraction):
    assert denoising_fraction(line) == fraction


@pytest.mark.asyncio
async def test_refresh_reports_version_and_cached_models():
    engine = make_engine()
    await engine.refresh()
    assert engine.info() == {"version": "0.1.0", "models": ["prince-canuma/LTX-2.3-distilled"]}


@pytest.mark.asyncio
async def test_a_video_job_runs_with_progress_and_uploads_the_mp4(video_agent):
    agent, _runtime, _engine = video_agent
    await run(agent)
    done = (await agent.front.wait_for_types("job.completed", timeout=10))[0]

    output = done["outputs"][0]
    assert output["filename"] == "mlx_video_j_1.mp4" and output["kind"] == "video"
    running = [m["progress"] for m in agent.front.of_type("job.progress") if m["phase"] == "running"]
    assert running and max(running) > 0.2
    phases = [m["phase"] for m in agent.front.of_type("job.progress")]
    assert phases.index("loading_model") < phases.index("running")


@pytest.mark.asyncio
async def test_recipe_flags_reach_the_tool_with_home_paths_expanded(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"))
    from comfier_agent.engines.base import JobContext

    async def progress(*_args, **_kw):
        pass

    files = await engine.execute(JobContext(job_id="j_x", engine="mlx_video"),
                                 {"command": "mlx_video.wan_2.generate", "model_dir": "~/models/wan", "prompt": "x"},
                                 timeout_s=30, progress=progress)
    written = open(files[0]["path"], "rb").read().decode(errors="replace")
    assert "mlx_video.wan_2.generate --model-dir " + os.path.expanduser("~/models/wan") in written
    assert "--output-path" in written


@pytest.mark.asyncio
async def test_a_failing_run_reports_what_the_tool_printed(video_agent):
    agent, _runtime, _engine = video_agent
    await run(agent, prompt="fail")
    failed = (await agent.front.wait_for_types("job.failed", timeout=10))[0]
    assert "exited with code 1" in failed["error"]
    assert "divisible by 64" in failed["error"]


@pytest.mark.asyncio
async def test_cancel_stops_the_tool(video_agent):
    agent, _runtime, engine = video_agent
    await run(agent, prompt="hang")
    await agent.front.wait_for(lambda: any(m.get("phase") == "running" for m in agent.front.of_type("job.progress")))
    await agent.front.send({"type": "job.cancel", "job_id": "j_1"})
    await agent.front.wait_for_types("job.cancelled", timeout=10)
    assert not engine.process.running


def test_ltx_commands_get_the_text_encoder_mask_fix(monkeypatch):
    from comfier_agent.workers import entry_point

    applied, ran = [], []
    monkeypatch.setitem(entry_point.FIXES, "mlx_video.ltx_2.", lambda: applied.append(True))
    monkeypatch.setattr(entry_point, "find", lambda command: lambda: ran.append(command))
    for command in ("mlx_video.ltx_2.generate", "mlx_video.wan_2.generate"):
        monkeypatch.setattr(sys, "argv", ["entry_point", command])
        with pytest.raises(SystemExit):
            entry_point.main()
    assert ran == ["mlx_video.ltx_2.generate", "mlx_video.wan_2.generate"]
    assert applied == [True]


def test_the_mask_fix_is_harmless_without_mlx_video():
    from comfier_agent.workers.entry_point import fix_ltx_text_encoder_mask

    fix_ltx_text_encoder_mask()  # mlx-video isn't installed here: nothing to patch, no error
