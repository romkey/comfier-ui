"""Wire protocol helpers."""

from __future__ import annotations

import base64
import gzip
import json
import re
from typing import Any

PROTOCOL_VERSION = 1

INPUT_REF = re.compile(r"^comfier-input://(?P<id>[^/]+)$")
PLACEHOLDER = re.compile(r"\{\{[^}]+\}\}")


def dumps(msg: dict[str, Any]) -> str:
    return json.dumps(msg, separators=(",", ":"), sort_keys=True)


def loads(raw: str) -> dict[str, Any]:
    data = json.loads(raw)
    if not isinstance(data, dict) or "type" not in data:
        raise ValueError("invalid message")
    return data


def canonical_hash(obj: Any) -> str:
    import hashlib

    payload = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


OBJECT_INFO_CHUNK_CHARS = 800_000
OBJECT_INFO_MAX_CHUNKS = 64


def compact(msg: dict[str, Any]) -> dict[str, Any]:
    """Drop None values: the schema types optional fields, and null is not one of those types."""
    return {k: v for k, v in msg.items() if v is not None}


def encode_object_info(
    data: dict[str, Any], info_hash: str, *, chunk_chars: int = OBJECT_INFO_CHUNK_CHARS
) -> list[dict[str, Any]]:
    """object_info as gzip+base64, split into messages the frontend joins in index order."""
    raw = json.dumps(data, sort_keys=True, separators=(",", ":")).encode("utf-8")
    encoded = base64.b64encode(gzip.compress(raw, compresslevel=6)).decode("ascii")
    pieces = [encoded[i:i + chunk_chars] for i in range(0, len(encoded), chunk_chars)] or [""]
    if len(pieces) > OBJECT_INFO_MAX_CHUNKS:
        raise ValueError(f"object_info needs {len(pieces)} chunks; the limit is {OBJECT_INFO_MAX_CHUNKS}")
    return [
        {
            "type": "object_info",
            "hash": info_hash,
            "index": index,
            "count": len(pieces),
            "encoding": "gzip+base64",
            "data": piece,
            "bytes": len(raw),
        }
        for index, piece in enumerate(pieces)
    ]


def find_unreplaced_placeholders(workflow: dict[str, Any]) -> list[str]:
    found: list[str] = []

    def walk(value: Any) -> None:
        if isinstance(value, str) and PLACEHOLDER.search(value):
            found.append(value)
        elif isinstance(value, dict):
            for v in value.values():
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)

    walk(workflow)
    return found


def replace_input_refs(workflow: dict[str, Any], mapping: dict[str, str]) -> dict[str, Any]:
    """Return a copy of workflow with comfier-input:// refs replaced."""

    def walk(value: Any) -> Any:
        if isinstance(value, str):
            m = INPUT_REF.match(value)
            if m:
                ref = m.group("id")
                if ref not in mapping:
                    raise KeyError(ref)
                return mapping[ref]
            return value
        if isinstance(value, dict):
            return {k: walk(v) for k, v in value.items()}
        if isinstance(value, list):
            return [walk(v) for v in value]
        return value

    return walk(workflow)
