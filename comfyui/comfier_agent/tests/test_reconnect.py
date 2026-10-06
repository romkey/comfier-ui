import asyncio

import pytest

from comfier_agent.connection import CLOSE_REASONS, TERMINAL_BUFFER_MAX, FrontendConnection
from comfier_agent.models import DownloadState
from comfier_agent.routes import apply_config, status_payload


async def reconnect(agent, code=1011):
    """Close the socket from the frontend side and wait for the next hello."""
    before = agent.front.connections
    start = len(agent.front.messages)
    await agent.front.close_agent(code)
    await agent.front.wait_for(lambda: agent.front.connections > before, timeout=5)
    await agent.front.wait_for_types("hello", timeout=5, after=start)
    return start


@pytest.mark.asyncio
async def test_terminal_events_are_resent_after_hello(agent):
    await agent.start()
    prompt_id = await agent.run_to_execution()
    await agent.finish(prompt_id, {"out.png": b"PNG"})
    await agent.front.wait_for_types("job.completed", timeout=8)

    start = await reconnect(agent)
    await agent.front.wait_for_types("job.completed", timeout=5, after=start)
    after = [m["type"] for m in agent.front.messages[start:]]
    assert after.index("hello") < after.index("job.completed")

    # Delivered once after the reconnect; not again on the next one.
    start = await reconnect(agent)
    await asyncio.sleep(0.3)
    assert "job.completed" not in [m["type"] for m in agent.front.messages[start:]]


@pytest.mark.asyncio
async def test_hello_lists_the_running_job_and_downloads(agent):
    runtime = await agent.start()
    await agent.run_to_execution("j_7")
    runtime.models.active["d_1"] = DownloadState(download_id="d_1", bytes_done=10, bytes_total=100)
    try:
        start = await reconnect(agent)
        (hello,) = await agent.front.wait_for_types("hello", after=start)
        assert hello["active_jobs"][0]["job_id"] == "j_7"
        assert hello["active_downloads"] == [
            {"download_id": "d_1", "state": "downloading", "bytes_done": 10, "bytes_total": 100},
        ]
    finally:
        runtime.models.active.pop("d_1", None)


@pytest.mark.asyncio
async def test_connecting_opens_exactly_one_job_request(agent):
    await agent.start()
    await asyncio.sleep(0.3)
    assert len(agent.front.of_type("job.request")) == 1

    start = len(agent.front.messages)
    await agent.front.send(agent.assign("j_1"))
    await agent.front.wait_for_types("job.accepted", timeout=8, after=start)


@pytest.mark.asyncio
async def test_an_assign_for_an_old_request_is_rejected_and_a_new_request_opened(agent):
    await agent.start()
    first = agent.front.of_type("job.request")[-1]["request_id"]
    start = len(agent.front.messages)
    await agent.front.send(agent.assign("j_4", request_id="r_stale"))

    rejected, request = await agent.front.wait_for_types("job.rejected", "job.request", after=start)
    assert rejected["reason"] == "busy"
    assert request["request_id"] != first


@pytest.mark.asyncio
async def test_an_idle_reconnect_opens_a_fresh_job_request(agent):
    await agent.start()
    first = agent.front.of_type("job.request")[-1]["request_id"]

    start = await reconnect(agent)
    (request,) = await agent.front.wait_for_types("job.request", after=start)
    assert request["request_id"] != first

    start = len(agent.front.messages)
    await agent.front.send(agent.assign("j_2"))
    await agent.front.wait_for_types("job.accepted", timeout=8, after=start)


@pytest.mark.asyncio
async def test_a_rejected_assign_is_followed_by_a_new_job_request(agent):
    await agent.start()
    start = len(agent.front.messages)
    missing = {"node_types": ["LoadImage"], "models": {"checkpoints": ["absent.safetensors"]}}
    await agent.front.send(agent.assign("j_3", requires=missing))

    rejected, request = await agent.front.wait_for_types("job.rejected", "job.request", after=start)
    assert rejected["reason"] == "missing_models"
    assert agent.front.messages.index(rejected) < agent.front.messages.index(request)


@pytest.mark.asyncio
async def test_cancel_for_an_unknown_job_is_confirmed(agent):
    await agent.start()
    start = len(agent.front.messages)
    await agent.front.send({"type": "job.cancel", "job_id": "j_gone"})
    (cancelled,) = await agent.front.wait_for_types("job.cancelled", after=start)
    assert cancelled["job_id"] == "j_gone"


