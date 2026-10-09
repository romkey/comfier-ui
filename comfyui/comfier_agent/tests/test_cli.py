"""comfier-agent's commands."""

import argparse
import io
import json
import plistlib
import subprocess
import sys

import pytest

from comfier_agent import cli
from comfier_agent.gpu_lock import GpuLock
from comfier_agent.workers.mflux_worker import pull_command, reference_flag


def test_no_subcommand_still_runs_the_agent(monkeypatch):
    seen = {}
    monkeypatch.setattr(cli, "cmd_run", lambda args: seen.update(url=args.comfyui_url))
    assert cli.main(["--comfyui-url", "http://127.0.0.1:8188"]) == 0
    assert seen["url"] == "http://127.0.0.1:8188"


def test_setup_without_questions_saves_the_settings(comfier_home, monkeypatch):
    monkeypatch.setattr(cli, "check_comfier", lambda url: (True, "ok"))
    monkeypatch.setattr(cli, "check_key", lambda url, key: (True, "ok"))
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
    ("qwen-image", "mflux-generate-qwen"), ("qwen-image-edit", "mflux-generate-qwen-edit"),
    ("qwen-image-edit-2511", "mflux-generate-qwen-edit"), ("qwen-image-2.1", "mflux-generate-qwen-2.1"),
    ("dev-kontext", "mflux-generate-kontext"), ("fibo-edit", "mflux-generate-fibo-edit"),
    ("dev", "mflux-generate"), ("schnell", "mflux-generate"),
])
def test_pull_picks_the_command_for_a_model(model, command):
    assert pull_command(model) == command


def parser_with(*options, require_init_image=False):
    parser = argparse.ArgumentParser()
    for option in options:
        parser.add_argument(option)
    parser.require_init_image = require_init_image
    return parser


@pytest.mark.parametrize("parser, command, flag", [
    (parser_with("--image-paths"), "mflux-generate-qwen-edit", "--image-paths"),
    (parser_with("--image-paths"), "my-custom-edit", "--image-paths"),
    (parser_with("--image-path", require_init_image=True), "mflux-generate-kontext", "--image-path"),
    (parser_with("--image-path"), "mflux-generate-fibo-edit", "--image-path"),
    (parser_with("--image-path"), "mflux-generate", None),
    (parser_with("--prompt"), "mflux-generate-lens", None),
])
def test_pull_reads_the_reference_image_flag_from_the_command(parser, command, flag):
    assert reference_flag(parser, command) == flag


def test_the_module_runs_the_cli():
    out = subprocess.run([sys.executable, "-m", "comfier_agent", "version"], capture_output=True, text=True,
                         cwd=str(cli.Path(cli.__file__).resolve().parents[1]), check=True)
    assert out.stdout.strip() == cli.__version__


def test_pull_holds_the_gpu_lock(comfier_home, monkeypatch):
    import comfier_agent.engines as engines

    seen = {}
    monkeypatch.setattr(engines, "installed", lambda pkg: True)

    def call(cmd):
        seen["cmd"] = cmd
        seen["held"] = GpuLock(str(comfier_home / "gpu.lock")).held_elsewhere()
        return 0

    monkeypatch.setattr(cli.subprocess, "call", call)
    assert cli.main(["pull", "z-image-turbo"]) == 0
    assert seen["cmd"][-2:] == ["--pull", "z-image-turbo"]
    assert seen["held"] is True
    assert not GpuLock(str(comfier_home / "gpu.lock")).held_elsewhere()


@pytest.mark.parametrize("saved, detected, default", [
    ({"engines": ["comfyui", "mflux"], "comfyui_url": "http://studio:8190"}, ["mflux"], "http://studio:8190"),
    ({"engines": ["comfyui"]}, ["mflux"], "http://127.0.0.1:8188"),
    ({"engines": ["mflux"], "comfyui_url": "http://studio:8190"}, ["mflux"], "none"),
    ({}, ["mflux"], "none"),
    ({}, [], "http://127.0.0.1:8188"),
])
def test_setup_offers_the_comfyui_url_it_saved_before(saved, detected, default):
    assert cli.comfyui_default(saved, detected) == default


def test_setup_again_keeps_comfyui_and_the_key(comfier_home, monkeypatch):
    monkeypatch.setattr(cli, "check_comfier", lambda url: (True, "ok"))
    monkeypatch.setattr(cli, "check_key", lambda url, key: (True, "ok"))
    cli.main(["setup", "-y", "--url", "https://c.example", "--key", "cmf_first",
              "--comfyui-url", "http://studio:8190", "--engines", "comfyui,mflux"])
    assert cli.main(["setup", "-y", "--url", "https://c.example"]) == 0
    saved = json.loads((comfier_home / "agent.json").read_text())
    assert saved["api_key"] == "cmf_first"
    assert saved["comfyui_url"] == "http://studio:8190"
    assert "comfyui" in saved["engines"]


def test_setup_refuses_something_that_isnt_a_key(comfier_home):
    assert cli.main(["setup", "-y", "--url", "https://c.example", "--key", "abc123"]) == 2


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def test_check_key_reports_the_server_it_belongs_to(monkeypatch):
    seen = {}

    def urlopen(request, timeout):
        seen["auth"] = request.headers["Authorization"]
        return FakeResponse(b'{"server": "Mac Studio", "key": "cmf_abcd1234\\u2026"}')

    monkeypatch.setattr(cli.urllib.request, "urlopen", urlopen)
    ok, detail = cli.check_key("https://c.example", "cmf_abcd1234secret")
    assert ok is True and "Mac Studio" in detail and "cmf_abcd1234…" in detail
    assert seen["auth"] == "Bearer cmf_abcd1234secret"


@pytest.mark.parametrize("code, body, ok, text", [
    (401, b'{"error": "This key was revoked."}', False, "revoked"),
    (404, b"Not Found", None, "older than the agent"),
])
def test_check_key_explains_a_refusal(monkeypatch, code, body, ok, text):
    def urlopen(request, timeout):
        raise cli.urllib.error.HTTPError(request.full_url, code, "x", {}, io.BytesIO(body))

    monkeypatch.setattr(cli.urllib.request, "urlopen", urlopen)
    result, detail = cli.check_key("https://c.example", "cmf_abcd1234secret")
    assert result is ok and text in detail
    if ok is False:
        assert "cmf_abcd1234…" in detail and "secret" not in detail
