"""Persistent mlx-video CLI host. Cache loaded components, never generated tensors or prompts.

The CLI still owns parsing, conditioning and generation. Scoped loader wrappers keep strong
references to weights that upstream otherwise deletes between stages. The parent ends this
process to unload everything, switch recipes, cancel a job or recover from an error.
"""

from __future__ import annotations

import contextlib
import functools
import importlib
import inspect
import json
import os
import sys
import traceback
from pathlib import Path

from comfier_agent.workers import entry_point


def freeze(value):
    if isinstance(value, dict):
        return tuple(sorted((k, freeze(v)) for k, v in value.items()))
    if isinstance(value, (list, tuple)):
        return tuple(freeze(v) for v in value)
    if isinstance(value, Path):
        return str(value)
    return repr(value)


class CachedTextEncoder:
    """Keep the whole LTX encoder, including projection weights and tokenizer, warm."""

    def __init__(self, encoder):
        self.encoder = encoder
        self.load_key = None

    def load(self, *args, **kwargs):
        key = (freeze(args), freeze(kwargs))
        if key != self.load_key:
            self.encoder.load(*args, **kwargs)
            self.load_key = key

    def __call__(self, *args, **kwargs):
        return self.encoder(*args, **kwargs)

    def __getattr__(self, name):
        return getattr(self.encoder, name)


class ModelCache:
    def __init__(self):
        self.models = {}

    def wrap(self, name, loader):
        signature = inspect.signature(loader)

        @functools.wraps(loader)
        def load(*args, **kwargs):
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            key = (name, freeze(bound.arguments))
            if key not in self.models:
                self.models[key] = loader(*args, **kwargs)
            return self.models[key]

        return load

    @contextlib.contextmanager
    def loaders(self, command):
        """Patch only model loaders in the pinned upstream API, restoring their descriptors afterward.

        LTX multi-stage pipelines merge LoRAs into their transformer in place. Reload that
        component on each job, while still retaining the text encoder and VAE weights.
        Wan's loader merges its LoRAs once; caching the returned model avoids merging again.
        """
        module = importlib.import_module(entry_point.find(command).__module__)
        patches = []
        if command.startswith("mlx_video.ltx_2."):
            text = importlib.import_module("mlx_video.models.ltx_2.text_encoder")
            patches += [(module, name) for name in ("load_upsampler", "load_audio_decoder", "load_vocoder_model")]
            patches += [(getattr(module, name), "from_pretrained") for name in ("VideoEncoder", "VideoDecoder")]
            # generate_video's default is distilled. Parse flags without duplicating upstream's parser.
            pipeline = option(sys.argv, "--pipeline", "distilled")
            if pipeline in ("distilled", "dev"):
                patches.append((module.LTXModel, "from_pretrained"))
        elif command.startswith("mlx_video.wan_2."):
            patches += [(module, name) for name in ("load_t5_encoder", "load_wan_model",
                                                   "load_vae_encoder", "load_vae_decoder")]
        else:
            raise ValueError(f"unsupported persistent video command: {command}")
        with contextlib.ExitStack() as stack:
            if command.startswith("mlx_video.ltx_2."):
                constructor = text.LTX2TextEncoder

                def create_encoder(*args, **kwargs):
                    return CachedTextEncoder(constructor(*args, **kwargs))

                stack.callback(setattr, text, "LTX2TextEncoder", constructor)
                text.LTX2TextEncoder = self.wrap("ltx_text_encoder", create_encoder)
            for target, name in patches:
                descriptor = inspect.getattr_static(target, name)
                loader = getattr(target, name)
                wrapped = self.wrap(f"{target.__module__ if inspect.isclass(target) else target.__name__}."
                                    f"{getattr(target, '__qualname__', '')}.{name}", loader)
                stack.callback(setattr, target, name, descriptor)
                setattr(target, name, staticmethod(wrapped) if inspect.isclass(target) else wrapped)
            yield


def option(argv, flag, default=None):
    for i, value in enumerate(argv):
        if value.startswith(flag + "="):
            return value.split("=", 1)[1]
        if value == flag and i + 1 < len(argv):
            return argv[i + 1]
    return default


class Worker:
    def __init__(self, out):
        self.out = out
        self.cache = ModelCache()
        self.fixed = False

    def emit(self, **event):
        self.out.write(json.dumps(event) + "\n")
        self.out.flush()

    def generate(self, request):
        command = request["command"]
        func = entry_point.find(command)
        # Quantization patches must be installed only once, never wrapped again for a warm job.
        if not self.fixed:
            for prefix, fixes in entry_point.FIXES.items():
                if command.startswith(prefix):
                    for fix in fixes:
                        fix()
            self.fixed = True
        args = request["argv"]
        if command.startswith("mlx_video.wan_2."):
            args = entry_point.wan_model_dir(args)
        saved = sys.argv
        try:
            sys.argv = [command, *args, "--output-path", request["output"]]
            with self.cache.loaders(command):
                result = func()
            if isinstance(result, int) and result:
                raise RuntimeError(f"mlx-video exited with code {result}")
            if not Path(request["output"]).is_file():
                raise RuntimeError("mlx-video finished without writing a video")
        finally:
            sys.argv = saved

    def serve(self, stream):
        for line in stream:
            if not line.strip():
                continue
            request = json.loads(line)
            try:
                self.generate(request)
            except BaseException as exc:  # includes argparse's SystemExit
                self.emit(event="error", id=request["id"], message=str(exc) or type(exc).__name__,
                          traceback=traceback.format_exc())
                return 1  # never retain partially mutated models after failure
            self.emit(event="done", id=request["id"])
        return 0


def main():
    out = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)  # upstream output/progress must not corrupt the JSON event stream
    return Worker(out).serve(sys.stdin)


if __name__ == "__main__":
    sys.exit(main())
