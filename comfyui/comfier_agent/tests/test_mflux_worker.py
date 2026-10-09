"""The real mflux worker's logic, with a stand-in for an mflux command module."""

import argparse
import io
import json
import sys
import types

import pytest

from comfier_agent.workers import mflux_worker


class FakeImage:
    def __init__(self, text):
        self.text = text

    def save(self, path, export_json_metadata=False):
        with open(path, "w") as f:
            f.write(self.text)


class FakeModel:
    def __init__(self, name):
        self.name = name
        self.callbacks = types.SimpleNamespace(registered=[], register=lambda cb: self.callbacks.registered.append(cb))


class FakeCommand:
    loads = []

    @staticmethod
    def load(args):
        FakeCommand.loads.append(args.model)
        return FakeModel(args.model)

    @staticmethod
    def generate(model, args, seed, prompt):
        if prompt == "explode":
            raise RuntimeError("[metal] out of memory")
        for cb in model.callbacks.registered:
            for t in range(args.steps):
                cb.call_in_loop(t, seed, prompt, None, types.SimpleNamespace(num_inference_steps=args.steps), None)
        return FakeImage(f"{model.name}|{seed}|{prompt}")


def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model")
    parser.add_argument("--prompt")
    parser.add_argument("--steps", type=int, default=2)
    parser.add_argument("--seed", type=int, nargs="+")
    parser.add_argument("--quantize", type=int)
    parser.add_argument("--output")
    return parser


@pytest.fixture
def worker(monkeypatch):
    FakeCommand.loads = []
    module = types.ModuleType("fake_mflux_cli")
    module.build_parser = build_parser
    module.FakeCommand = FakeCommand
    monkeypatch.setattr(mflux_worker, "command_module", lambda command: module)
    monkeypatch.setattr(mflux_worker, "clear_mlx_cache", lambda: None)
    prompt_util = types.ModuleType("mflux.utils.prompt_util")
    prompt_util.PromptUtil = types.SimpleNamespace(read_prompt=lambda args: args.prompt)
    for name, mod in {"mflux": types.ModuleType("mflux"), "mflux.utils": types.ModuleType("mflux.utils"),
                      "mflux.utils.prompt_util": prompt_util}.items():
        monkeypatch.setitem(sys.modules, name, mod)
    out = io.StringIO()
    return mflux_worker.Worker(out), out, module


def events(out):
    return [json.loads(line) for line in out.getvalue().splitlines()]


def request(tmp_path, job_id="j_1", model="z-image-turbo", prompt="a cat", seed=7):
    return {"op": "generate", "id": job_id, "command": "mflux-generate-z-image-turbo",
            "argv": ["--model", model, "--prompt", prompt, "--seed", str(seed), "--steps", "2"],
            "output": str(tmp_path / f"{job_id}.png")}


def test_generates_with_progress_and_keeps_the_model_loaded(worker, tmp_path):
    w, out, _ = worker
    w.generate_safely(request(tmp_path))
    w.generate_safely(request(tmp_path, "j_2", prompt="a dog"))

    assert FakeCommand.loads == ["z-image-turbo"]
    assert (tmp_path / "j_2.png").read_text() == "z-image-turbo|7|a dog"
    kinds = [e["event"] for e in events(out)]
    assert kinds == ["loading", "loaded", "progress", "progress", "done", "loaded", "progress", "progress", "done"]
    assert events(out)[3] == {"event": "progress", "id": "j_1", "step": 2, "total": 2}


def test_a_different_model_is_loaded_in_place_of_the_old_one(worker, tmp_path):
    w, _, _ = worker
    w.generate_safely(request(tmp_path))
    w.generate_safely(request(tmp_path, "j_2", model="dev"))
    assert FakeCommand.loads == ["z-image-turbo", "dev"]
    assert w.model.name == "dev"


def test_options_mflux_rejects_are_reported(worker, tmp_path):
    w, out, _ = worker
    bad = request(tmp_path)
    bad["argv"] += ["--no-such-flag"]
    w.generate_safely(bad)
    error = events(out)[-1]
    assert error["event"] == "error" and error["type"] == "InvalidOptions"


def test_a_failure_unloads_the_model_and_reports_the_traceback(worker, tmp_path):
    w, out, _ = worker
    w.generate_safely(request(tmp_path, prompt="explode"))
    error = events(out)[-1]
    assert error["type"] == "RuntimeError" and "out of memory" in error["message"]
    assert "Traceback" in error["traceback"]
    assert w.model is None


def test_a_command_without_a_load_class_runs_its_main(worker, tmp_path):
    w, out, module = worker
    del module.FakeCommand
    seen = {}

    def main():
        seen["argv"] = list(sys.argv)
        with open(sys.argv[sys.argv.index("--output") + 1], "w") as f:
            f.write("png")

    module.main = main
    w.generate_safely(request(tmp_path))
    assert seen["argv"][0] == "mflux-generate-z-image-turbo"
    assert [e["event"] for e in events(out)] == ["loaded", "done"]


def test_flux1_is_handled_by_the_adapter():
    assert mflux_worker.ADAPTERS["mflux-generate"] is mflux_worker.Flux1Command


def test_an_adapter_that_no_longer_fits_mflux_falls_back_to_main(worker, tmp_path, monkeypatch):
    w, out, module = worker

    class Broken:
        @staticmethod
        def load(args):
            raise ImportError("mflux.models.flux.variants moved")

    monkeypatch.setitem(mflux_worker.ADAPTERS, "mflux-generate-z-image-turbo", Broken)

    def main():
        with open(sys.argv[sys.argv.index("--output") + 1], "w") as f:
            f.write("png")

    module.main = main
    w.generate_safely(request(tmp_path))
    assert [e["event"] for e in events(out)] == ["loading", "loaded", "done"]
