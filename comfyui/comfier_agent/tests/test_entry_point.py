"""The entry point's argument fixes for mlx-video."""

import sys
import types

import pytest

from comfier_agent.workers.entry_point import wan_model_dir
from comfier_agent.workers.hf_download import patterns_for


@pytest.fixture
def snapshots(monkeypatch):
    calls = []

    def snapshot_download(repo_id, allow_patterns):
        calls.append((repo_id, allow_patterns))
        return f"/cache/{repo_id}/snap"

    monkeypatch.setitem(sys.modules, "huggingface_hub", types.SimpleNamespace(snapshot_download=snapshot_download))
    return calls


def test_a_wan_repo_and_subfolder_become_its_cached_folder(snapshots):
    args = ["--model-repo", "SceneWorks/wan2.2-t2v-a14b-mlx", "--prompt", "waves", "--model-subdir", "q8"]

    assert wan_model_dir(args) == ["--model-dir", "/cache/SceneWorks/wan2.2-t2v-a14b-mlx/snap/q8", "--prompt", "waves"]
    assert snapshots == [("SceneWorks/wan2.2-t2v-a14b-mlx", ["q8/*"])]


def test_a_local_model_dir_is_left_alone(snapshots):
    args = ["--model-dir", "/models/wan", "--prompt", "waves"]

    assert wan_model_dir(args) == args
    assert snapshots == []


@pytest.mark.parametrize("args", [["--model-subdir", "q8"], ["--model-repo", "a/b", "--model-subdir", "../q8"]])
def test_bad_subfolders_are_refused(snapshots, args):
    with pytest.raises(SystemExit):
        wan_model_dir(args)
    assert snapshots == []


def test_downloading_ahead_fetches_only_the_8_bit_wan_files():
    assert patterns_for("SceneWorks/wan2.2-t2v-a14b-mlx") == ["q8/*"]
