from comfier_agent.config import AgentConfig
from comfier_agent.hf_cli import cli_env, parse_hf_resolve_url, token_from_headers


def test_parse_hf_resolve_url():
    spec = parse_hf_resolve_url(
        "https://huggingface.co/acme/model/resolve/main/sub/file.safetensors?download=true"
    )
    assert spec.repo_id == "acme/model"
    assert spec.revision == "main"
    assert spec.filename == "sub/file.safetensors"

    ds = parse_hf_resolve_url("https://huggingface.co/datasets/org/data/resolve/v2/a.bin")
    assert ds.repo_id == "datasets/org/data"
    assert ds.revision == "v2"
    assert ds.filename == "a.bin"

    assert parse_hf_resolve_url("https://civitai.com/x") is None


def test_cli_env_sets_endpoint_and_token():
    cfg = AgentConfig(hf_endpoint="https://cache.internal/hf")
    env = cli_env(cfg, {"Authorization": "Bearer from_comfier"})
    assert env["HF_ENDPOINT"] == "https://cache.internal/hf"
    assert env["HF_TOKEN"] == "from_comfier"


def test_cli_env_keeps_existing_hf_token(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", "local")
    env = cli_env(AgentConfig(), {})
    assert env["HF_TOKEN"] == "local"


def test_token_from_headers():
    assert token_from_headers({"Authorization": "Bearer abc"}) == "abc"
    assert token_from_headers({}) is None
