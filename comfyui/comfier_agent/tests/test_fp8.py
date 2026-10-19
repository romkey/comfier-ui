import json

import pytest

from comfier_agent.fp8 import ConversionError, convert_fp8_to_fp16

np = pytest.importorskip("numpy")


def write_safetensors(path, tensors, metadata=None):
    """tensors: name -> (dtype, shape, raw bytes)."""
    header, offset = ({"__metadata__": metadata} if metadata else {}), 0
    for name, (dtype, shape, raw) in tensors.items():
        header[name] = {"dtype": dtype, "shape": shape, "data_offsets": [offset, offset + len(raw)]}
        offset += len(raw)
    data = json.dumps(header).encode()
    with open(path, "wb") as f:
        f.write(len(data).to_bytes(8, "little") + data + b"".join(raw for _, _, raw in tensors.values()))


def read_safetensors(path):
    with open(path, "rb") as f:
        length = int.from_bytes(f.read(8), "little")
        assert (8 + length) % 8 == 0
        header = json.loads(f.read(length))
        body = f.read()
    metadata = header.pop("__metadata__", {})
    views = {"F16": np.float16, "F32": np.float32, "U8": np.uint8}
    tensors = {name: np.frombuffer(body[i["data_offsets"][0]:i["data_offsets"][1]], dtype=views.get(i["dtype"],
               np.uint8)).reshape(i["shape"]) if i["dtype"] in views else (i["dtype"], body[slice(*i["data_offsets"])])
               for name, i in header.items()}
    return header, tensors, metadata


# e4m3fn: 1.0, 2.0, -1.0, 2^-9 (smallest subnormal), 448 (largest)
E4M3 = bytes([0x38, 0x40, 0xB8, 0x01, 0x7E, 0x00])
E4M3_VALUES = [1.0, 2.0, -1.0, 2.0**-9, 448.0, 0.0]


def test_scaled_fp8_becomes_plain_fp16(tmp_path):
    src, dst = tmp_path / "in.safetensors", tmp_path / "out.safetensors"
    write_safetensors(src, {
        "scaled_fp8": ("F8_E4M3", [0], b""),
        "blocks.0.linear.weight": ("F8_E4M3", [2, 3], E4M3),
        "blocks.0.linear.scale_weight": ("F32", [], np.float32(0.5).tobytes()),
        "blocks.0.linear.scale_input": ("F32", [], np.float32(1).tobytes()),
        "blocks.0.linear.bias": ("F32", [2], np.float32([0.25, -3]).tobytes()),
        "head.bf16": ("BF16", [1], (np.float32([1.5]).view(np.uint32) >> 16).astype(np.uint16).tobytes()),
    }, metadata={"format": "pt", "_quantization_metadata": "{}"})

    size = convert_fp8_to_fp16(str(src), str(dst))

    header, tensors, metadata = read_safetensors(dst)
    assert size == dst.stat().st_size
    assert metadata == {"format": "pt"}
    assert set(header) == {"blocks.0.linear.weight", "blocks.0.linear.bias", "head.bf16"}
    assert header["blocks.0.linear.weight"]["dtype"] == "F16"
    np.testing.assert_array_equal(tensors["blocks.0.linear.weight"].ravel(), np.float16([v * 0.5 for v in E4M3_VALUES]))
    np.testing.assert_array_equal(tensors["blocks.0.linear.bias"], np.float32([0.25, -3]))
    assert tensors["head.bf16"][0] == "BF16"


def test_comfy_quant_per_channel_scales(tmp_path):
    src, dst = tmp_path / "in.safetensors", tmp_path / "out.safetensors"
    write_safetensors(src, {
        "l.weight": ("F8_E4M3", [2, 3], E4M3),
        "l.weight_scale": ("F32", [2, 1], np.float32([2, 4]).tobytes()),
        "l.comfy_quant": ("U8", [27], json.dumps({"format": "float8_e4m3fn"}).encode().ljust(27)),
    })

    convert_fp8_to_fp16(str(src), str(dst))

    _, tensors, _ = read_safetensors(dst)
    expected = np.float32(E4M3_VALUES).reshape(2, 3) * np.float32([[2], [4]])
    np.testing.assert_array_equal(tensors["l.weight"], expected.astype(np.float16))


def test_unscaled_e5m2(tmp_path):
    src, dst = tmp_path / "in.safetensors", tmp_path / "out.safetensors"
    halves = np.float16([1.0, -2.0, 0.5])
    write_safetensors(src, {"w": ("F8_E5M2", [3], (halves.view(np.uint16) >> 8).astype(np.uint8).tobytes())})

    convert_fp8_to_fp16(str(src), str(dst))

    np.testing.assert_array_equal(read_safetensors(dst)[1]["w"], halves)


def test_refuses_other_quantization_and_cleans_up(tmp_path):
    src, dst = tmp_path / "in.safetensors", tmp_path / "out.safetensors"
    write_safetensors(src, {
        "l.weight": ("U8", [2, 2], bytes(4)),
        "l.weight_scale": ("F32", [], np.float32(1).tobytes()),
        "l.comfy_quant": ("U8", [19], json.dumps({"format": "nvfp4"}).encode().ljust(19)),
    })

    with pytest.raises(ConversionError, match="nvfp4"):
        convert_fp8_to_fp16(str(src), str(dst))
    assert not dst.exists()


def test_refuses_a_file_without_fp8(tmp_path):
    src = tmp_path / "in.safetensors"
    write_safetensors(src, {"w": ("F32", [1], np.float32(1).tobytes())})

    with pytest.raises(ConversionError, match="no fp8"):
        convert_fp8_to_fp16(str(src), str(tmp_path / "out.safetensors"))
