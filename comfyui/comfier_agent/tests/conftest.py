import asyncio
import os
import sys
import types

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TESTS = os.path.dirname(__file__)
for path in (ROOT, TESTS):
    if path not in sys.path:
        sys.path.insert(0, path)

from fake_comfy import FakeComfy  # noqa: E402
from fake_frontend import FakeFrontend  # noqa: E402

from comfier_agent import connection  # noqa: E402
from comfier_agent.config import AgentConfig  # noqa: E402
from comfier_agent.runtime import AgentRuntime  # noqa: E402


@pytest.fixture(autouse=True)
def comfier_home(tmp_path, monkeypatch):
    """Settings, work files and the GPU lock go under the test's own folder, never ~/.comfier."""
    home = tmp_path / "comfier-home"
    monkeypatch.setenv("COMFIER_HOME", str(home))
    for name in ("COMFIER_ENGINES", "COMFIER_WORK_DIR", "COMFIER_GPU_LOCK"):
        monkeypatch.delenv(name, raising=False)
    return home


@pytest.fixture
def folder_paths_stub(tmp_path, monkeypatch):
    models = tmp_path / "models"
    inp = tmp_path / "input"
    out = tmp_path / "output"
    for p in (models / "checkpoints", inp / "comfier", out):
        p.mkdir(parents=True)
    fp = types.ModuleType("folder_paths")
    fp.folder_names_and_paths = {"checkpoints": ([str(models / "checkpoints")], {".safetensors"})}
    fp.get_folder_paths = lambda name: fp.folder_names_and_paths[name][0]
    fp.get_input_directory = lambda: str(inp)
    fp.get_output_directory = lambda: str(out)
    fp.get_directory_by_type = lambda t: {"input": str(inp), "output": str(out), "temp": str(out)}.get(t)
    monkeypatch.setitem(sys.modules, "folder_paths", fp)
    return {"fp": fp, "inp": inp, "models": models}


class AgentHarness:
    """A real AgentRuntime between a fake frontend and a fake ComfyUI."""

    def __init__(self, front: FakeFrontend, comfy: FakeComfy, inp):
        self.front = front
        self.comfy = comfy
        self.inp = inp
        self.runtime: AgentRuntime | None = None
        self._task: asyncio.Task | None = None

    async def start(self, wait_for_request: bool = True, **overrides) -> AgentRuntime:
        overrides.setdefault("engines", ["comfyui"])
        cfg = AgentConfig(
            frontend_url=self.front.base_url,
            api_key="test-key",
            comfyui_url=self.comfy.base_url,
            allow_insecure=True,
            enabled=True,
            comfyui_input_dir=str(self.inp),
            min_free_disk_gb=0,
            **overrides,
        )
        self.runtime = AgentRuntime(cfg)
        self._task = asyncio.create_task(self.runtime.run(sidecar=True))
        await self.front.wait_for_types("hello", *(() if wait_for_request is False else ("job.request",)), timeout=8)
        return self.runtime

    async def stop(self) -> None:
        if self.runtime:
            await self.runtime.stop()
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    def assign(self, job_id: str = "j_1", **extra) -> dict:
        req = self.front.of_type("job.request")[-1]
        base = self.front.base_url
        msg = {
            "type": "job.assign",
            "request_id": req["request_id"],
            "job_id": job_id,
            "workflow": {"3": {"class_type": "LoadImage", "inputs": {"image": "comfier-input://in_0"}}},
            "inputs": [{
                "id": "in_0",
                "url": f"{base}/api/agent/jobs/{job_id}/inputs/in_0",
                "filename": "photo.png",
                "bytes": len(self.front.input_payload),
            }],
            "upload_url": f"{base}/api/agent/jobs/{job_id}/outputs",
            "requires": {"node_types": ["LoadImage"], "models": {}},
            "timeout_s": 30,
        }
        msg.update(extra)
        return msg

    async def run_to_execution(self, job_id: str = "j_1", **extra) -> str:
        """Assign a job and wait until ComfyUI has its prompt. Returns the prompt id."""
        start = len(self.front.messages)
        await self.front.send(self.assign(job_id, **extra))
        await self.front.wait_for_types("job.accepted", timeout=8, after=start)
        await self.front.wait_for(lambda: self.comfy.last_prompt is not None
                                  and self.comfy.last_prompt["extra_data"]["comfier_job_id"] == job_id)
        await asyncio.sleep(0.1)
        return f"p_{self.comfy.prompt_counter}"

    async def finish(self, prompt_id: str, files: dict[str, bytes]) -> None:
        self.comfy.output_files.update(files)
        self.comfy.history[prompt_id] = {
            "outputs": {"9": {"images": [{"filename": n, "type": "output", "subfolder": ""} for n in files]}},
        }
        await self.comfy.push_ws({"type": "execution_start", "prompt_id": prompt_id})
        await self.comfy.push_ws({"type": "executing", "prompt_id": prompt_id, "node": "9"})
        await self.comfy.push_ws({"type": "execution_success", "prompt_id": prompt_id})


@pytest.fixture
async def agent(folder_paths_stub, monkeypatch):
    monkeypatch.setattr(connection, "INITIAL_RETRY_S", 0.05)
    monkeypatch.setattr(connection.random, "uniform", lambda _a, _b: 0.0)
    front = FakeFrontend()
    comfy = FakeComfy()
    await front.start()
    await comfy.start()
    harness = AgentHarness(front, comfy, folder_paths_stub["inp"])
    try:
        yield harness
    finally:
        await harness.stop()
        await comfy.stop()
        await front.stop()
