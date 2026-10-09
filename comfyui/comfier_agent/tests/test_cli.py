"""comfier-agent's commands."""

import json
import plistlib
import subprocess
import sys

import pytest

from comfier_agent import cli
from comfier_agent.gpu_lock import GpuLock
from comfier_agent.workers.mflux_worker import PULL_COMMANDS


def test_no_subcommand_still_runs_the_agent(monkeypatch):
    seen = {}
    monkeypatch.setattr(cli, "cmd_run", lambda args: seen.update(url=args.comfyui_url))
    assert cli.main(["--comfyui-url", "http://127.0.0.1:8188"]) == 0
    assert seen["url"] == "http://127.0.0.1:8188"


def test_setup_without_questions_saves_the_settings(comfier_home, monkeypatch):
    monkeypatch.setattr(cli, "check_comfier", lambda url: (True, "ok"))
    code = cli.main(["setup", "-y", "--url", "https://comfier.example/", "--key", "cmf_secret",
                     "--name", "studio", "--comfyui-url", "none", "--engines", "mflux"])
    assert code == 0
    saved = json.loads((comfier_home / "agent.json").read_text())
    assert saved == {"api_key": "cmf_secret", "backend_name": "studio", "engines": ["mflux"],
                     "frontend_url": "https://comfier.example"}
    assert (comfier_home / "agent.json").stat().st_mode & 0o777 == 0o600


def test_setup_needs_a_url_and_key(comfier_home):
    assert cli.main(["setup", "-y", "--engines", "mflux"]) == 2


def test_the_service_runs_this_python_and_logs_to_library_logs(comfier_home):
    plist = cli.service_plist()
    assert plist["Label"] == "com.comfier.agent"
    assert plist["ProgramArguments"] == [sys.executable, "-m", "comfier_agent", "run"]
    assert plist["KeepAlive"] is True and plist["RunAtLoad"] is True
    assert plist["StandardOutPath"].endswith("Library/Logs/comfier-agent.log")
    assert plist["EnvironmentVariables"]["COMFIER_HOME"] == str(comfier_home)
    plistlib.dumps(plist)  # writable as a plist


def test_lock_holds_the_gpu_lock_while_the_command_runs(comfier_home):
    lock_path = comfier_home / "gpu.lock"
    probe = (
        "import sys; sys.path.insert(0, %r);"
        "from comfier_agent.gpu_lock import GpuLock;"
        "sys.exit(0 if GpuLock(%r).held_elsewhere() else 1)"
    ) % (str(cli.Path(cli.__file__).resolve().parents[1]), str(lock_path))
    assert cli.main(["lock", "--", sys.executable, "-c", probe]) == 0
    assert not GpuLock(str(lock_path)).held_elsewhere()


def test_lock_needs_a_command():
    assert cli.main(["lock"]) == 2


def test_doctor_reports_without_crashing(comfier_home, capsys):
    code = cli.main(["doctor"])
    out = capsys.readouterr().out
    assert "comfier-agent" in out and "Settings in" in out
    assert code == 1  # no URL or key in a fresh home


@pytest.mark.parametrize("model, command", [
    ("z-image-turbo", "mflux-generate-z-image-turbo"), ("flux2-klein-4b", "mflux-generate-flux2"),
    ("qwen-image", "mflux-generate-qwen"), ("dev", "mflux-generate"), ("schnell", "mflux-generate"),
])
def test_pull_picks_the_command_for_a_model(model, command):
    assert next(cmd for prefix, cmd in PULL_COMMANDS if model.startswith(prefix)) == command


def test_the_module_runs_the_cli():
    out = subprocess.run([sys.executable, "-m", "comfier_agent", "version"], capture_output=True, text=True,
                         cwd=str(cli.Path(cli.__file__).resolve().parents[1]), check=True)
    assert out.stdout.strip() == cli.__version__
