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
async def test_quantize_reaches_the_entry_point_rather_than_the_tool(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"))
    from comfier_agent.engines.base import JobContext

    async def progress(*_args, **_kw):
        pass

    files = await engine.execute(JobContext(job_id="j_q", engine="mlx_video"), {**RECIPE, "quantize": 8},
                                 timeout_s=30, progress=progress)
    written = open(files[0]["path"], "rb").read().decode(errors="replace")
    assert "--quantize" not in written
    assert "quantize=8" in written


@pytest.mark.asyncio
async def test_the_agents_own_environment_cant_quantize_a_full_precision_job(comfier_home, monkeypatch):
    from comfier_agent.engines.base import JobContext
    from comfier_agent.workers.entry_point import QUANTIZE_ENV

    monkeypatch.setenv(QUANTIZE_ENV, "8")
    engine = make_engine(work_dir=str(comfier_home / "work"))

    async def progress(*_args, **_kw):
        pass

    files = await engine.execute(JobContext(job_id="j_f", engine="mlx_video"), RECIPE, timeout_s=30, progress=progress)
    assert open(files[0]["path"], "rb").read().decode(errors="replace").endswith("quantize=")


@pytest.mark.parametrize("value,bits", [(8, "8"), (8.0, "8"), ("8", "8"), (None, ""), (False, ""), ("lots", "")])
def test_quantize_reaches_the_entry_point_as_whole_bits(value, bits):
    from comfier_agent.engines.mlx_video import quantize_bits

    assert quantize_bits(value) == bits


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
    monkeypatch.setitem(entry_point.FIXES, "mlx_video.", [lambda: applied.append("all")])
    monkeypatch.setitem(entry_point.FIXES, "mlx_video.ltx_2.", [lambda: applied.append("ltx")])
    monkeypatch.setattr(entry_point, "find", lambda command: lambda: ran.append(command))
    for command in ("mlx_video.ltx_2.generate", "mlx_video.wan_2.generate"):
        monkeypatch.setattr(sys, "argv", ["entry_point", command])
        with pytest.raises(SystemExit):
            entry_point.main()
    assert ran == ["mlx_video.ltx_2.generate", "mlx_video.wan_2.generate"]
    assert applied == ["all", "ltx", "all"]


def test_the_mask_fix_is_harmless_without_mlx_video():
    from comfier_agent.workers.entry_point import fix_ltx_text_encoder_mask

    fix_ltx_text_encoder_mask()  # mlx-video isn't installed here: nothing to patch, no error


def test_the_mask_fix_covers_both_gemma_encoders(monkeypatch):
    import types

    from comfier_agent.workers.entry_point import fix_ltx_text_encoder_mask

    class Gemma3:
        def _create_causal_mask_with_padding(self, seq_len, attention_mask, dtype):
            return "additive"

    class Gemma4:
        def _attention_mask(self, attention_mask, dtype):
            return "additive"

    mlx = types.ModuleType("mlx")
    mlx.core = types.ModuleType("mlx.core")
    text_encoder = types.ModuleType("mlx_video.models.ltx_2.text_encoder")
    text_encoder.LanguageModel, text_encoder.Gemma4LanguageModel = Gemma3, Gemma4
    ltx_2 = types.ModuleType("mlx_video.models.ltx_2")
    ltx_2.text_encoder = text_encoder
    for name, module in {"mlx": mlx, "mlx.core": mlx.core, "mlx_video": types.ModuleType("mlx_video"),
                         "mlx_video.models": types.ModuleType("mlx_video.models"), "mlx_video.models.ltx_2": ltx_2,
                         "mlx_video.models.ltx_2.text_encoder": text_encoder}.items():
        monkeypatch.setitem(sys.modules, name, module)

    fix_ltx_text_encoder_mask()
    assert Gemma3._create_causal_mask_with_padding.__name__ == "<lambda>"
    assert Gemma4._attention_mask.__name__ == "<lambda>"
    assert Gemma4()._attention_mask(None, "bfloat16") is None


def make_clip(path, faststart_flag):
    import subprocess
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "testsrc=size=64x48:rate=10:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    *(["-movflags", "+faststart"] if faststart_flag else []), str(path)], check=True)


def index_first(path):
    with open(path, "rb") as f:
        while header := f.read(8):
            size, kind = int.from_bytes(header[:4], "big"), header[4:]
            if kind in (b"moov", b"mdat"):
                return kind == b"moov"
            f.seek(size - 8, 1)
    return None


@pytest.mark.asyncio
@pytest.mark.skipif(not __import__("shutil").which("ffmpeg"), reason="ffmpeg required")
async def test_faststart_moves_the_index_ahead_of_the_media(tmp_path):
    from comfier_agent.engines.mlx_video import faststart
    clip = tmp_path / "clip.mp4"
    make_clip(clip, faststart_flag=False)
    assert index_first(clip) is False

    assert await faststart(clip) is True
    assert index_first(clip) is True
    assert not list(tmp_path.glob("*.faststart.*"))


@pytest.mark.asyncio
async def test_faststart_leaves_a_file_it_cannot_read(tmp_path):
    from comfier_agent.engines.mlx_video import faststart
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"not really a video")

    assert await faststart(clip) is False
    assert clip.read_bytes() == b"not really a video"
    assert not list(tmp_path.glob("*.faststart.*"))


def test_quantizing_is_harmless_without_mlx_video(monkeypatch):
    from comfier_agent.workers import entry_point

    monkeypatch.setenv(entry_point.QUANTIZE_ENV, "8")
    entry_point.quantize_ltx_weights()  # mlx-video isn't installed here: nothing to patch, no error
    entry_point.limit_mlx_cache()


def test_a_quantized_copy_is_named_for_its_checkpoint(monkeypatch, tmp_path):
    from comfier_agent.workers import entry_point

    monkeypatch.setenv(entry_point.QUANTIZED_DIR_ENV, str(tmp_path / "q"))
    source = tmp_path / "ltx-2.5-transformer-bf16.safetensors"
    source.write_bytes(b"x" * 10)
    os.utime(source, (1_000_000, 1_000_000))
    first = entry_point.quantized_copy_path(source, 8)

    assert first.parent == tmp_path / "q" and first.name.startswith("ltx-2.5-transformer-bf16.q8g64")
    assert entry_point.quantized_copy_path(source, 4) != first
    source.write_bytes(b"x" * 11)  # re-downloaded: a different file gets a fresh copy
    assert entry_point.quantized_copy_path(source, 8) != first
