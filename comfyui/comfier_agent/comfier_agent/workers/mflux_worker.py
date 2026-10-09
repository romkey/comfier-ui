"""The mflux worker: runs in its own process so a crash, a cancel or giving memory back to ComfyUI is
just ending the process.

Requests arrive one JSON object per line on stdin:
  {"op": "generate", "id": "j_1", "command": "mflux-generate-z-image-turbo", "argv": [...], "output": "/x.png"}
  {"op": "unload"}
Events go back one JSON object per line on stdout: loading, loaded, progress, done, error. mflux's own
printing is sent to stderr so it can't corrupt them.

Options are parsed by the command's own build_parser(), so recipes use mflux's command-line flags. A
command with a load/generate class (most mflux CLIs have one) keeps its model loaded between jobs;
any other command runs through its main() each time.

`--inventory` prints mflux's version and the models already downloaded, then exits.
"""

from __future__ import annotations

import gc
import importlib
import importlib.metadata
import inspect
import json
import os
import random
import sys
import traceback
from typing import Any

# What decides which weights a command loads; the model stays loaded while these don't change.
LOAD_KEYS = (
    "model", "base_model", "model_path", "quantize", "lora", "lora_paths", "lora_scales", "lora_style",
    "float32", "compute_precision", "low_ram", "mlx_cache_limit_gb",
)
TRACEBACK_LINES = 20


class Flux1Command:
    """mflux-generate (FLUX.1) has no load/generate class of its own; this mirrors its main()."""

    @staticmethod
    def load(args):
        from mflux.cli.parser.parsers import lora_init_kwargs_from_args
        from mflux.models.common.config import ModelConfig
        from mflux.models.flux.variants.txt2img.flux import Flux1

        config = ModelConfig.from_name(model_name=args.model, base_model=args.base_model)
        return Flux1(model_config=config, quantize=args.quantize, model_path=args.model_path,
                     **lora_init_kwargs_from_args(args))

    @staticmethod
    def generate(model, args, seed, prompt):
        from mflux.cli.defaults import defaults as ui_defaults
        from mflux.utils.dimension_resolver import DimensionResolver
        from mflux.utils.prompt_util import PromptUtil

        width, height = DimensionResolver.resolve(height=args.height, width=args.width,
                                                  reference_image_path=args.image_path)
        return model.generate_image(
            seed=seed, prompt=prompt, width=width, height=height,
            guidance=args.guidance if args.guidance is not None else ui_defaults.GUIDANCE_SCALE,
            scheduler=args.scheduler, image_path=args.image_path, num_inference_steps=args.steps,
            image_strength=args.image_strength, negative_prompt=PromptUtil.read_negative_prompt(args),
        )


class Flux2Command:
    """mflux-generate-flux2 (FLUX.2 Klein) has no load/generate class either; this mirrors its main()."""

    @staticmethod
    def load(args):
        from mflux.cli.parser.parsers import lora_init_kwargs_from_args
        from mflux.models.common.compute_precision import ComputePrecision
        from mflux.models.common.resolution.config_resolution import ConfigResolution
        from mflux.models.flux2.cli import flux2_generate as cli
        from mflux.models.flux2.variants import Flux2Klein

        config = ConfigResolution.resolve_restricted(args.model, cli.DEFAULT_MODEL, model_path=args.model_path,
                                                     extra_keys=cli.FAMILY_MODELS, base_model=args.base_model)
        return Flux2Klein(model_config=config, quantize=args.quantize, model_path=args.model_path,
                          compute_precision=ComputePrecision.dtype_for(args.compute_precision),
                          **lora_init_kwargs_from_args(args))

    @staticmethod
    def generate(model, args, seed, prompt):
        from mflux.utils.dimension_resolver import DimensionResolver

        width, height = DimensionResolver.resolve(width=args.width, height=args.height,
                                                  reference_image_path=args.image_path)
        return model.generate_image(
            seed=seed, prompt=prompt, width=width, height=height,
            guidance=args.guidance if args.guidance is not None else 1.0,
            image_path=args.image_path, num_inference_steps=args.steps, image_strength=args.image_strength,
            scheduler="flow_match_euler_discrete",
        )


# Commands without a load/generate class of their own. If mflux changes underneath one of these, the
# worker falls back to the command's main() (no warm model, but still working).
ADAPTERS = {"mflux-generate": Flux1Command, "mflux-generate-flux2": Flux2Command}


class StepCounter:
    """An mflux in-loop callback that reports each denoising step."""

    def __init__(self, emit):
        self.emit = emit
        self.job_id: str | None = None
        self.step = 0
        self.total: int | None = None

    def start(self, job_id: str, total: int | None) -> None:
        self.job_id, self.step, self.total = job_id, 0, total

    def call_in_loop(self, t, seed, prompt, latents, config, time_steps, **_kwargs) -> None:
        self.step += 1
        total = self.total or getattr(time_steps, "total", None) or getattr(config, "num_inference_steps", None)
        self.emit({"event": "progress", "id": self.job_id, "step": self.step, "total": total})


