"""Fixes from review: Windows without flock, disk checks for folders not made yet, the service commands,
and the mlx-video tool never outliving a job."""

import os
import sys

import pytest

from comfier_agent import cli, gpu_lock
from comfier_agent.config import AgentConfig
from comfier_agent.engines.base import JobContext
from comfier_agent.engines.mlx_video import MlxVideoEngine
from comfier_agent.resources import _paths_for_disk_check, nearest_existing

FAKE_VIDEO = os.path.join(os.path.dirname(__file__), "fake_mlx_video.py")


def test_without_flock_the_gpu_lock_is_off_rather_than_an_import_error(monkeypatch, tmp_path):
    monkeypatch.setattr(gpu_lock, "fcntl", None)
    lock = gpu_lock.GpuLock(str(tmp_path / "gpu.lock"))
    assert lock.enabled is False
    assert lock.acquire() is True and lock.held_elsewhere() is False


def test_disk_checks_count_folders_that_dont_exist_yet(tmp_path, monkeypatch):
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hf" / "hub"))
    paths = dict(_paths_for_disk_check(AgentConfig(work_dir=str(tmp_path / "comfier" / "work"))))
    assert str(tmp_path) in paths.values()
    assert nearest_existing(str(tmp_path / "a" / "b")) == str(tmp_path)


@pytest.fixture
def launchd(monkeypatch, tmp_path, comfier_home):
    calls = []
    loaded = {"value": True}
    plist = tmp_path / "com.comfier.agent.plist"
    plist.write_text("x")
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    monkeypatch.setattr(cli, "plist_path", lambda: plist)
    monkeypatch.setattr(cli, "service_loaded", lambda: loaded["value"])

    def launchctl(*args, check=False):
        calls.append(args)
        if args[0] == "bootout":
            loaded["value"] = False
        return cli.subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(cli, "launchctl", launchctl)
    return calls, loaded


def test_service_start_leaves_a_running_agent_alone(launchd, capsys):
    calls, _ = launchd
    assert cli.main(["service", "start"]) == 0
    assert calls == []
    assert "Already running" in capsys.readouterr().out


def test_service_restart_restarts_it(launchd):
    calls, _ = launchd
    cli.main(["service", "restart"])
    assert calls[0][:2] == ("kickstart", "-k")


def test_service_start_loads_a_stopped_agent(launchd):
    calls, loaded = launchd
    loaded["value"] = False
    cli.main(["service", "start"])
    assert calls[0][0] == "bootstrap"


def test_unloading_waits_for_launchd(monkeypatch):
    states = iter([True, True, True, False])
    monkeypatch.setattr(cli, "service_loaded", lambda: next(states))
    monkeypatch.setattr(cli, "launchctl", lambda *a, **k: None)
    monkeypatch.setattr(cli.time, "sleep", lambda _s: None)
    cli.unload_service()
    assert next(states, "done") == "done"


@pytest.mark.asyncio
async def test_a_failure_before_the_tool_runs_still_stops_it(comfier_home):
    engine = MlxVideoEngine(AgentConfig(work_dir=str(comfier_home / "work")), runner_argv=[sys.executable, FAKE_VIDEO])
    engine._refreshed_at = 1.0

    async def broken_progress(*_args, **_kwargs):
        raise RuntimeError("the frontend went away")

    with pytest.raises(RuntimeError):
        await engine.execute(JobContext(job_id="j_e", engine="mlx_video"),
                             {"command": "mlx_video.ltx_2.generate", "prompt": "hang"}, timeout_s=30,
                             progress=broken_progress)
    assert not engine.process.running
    assert engine._refreshed_at is None