@pytest.mark.asyncio
async def test_revoked_key_close_is_explained_and_backs_off(agent):
    runtime = await agent.start()
    await agent.front.close_agent(4401, b"key revoked")
    await agent.front.wait_for(lambda: runtime.connection.last_close_code == 4401)
    status = runtime.connection.status_dict()
    assert status["state"] == "waiting"
    assert status["last_close_reason"] == CLOSE_REASONS[4401]
    assert status["retry_at"] - status["connected_at"] > 250
    payload = status_payload(runtime)
    assert payload["connection"]["last_close_code"] == 4401
    assert payload["backend_name"] == runtime.config.backend_name


@pytest.mark.asyncio
async def test_replaced_connection_is_explained(agent):
    runtime = await agent.start()
    await agent.front.close_agent(4409, b"replaced")
    await agent.front.wait_for(lambda: runtime.connection.last_close_code == 4409)
    assert "Another agent connected" in runtime.connection.status_dict()["last_close_reason"]


@pytest.mark.asyncio
async def test_saving_a_new_key_reconnects_with_it(agent):
    runtime = await agent.start()
    agent.front.auth_key = "new-key"
    before = agent.front.connections
    restart = await apply_config(runtime, {"api_key": "new-key", "backend_name": "Studio box"})
    assert restart is False
    await agent.front.wait_for(lambda: agent.front.connections > before, timeout=5)
    (hello,) = await agent.front.wait_for_types("hello", after=0)
    assert agent.front.auth_header_seen == "Bearer new-key"
    assert agent.front.of_type("hello")[-1]["backend_name"] == "Studio box"


def test_rejected_key_at_handshake_is_explained():
    from comfier_agent.config import AgentConfig

    conn = FrontendConnection(AgentConfig(frontend_url="https://comfier.example.com", api_key="k"))
    assert conn._handshake_failed(401) == 300.0  # noqa: SLF001
    assert "rejected the API key" in conn.last_error


def test_terminal_buffer_is_bounded():
    from comfier_agent.config import AgentConfig

    conn = FrontendConnection(AgentConfig())
    for i in range(TERMINAL_BUFFER_MAX + 20):
        conn.buffer_terminal({"type": "job.cancelled", "job_id": f"j_{i}"})
    assert len(conn._terminal_out) == TERMINAL_BUFFER_MAX  # noqa: SLF001
    assert conn._terminal_out[-1]["job_id"] == f"j_{TERMINAL_BUFFER_MAX + 19}"  # noqa: SLF001


@pytest.mark.asyncio
async def test_cancel_interrupts_a_running_prompt_without_a_websocket_hint(agent):
    runtime = await agent.start()
    prompt_id = await agent.run_to_execution("j_8")
    agent.comfy.queue_running = [[0, prompt_id, {}, {}, []]]
    start = len(agent.front.messages)
    await agent.front.send({"type": "job.cancel", "job_id": "j_8"})
    await agent.front.wait_for(lambda: prompt_id in agent.comfy.interrupts, timeout=5)
    agent.comfy.queue_running = []
    await agent.comfy.push_ws({"type": "execution_interrupted", "prompt_id": prompt_id})

    (cancelled,) = await agent.front.wait_for_types("job.cancelled", timeout=5, after=start)
    assert cancelled["job_id"] == "j_8"
    assert runtime.jobs.active is None
    assert "job.completed" not in [m["type"] for m in agent.front.messages[start:]]


@pytest.mark.asyncio
async def test_cancel_gives_up_when_comfyui_never_confirms(agent, monkeypatch):
    from comfier_agent import jobs

    monkeypatch.setattr(jobs, "CANCEL_GRACE_S", 0.3)
    runtime = await agent.start()
    await agent.run_to_execution("j_9")
    start = len(agent.front.messages)
    await agent.front.send({"type": "job.cancel", "job_id": "j_9"})

    await agent.front.wait_for_types("job.cancelled", timeout=5, after=start)
    await agent.front.wait_for_types("job.request", timeout=5, after=start)
    assert runtime.jobs.active is None
    await asyncio.sleep(0.6)
    assert [m["type"] for m in agent.front.messages[start:]].count("job.cancelled") == 1
