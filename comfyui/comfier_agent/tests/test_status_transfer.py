import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.status import StatusTracker
from comfier_agent.transfer import same_origin


def test_same_origin_rejects_foreign_hosts():
    assert not same_origin("https://evil.example/file", "https://comfier.example.com")
    assert same_origin("https://comfier.example.com/file", "https://comfier.example.com/")


@pytest.mark.asyncio
async def test_busy_local_when_foreign_queue_and_no_share():
    from comfier_agent.comfy_client import ComfyClient

    class FakeComfy(ComfyClient):
        async def system_stats(self):
            return {"devices": [{"vram_free": 1}]}

        async def queue(self):
            return {"queue_running": [["n", "foreign-pid"]], "queue_pending": []}

    cfg = AgentConfig(enabled=True, accept_when_local_busy=False)
    tracker = StatusTracker(cfg, started_at=0)
    comfy = FakeComfy("http://127.0.0.1:1")
    await tracker.refresh(
        comfy,
        comfier_prompt_ids=set(),
        active_job=None,
        downloads=[],
        comfy_reachable=True,
    )
    assert tracker.snapshot.state == "busy_local"
    assert not tracker.snapshot.accepting


@pytest.mark.asyncio
async def test_finished_job_drops_out_of_the_status():
    from comfier_agent.comfy_client import ComfyClient
    from comfier_agent.status import ComfierJobStatus

    class FakeComfy(ComfyClient):
        async def system_stats(self):
            return {"devices": [{"vram_free": 1}]}

        async def queue(self):
            return {"queue_running": [], "queue_pending": []}

    tracker = StatusTracker(AgentConfig(enabled=True, min_free_disk_gb=0), started_at=0)
    comfy = FakeComfy("http://127.0.0.1:1")
    job = ComfierJobStatus(job_id="j_1", state="running")
    for active in (job, None):
        await tracker.refresh(comfy, comfier_prompt_ids=set(), active_job=active, downloads=[], comfy_reachable=True)
    assert tracker.snapshot.state == "idle"
    assert tracker.to_message()["comfier_jobs"] == []