class Worker:
    def __init__(self, out):
        self.out = out
        self.model = None
        self.model_key = None
        self.steps = StepCounter(self.emit)

    def emit(self, event: dict[str, Any]) -> None:
        self.out.write(json.dumps(event) + "\n")
        self.out.flush()

    def serve(self, stream) -> None:
        for line in stream:
            if not line.strip():
                continue
            request = json.loads(line)
            if request.get("op") == "unload":
                self.unload()
            elif request.get("op") == "generate":
                self.generate_safely(request)

    def generate_safely(self, request: dict[str, Any]) -> None:
        try:
            self.generate(request)
            self.emit({"event": "done", "id": request["id"], "output": request["output"]})
        except SystemExit as exc:
            # argparse rejected the recipe's options (it printed why to stderr).
            self.emit({"event": "error", "id": request["id"], "type": "InvalidOptions",
                       "message": f"mflux rejected the recipe's options (exit {exc.code})"})
        except BaseException as exc:  # noqa: BLE001 - every failure has to reach the agent
            self.unload()
            self.emit({"event": "error", "id": request["id"], "type": type(exc).__name__,
                       "message": str(exc) or type(exc).__name__,
                       "traceback": "".join(traceback.format_exc().splitlines(True)[-TRACEBACK_LINES:])})

    def generate(self, request: dict[str, Any]) -> None:
        command = request["command"]
        module = command_module(command)
        args = parse_args(module, command, request)
        runner = ADAPTERS.get(command) or command_class(module)
        if runner is None:
            self.unload()
            self.emit({"event": "loaded", "id": request["id"]})
            run_main(module, command, request)
            return

        key = (command, tuple((name, repr(getattr(args, name, None))) for name in LOAD_KEYS))
        if key != self.model_key:
            self.unload()
            self.emit({"event": "loading", "id": request["id"]})
            try:
                self.model = runner.load(args)
            except (ImportError, AttributeError) as exc:
                if command not in ADAPTERS:
                    raise
                print(f"comfier: {command} adapter doesn't fit this mflux ({exc}); running its main()", file=sys.stderr)
                self.emit({"event": "loaded", "id": request["id"]})
                run_main(module, command, request)
                return
            self.model_key = key
            self.model.callbacks.register(self.steps)
        self.emit({"event": "loaded", "id": request["id"]})

        from mflux.utils.prompt_util import PromptUtil

        seeds = args.seed if isinstance(args.seed, list) else [args.seed]
        seed = seeds[0] if seeds and seeds[0] is not None else random.randint(0, 2**32 - 1)
        self.steps.start(request["id"], getattr(args, "steps", None))
        image = runner.generate(self.model, args, seed, PromptUtil.read_prompt(args))
        image.save(path=request["output"], export_json_metadata=False)

    def unload(self) -> None:
        self.model = None
        self.model_key = None
        gc.collect()
        clear_mlx_cache()


def command_module(command: str):
    for entry in importlib.metadata.entry_points(group="console_scripts"):
        if entry.name == command and entry.value.startswith("mflux."):
            return importlib.import_module(entry.value.split(":")[0])
    raise ValueError(f"{command} isn't an installed mflux command (is mflux up to date?)")


def parse_args(module, command: str, request: dict[str, Any]):
    """mflux's parsers read sys.argv themselves (and check it to see which flags were given)."""
    saved = sys.argv
    sys.argv = [command, *request["argv"], "--output", request["output"]]
    try:
        return module.build_parser().parse_args()
    finally:
        sys.argv = saved


def command_class(module):
    for value in vars(module).values():
        if inspect.isclass(value) and callable(getattr(value, "load", None)) and callable(
            getattr(value, "generate", None)
        ):
            return value
    return None


def run_main(module, command: str, request: dict[str, Any]) -> None:
    saved = sys.argv
    sys.argv = [command, *request["argv"], "--output", request["output"]]
    try:
        module.main()
    finally:
        sys.argv = saved
    if not os.path.exists(request["output"]):
        raise RuntimeError(f"{command} finished without writing an image")


def clear_mlx_cache() -> None:
    try:
        import mlx.core as mx
    except ImportError:
        return
    clear = getattr(mx, "clear_cache", None) or getattr(getattr(mx, "metal", None), "clear_cache", None)
    if clear:
        clear()


def inventory() -> dict[str, Any]:
    """mflux's version, every model name it knows, and the ones whose weights are already downloaded."""
    from mflux.models.common.config.model_config import ModelConfig

    configs = []
    for name, attr in inspect.getmembers(ModelConfig):
        if name.startswith("_") or not isinstance(inspect.getattr_static(ModelConfig, name), staticmethod):
            continue
        try:
            if not inspect.signature(attr).parameters:
                config = attr()
                if isinstance(config, ModelConfig):
                    configs.append(config)
        except Exception:  # noqa: BLE001 - one odd entry shouldn't hide the rest
            continue
    try:
        from huggingface_hub import scan_cache_dir

        cached = {repo.repo_id for repo in scan_cache_dir().repos if repo.size_on_disk > 0}
    except Exception:  # noqa: BLE001 - an empty or missing cache
        cached = set()
    return {
        "version": importlib.metadata.version("mflux"),
        "catalog": sorted({alias for c in configs for alias in c.aliases}),
        "models": sorted({alias for c in configs if c.model_name in cached for alias in c.aliases}),
    }


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--inventory"]:
        print(json.dumps(inventory()))
        return 0
    # Keep the event stream to ourselves: anything else written to stdout goes to stderr.
    out = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)
    Worker(out).serve(sys.stdin)
    return 0


if __name__ == "__main__":
    sys.exit(main())
