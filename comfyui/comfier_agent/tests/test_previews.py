import os
import textwrap

import pytest

from comfier_agent import jobs


def stub_renderer(tmp_path, body: str) -> str:
    script = tmp_path / "stub_preview.py"
    script.write_text("import sys\n" + textwrap.dedent(body))
    return str(script)


@pytest.fixture
def renders_jpeg(tmp_path, monkeypatch):
    calls = tmp_path / "calls.txt"
    monkeypatch.setattr(jobs, "PREVIEW_SCRIPT", stub_renderer(tmp_path, f"""
        open({str(calls)!r}, "a").write(sys.argv[1] + "\\n")
        open(sys.argv[2], "wb").write(b"\\xff\\xd8\\xff\\xe0preview")
    """))
    return calls


@pytest.mark.asyncio
async def test_first_3d_output_gets_a_preview_uploaded_after_it(agent, renders_jpeg):
    await agent.start()
    prompt_id = await agent.run_to_execution(previews=["3d"])
    await agent.finish(prompt_id, {"mesh.glb": b"glTF....", "other.obj": b"v 0 0 0", "out.png": b"PNG"})
    (done,) = await agent.front.wait_for_types("job.completed", timeout=8)

    assert [(o["filename"], o.get("role")) for o in done["outputs"]] == [
        ("mesh.glb", None), ("mesh_preview.jpg", "preview"), ("other.obj", None), ("out.png", None),
    ]
    preview = agent.front.uploads[1]
    assert preview["role"] == "preview"
    assert preview["mime"] == "image/jpeg"
    assert preview["bytes"].startswith(b"\xff\xd8")
    assert len(renders_jpeg.read_text().splitlines()) == 1


@pytest.mark.asyncio
async def test_no_preview_unless_the_frontend_takes_them(agent, renders_jpeg):
    await agent.start()
    prompt_id = await agent.run_to_execution()
    await agent.finish(prompt_id, {"mesh.glb": b"glTF...."})
    (done,) = await agent.front.wait_for_types("job.completed", timeout=8)

    assert [o["filename"] for o in done["outputs"]] == ["mesh.glb"]
    assert not renders_jpeg.exists()


@pytest.mark.asyncio
async def test_a_preview_that_cant_be_rendered_leaves_the_job_alone(agent, tmp_path, monkeypatch):
    monkeypatch.setattr(jobs, "PREVIEW_SCRIPT", stub_renderer(tmp_path, """
        print("ModuleNotFoundError: No module named 'trimesh'", file=sys.stderr)
        sys.exit(1)
    """))
    await agent.start()
    prompt_id = await agent.run_to_execution(previews=["3d"])
    await agent.finish(prompt_id, {"mesh.glb": b"glTF...."})
    (done,) = await agent.front.wait_for_types("job.completed", timeout=8)

    assert [o["filename"] for o in done["outputs"]] == ["mesh.glb"]
    assert "warning" not in done


@pytest.mark.asyncio
async def test_a_renderer_that_wont_start_leaves_the_job_alone(agent, monkeypatch):
    async def no_spawn(*args, **kwargs):
        raise OSError("cannot spawn")

    monkeypatch.setattr(jobs.asyncio, "create_subprocess_exec", no_spawn)
    await agent.start()
    prompt_id = await agent.run_to_execution(previews=["3d"])
    await agent.finish(prompt_id, {"mesh.glb": b"glTF...."})
    (done,) = await agent.front.wait_for_types("job.completed", timeout=8)

    assert [o["filename"] for o in done["outputs"]] == ["mesh.glb"]


@pytest.mark.asyncio
async def test_slow_renders_are_killed(tmp_path, monkeypatch):
    monkeypatch.setattr(jobs, "PREVIEW_SCRIPT", stub_renderer(tmp_path, "import time\ntime.sleep(30)\n"))
    monkeypatch.setattr(jobs, "PREVIEW_TIMEOUT_S", 0.2)
    model = tmp_path / "mesh.glb"
    model.write_bytes(b"glTF")
    before = set(os.listdir(jobs.tempfile.gettempdir()))

    assert await jobs.render_preview(str(model), "mesh.glb") is None
    after = set(os.listdir(jobs.tempfile.gettempdir()))
    assert not [name for name in after - before if name.endswith(".jpg")]


def test_renders_a_textured_model(tmp_path):
    np = pytest.importorskip("numpy")
    trimesh = pytest.importorskip("trimesh")
    image_mod = pytest.importorskip("PIL.Image")
    from comfier_agent import preview

    box = trimesh.creation.box()
    texture = image_mod.new("RGB", (8, 8), (200, 30, 30))
    uv = np.tile([[0.5, 0.5]], (len(box.vertices), 1))
    box.visual = trimesh.visual.TextureVisuals(uv=uv, image=texture)
    model = tmp_path / "box.glb"
    box.export(model)
    out = tmp_path / "box.jpg"

    assert preview.main(["preview.py", str(model), str(out), "256"]) == 0
    with image_mod.open(out) as image:
        assert image.size == (256, 256)
        r, g, b = image.convert("RGB").getpixel((128, 128))
        assert r > 2 * g and r > 2 * b
        assert image.getpixel((2, 2))[0] > 200


def test_unreadable_model_exits_nonzero(tmp_path, capsys):
    pytest.importorskip("trimesh")
    from comfier_agent import preview

    model = tmp_path / "mesh.glb"
    model.write_bytes(b"not a model")
    assert preview.main(["preview.py", str(model), str(tmp_path / "out.jpg")]) == 1
    assert capsys.readouterr().err

