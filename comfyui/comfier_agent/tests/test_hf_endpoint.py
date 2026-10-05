from comfier_agent.hf_endpoint import (
    hf_endpoint_host_allowed,
    host_matches_allowlist,
    rewrite_url,
)


def test_rewrite_preserves_query_and_prefix():
    url, ok = rewrite_url(
        "https://huggingface.co/org/repo/resolve/main/a.safetensors?download=true",
        "https://cache.example/hf",
    )
    assert ok
    assert url == "https://cache.example/hf/org/repo/resolve/main/a.safetensors?download=true"


def test_rewrite_skips_cdn_hosts():
    url, ok = rewrite_url("https://cdn-lfs.huggingface.co/x", "https://cache.example")
    assert not ok
    assert url.startswith("https://cdn-lfs")


def test_endpoint_host_allowed_with_hub_allowlist():
    assert hf_endpoint_host_allowed("cache.internal", ["huggingface.co"], "https://cache.internal")
    assert not hf_endpoint_host_allowed("evil.test", ["huggingface.co"], "https://cache.internal")


def test_host_matches_allowlist_subdomains():
    assert host_matches_allowlist("cdn-lfs.huggingface.co", ["huggingface.co"])
