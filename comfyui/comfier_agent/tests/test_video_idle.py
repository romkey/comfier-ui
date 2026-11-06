"""Persistent model reuse, independent timers and memory handoff regressions."""
import asyncio
import io
import json
import sys
import types
from pathlib import Path

import pytest

from comfier_agent.config import AgentConfig, load_config
from comfier_agent.engines.base import JobContext, JobError
from comfier_agent.workers.video_worker import Worker
from tests.test_mlx_video import RECIPE, make_engine


async def ignore_progress(*args, **kwargs):
    pass


async def execute(engine, job_id="warm", **recipe):
    return await engine.execute(JobContext(job_id=job_id, engine="mlx_video"), {**RECIPE, **recipe},
                                timeout_s=5, progress=ignore_progress)


@pytest.mark.asyncio
async def test_video_worker_survives_jobs_and_restarts_for_changed_weights(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"))
    try:
        await execute(engine)
        pid = engine.worker.proc.pid
        await execute(engine, "next", prompt="different prompt", seed=42)
        assert engine.worker.running and engine.worker.proc.pid == pid
        await execute(engine, "new_model", model_repo="other/model")
        assert engine.worker.proc.pid != pid
    finally:
        await engine.close()


@pytest.mark.asyncio
async def test_video_idle_timer_resets_on_a_new_job(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"), mlx_video_idle_unload_minutes=0.004)
    try:
        await execute(engine)
        pid = engine.worker.proc.pid
        await asyncio.sleep(0.12)
        await execute(engine, "next")  # fake generation takes longer than the idle timeout
        assert engine.worker.running and engine.worker.proc.pid == pid
        await asyncio.sleep(0.35)
        assert not engine.worker.running
    finally:
        await engine.close()


@pytest.mark.asyncio
async def test_video_zero_disables_idle_timer_independently_of_mflux(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"), mlx_video_idle_unload_minutes=0,
                         mlx_idle_unload_minutes=0.0001)
    try:
        await execute(engine)
        assert engine._idle_task is None
        await asyncio.sleep(0.1)
        assert engine.worker.running
    finally:
        await engine.close()


@pytest.mark.asyncio
async def test_unload_already_in_progress_finishes_before_next_job(comfier_home, monkeypatch):
    engine = make_engine(work_dir=str(comfier_home / "work"), mlx_video_idle_unload_minutes=10)
    started, release = asyncio.Event(), asyncio.Event()
    original = engine.worker.stop

    async def delayed_stop():
        started.set()
        await release.wait()
        await original()

    try:
        await execute(engine)
        pid = engine.worker.proc.pid
        monkeypatch.setattr(engine.worker, "stop", delayed_stop)
        engine.config.mlx_video_idle_unload_minutes = 0.0001
        engine._schedule_idle_unload()
        await asyncio.wait_for(started.wait(), 3)
        next_job = asyncio.create_task(execute(engine, "next"))
        await asyncio.sleep(0.05)
        assert not next_job.done()
        release.set()
        await next_job
        assert engine.worker.proc.pid != pid
    finally:
        release.set()
        await engine.close()


@pytest.mark.asyncio
async def test_video_is_unloaded_before_mflux_runs(agent, comfier_home):
    from tests.test_mflux import make_engine as image_engine

    runtime = await agent.start()
    video = make_engine(work_dir=str(comfier_home / "work"))
    image = image_engine(work_dir=str(comfier_home / "work"))
    runtime.jobs.engines.update(mlx_video=video, mflux=image)
    try:
        await execute(video)
        runtime.jobs.warm_engine = "mlx_video"
        await runtime.jobs._make_room_for("mflux")
        assert not video.worker.running
        assert video._idle_task is None
        # The reverse switch must free mflux as well.
        await image._ensure_worker()
        await runtime.jobs._make_room_for("mlx_video")
        assert not image.worker.running
    finally:
        await video.close()
        await image.close()


@pytest.mark.asyncio
async def test_timeout_kills_video_worker(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"))
    try:
        with pytest.raises(JobError, match="timeout"):
            await engine.execute(JobContext(job_id="slow", engine="mlx_video"), {**RECIPE, "prompt": "hang"},
                                 timeout_s=0.05, progress=ignore_progress)
        assert not engine.worker.running
    finally:
        await engine.close()


def test_video_timeout_setting_loads_from_json_and_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("COMFIER_HOME", str(tmp_path))
    assert AgentConfig().mlx_video_idle_unload_minutes == 10
    (tmp_path / "agent.json").write_text(json.dumps({"mlx_video_idle_unload_minutes": 3,
                                                   "mlx_idle_unload_minutes": 7}))
    config = load_config(sidecar=True)
    assert config.mlx_video_idle_unload_minutes == 3 and config.mlx_idle_unload_minutes == 7
    monkeypatch.setenv("COMFIER_MLX_VIDEO_IDLE_UNLOAD_MINUTES", "2.5")
    config = load_config(sidecar=True)
    assert config.mlx_video_idle_unload_minutes == 2.5 and config.mlx_idle_unload_minutes == 7


def test_worker_reuses_wan_models_but_regenerates_prompt_outputs(monkeypatch, tmp_path):
    from comfier_agent.workers import entry_point

    module = types.ModuleType("fake_wan_cli")
    loads = []

    def loader(path, config=None):
        model = object()
        loads.append((path, model))
        return model

    for name in ("load_t5_encoder", "load_wan_model", "load_vae_encoder", "load_vae_decoder"):
        setattr(module, name, loader)

    def main():
        args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
        for name in ("load_t5_encoder", "load_wan_model", "load_vae_encoder", "load_vae_decoder"):
            getattr(module, name)("weights")
        Path(args["--output-path"]).write_text(args["--prompt"])

    main.__module__ = module.__name__
    monkeypatch.setitem(sys.modules, module.__name__, module)
    monkeypatch.setattr(entry_point, "find", lambda _: main)
    monkeypatch.setattr(entry_point, "FIXES", {})
    monkeypatch.setattr(entry_point, "wan_model_dir", lambda args: args)
    worker = Worker(io.StringIO())
    for prompt in ("waves", "mountains"):
        worker.generate({"id": prompt, "command": "mlx_video.wan_2.generate", "argv": ["--prompt", prompt],
                         "output": str(tmp_path / prompt)})
    assert len(loads) == 4
    assert (tmp_path / "waves").read_text() == "waves"
    assert (tmp_path / "mountains").read_text() == "mountains"
    assert module.load_wan_model is loader  # wrappers restored after every invocation


@pytest.mark.parametrize("pipeline,transformer_loads", [("distilled", 1), ("dev", 1), ("dev-two-stage", 2)])
def test_ltx_reuses_weights_without_reapplying_lora_to_cached_transformer(
        monkeypatch, tmp_path, pipeline, transformer_loads):
    from comfier_agent.workers import entry_point

    module = types.ModuleType("fake_ltx_cli")
    text = types.ModuleType("mlx_video.models.ltx_2.text_encoder")
    loads = []

    def loader(name):
        def load(path="weights", strict=True):
            loads.append(name)
            return {"merges": 0}
        return load

    for name in ("LTXModel", "VideoEncoder", "VideoDecoder"):
        setattr(module, name, type(name, (), {"from_pretrained": staticmethod(loader(name))}))
    class TextEncoder:
        def load(self, path):
            loads.append("TextEncoder")

        def __call__(self, prompt):
            return "encoded " + prompt

    text.LTX2TextEncoder = TextEncoder
    for name in ("load_upsampler", "load_audio_decoder", "load_vocoder_model"):
        setattr(module, name, loader(name))

    def main():
        args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
        encoder = text.LTX2TextEncoder()
        encoder.load("weights")
        assert encoder(args["--prompt"]) == "encoded " + args["--prompt"]
        transformer = module.LTXModel.from_pretrained("weights")
        for name in ("VideoEncoder", "VideoDecoder"):
            getattr(module, name).from_pretrained("weights")
        for name in ("load_upsampler", "load_audio_decoder", "load_vocoder_model"):
            getattr(module, name)("weights")
        if pipeline == "dev-two-stage":
            transformer["merges"] += 1
        Path(args["--output-path"]).write_text(str(transformer["merges"]))

    main.__module__ = module.__name__
    monkeypatch.setitem(sys.modules, module.__name__, module)
    monkeypatch.setitem(sys.modules, text.__name__, text)
    monkeypatch.setattr(entry_point, "find", lambda _: main)
    fixes = []
    monkeypatch.setattr(entry_point, "FIXES", {"mlx_video.": [lambda: fixes.append(True)]})
    worker = Worker(io.StringIO())
    for job in ("first", "second"):
        worker.generate({"id": job, "command": "mlx_video.ltx_2.generate",
                         "argv": ["--prompt", job, "--pipeline", pipeline], "output": str(tmp_path / job)})
    assert loads.count("LTXModel") == transformer_loads
    assert loads.count("TextEncoder") == 1
    assert loads.count("VideoDecoder") == 1
    assert len(fixes) == 1
    expected = "1" if pipeline == "dev-two-stage" else "0"
    assert (tmp_path / "first").read_text() == (tmp_path / "second").read_text() == expected


@pytest.mark.asyncio
async def test_video_error_releases_models_and_next_job_starts_cleanly(comfier_home):
    engine = make_engine(work_dir=str(comfier_home / "work"))
    try:
        await execute(engine)
        pid = engine.worker.proc.pid
        with pytest.raises(JobError, match="divisible by 64"):
            await execute(engine, "failed", prompt="fail")
        assert not engine.worker.running
        await execute(engine, "recovered")
        assert engine.worker.proc.pid != pid
    finally:
        await engine.close()
