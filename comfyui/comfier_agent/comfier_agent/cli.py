"""comfier-agent: run the agent on its own and manage it on a Mac.

  comfier-agent setup              ask for Comfier's URL and key (or take them as flags), save them
  comfier-agent run                run in the foreground (what the service runs)
  comfier-agent service install    start at login and restart on crash (launchd)
  comfier-agent service uninstall | start | stop | restart | status
  comfier-agent logs [-f]          show the service's log
  comfier-agent doctor             check everything the agent needs
  comfier-agent pull MODEL         download an mflux model ahead of its first job
  comfier-agent lock -- CMD ...    run CMD while holding the GPU lock, so no Comfier job runs alongside it
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import json
import logging
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from comfier_agent import __version__
from comfier_agent.config import comfier_home, default_config_path, load_config, save_config

LABEL = "com.comfier.agent"
LOG_PATH = Path.home() / "Library" / "Logs" / "comfier-agent.log"
SUBCOMMANDS = {"setup", "run", "service", "logs", "doctor", "pull", "lock", "version"}


def plist_path() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    # `python -m comfier_agent --comfyui-url ...` (no subcommand) still runs the agent, as it always has.
    if not argv or argv[0] not in SUBCOMMANDS and argv[0] not in ("-h", "--help"):
        argv = ["run", *argv]
    args = build_parser().parse_args(argv)
    return args.func(args) or 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="comfier-agent", description="Comfier agent")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="run the agent in the foreground")
    run.add_argument("--comfyui-url", dest="comfyui_url", help="where ComfyUI is, e.g. http://127.0.0.1:8188")
    run.add_argument("-v", "--verbose", action="store_true")
    run.set_defaults(func=cmd_run)

    setup = sub.add_parser("setup", help="save Comfier's URL and this server's key")
    setup.add_argument("--url", help="Comfier's URL")
    setup.add_argument("--key", help="this server's key from Comfier (cmf_...)")
    setup.add_argument("--name", help="server name shown in Comfier")
    setup.add_argument("--comfyui-url", help="ComfyUI's URL, or 'none' if this machine doesn't run ComfyUI")
    setup.add_argument("--engines", help="comma-separated: comfyui,mflux,mlx_video (default: detect)")
    setup.add_argument("--allow-insecure", action="store_true", help="allow an http Comfier URL (testing only)")
    setup.add_argument("--yes", "-y", action="store_true", help="don't ask; use flags and defaults")
    setup.set_defaults(func=cmd_setup)

    service = sub.add_parser("service", help="manage the launchd service (macOS)")
    service.add_argument("action", choices=["install", "uninstall", "start", "stop", "restart", "status"])
    service.set_defaults(func=cmd_service)

    logs = sub.add_parser("logs", help="show the service log")
    logs.add_argument("-f", "--follow", action="store_true")
    logs.add_argument("-n", "--lines", type=int, default=50)
    logs.set_defaults(func=cmd_logs)

    doctor = sub.add_parser("doctor", help="check the agent's setup")
    doctor.set_defaults(func=cmd_doctor)

    pull = sub.add_parser("pull", help="download an mflux model and check it runs (makes a small test image)")
    pull.add_argument("model", help="an mflux model name, e.g. z-image-turbo")
    pull.add_argument("--command", help="the mflux command to test it with (default: picked from the name)")
    pull.set_defaults(func=cmd_pull)

    lock = sub.add_parser("lock", help="run a command while holding the GPU lock")
    lock.add_argument("cmd", nargs=argparse.REMAINDER, help="the command, after --")
    lock.set_defaults(func=cmd_lock)

    version = sub.add_parser("version", help="print the agent version")
    version.set_defaults(func=lambda _args: print(__version__))
    return parser


# --- run ---------------------------------------------------------------------------------------------

def cmd_run(args) -> int:
    from comfier_agent.runtime import run_agent

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s [Comfier] %(levelname)s %(message)s")
    config = load_config(sidecar=True, overrides={"comfyui_url": args.comfyui_url} if args.comfyui_url else None)
    if not config.ok:
        logging.getLogger("comfier_agent").warning(config.idle_reason)
        return 1
    try:
        asyncio.run(run_agent(config, sidecar=True))
    except KeyboardInterrupt:
        pass
    return 0


# --- setup -------------------------------------------------------------------------------------------

def ask(prompt: str, default: str | None = None, *, secret: bool = False) -> str:
    suffix = f" [{default}]" if default else ""
    reader = getpass.getpass if secret else input
    answer = reader(f"{prompt}{suffix}: ").strip()
    return answer or (default or "")


def cmd_setup(args) -> int:
    from comfier_agent.engines import KNOWN, MLX_PACKAGES, installed

    config = load_config(sidecar=True)
    interactive = not args.yes and sys.stdin.isatty()
    url = args.url or (ask("Comfier URL", config.frontend_url or None) if interactive else config.frontend_url)
    key = args.key or (ask("Server key (from Servers → your server)", None, secret=True) if interactive else "")
    name = args.name or (ask("Server name", config.backend_name) if interactive else config.backend_name)

    detected = [n for n, pkg in MLX_PACKAGES.items() if installed(pkg)]
    comfyui_url = args.comfyui_url
    if comfyui_url is None and interactive:
        comfyui_url = ask("ComfyUI URL ('none' if this machine doesn't run ComfyUI)",
                          "none" if detected else config.comfyui_url)
    engines = args.engines
    if engines is None:
        engines = ",".join(([] if (comfyui_url or "").lower() == "none" else ["comfyui"]) + detected)
        if interactive:
            engines = ask(f"Engines ({', '.join(KNOWN)})", engines)

    if not url or not (key or config.api_key):
        print("Comfier's URL and this server's key are both needed.", file=sys.stderr)
        return 2
    if url.startswith("http://") and not (args.allow_insecure or config.allow_insecure):
        print("Comfier's URL must use https (add --allow-insecure only for local testing).", file=sys.stderr)
        return 2
    updates = {"frontend_url": url.rstrip("/"), "api_key": key or None, "backend_name": name,
               "engines": [e.strip() for e in engines.split(",") if e.strip()]}
    if comfyui_url and comfyui_url.lower() != "none":
        updates["comfyui_url"] = comfyui_url
    if args.allow_insecure:
        updates["allow_insecure"] = True
    config.config_path = config.config_path or default_config_path()
    save_config(config, updates)
    print(f"Saved {config.config_path}")
    reachable, detail = check_comfier(url)
    print(("✓ " if reachable else "✗ ") + detail)
    if sys.platform == "darwin":
        print("Next: comfier-agent service install")
    return 0 if reachable else 1


def check_comfier(url: str) -> tuple[bool, str]:
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}/up", timeout=10) as resp:
            return True, f"Comfier answered at {url} ({resp.status})"
    except urllib.error.HTTPError as exc:
        return exc.code < 500, f"Comfier answered at {url} ({exc.code})"
    except Exception as exc:  # noqa: BLE001 - any failure is the answer
        return False, f"Couldn't reach Comfier at {url}: {exc}"


# --- service (launchd) -------------------------------------------------------------------------------

def service_plist() -> dict:
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), "PYTHONUNBUFFERED": "1"}
    for name in ("COMFIER_HOME", "HF_HOME", "HF_TOKEN", "HF_ENDPOINT"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    return {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, "-m", "comfier_agent", "run"],
        "RunAtLoad": True,
        "KeepAlive": True,
        # Don't restart in a tight loop if it can't start (e.g. no key yet).
        "ThrottleInterval": 30,
        "ProcessType": "Interactive",
        "StandardOutPath": str(LOG_PATH),
        "StandardErrorPath": str(LOG_PATH),
        "EnvironmentVariables": env,
        "WorkingDirectory": str(comfier_home()),
    }


def launchctl(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True, check=check)


def domain() -> str:
    return f"gui/{os.getuid()}"


def service_loaded() -> bool:
    return launchctl("print", f"{domain()}/{LABEL}").returncode == 0


def cmd_service(args) -> int:
    if sys.platform != "darwin":
        print("The service commands use launchd, so they're for macOS. Elsewhere, run "
              "`comfier-agent run` under systemd or Docker.", file=sys.stderr)
        return 2
    path = plist_path()
    action = args.action
    if action == "install":
        if not load_config(sidecar=True).ok:
            print("Run `comfier-agent setup` first.", file=sys.stderr)
            return 1
        comfier_home().mkdir(parents=True, exist_ok=True)
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        if service_loaded():
            launchctl("bootout", f"{domain()}/{LABEL}")
        with path.open("wb") as f:
            plistlib.dump(service_plist(), f)
        result = launchctl("bootstrap", domain(), str(path))
        if result.returncode != 0:
            print(f"launchctl bootstrap failed: {result.stderr.strip()}", file=sys.stderr)
            return 1
        print(f"Installed and started. It starts at login; logs are in {LOG_PATH}")
    elif action == "uninstall":
        if service_loaded():
            launchctl("bootout", f"{domain()}/{LABEL}")
        path.unlink(missing_ok=True)
        print("Stopped and removed the service.")
    elif action in ("start", "restart"):
        if not path.exists():
            print("Not installed; run `comfier-agent service install`.", file=sys.stderr)
            return 1
        if not service_loaded():
            launchctl("bootstrap", domain(), str(path))
        else:
            launchctl("kickstart", "-k", f"{domain()}/{LABEL}")
        print("Started.")
    elif action == "stop":
        launchctl("bootout", f"{domain()}/{LABEL}")
        print("Stopped until the next login or `comfier-agent service start`.")
    elif action == "status":
        if not path.exists():
            print("Not installed.")
            return 3
        info = launchctl("print", f"{domain()}/{LABEL}")
        if info.returncode != 0:
            print("Installed, not running.")
            return 3
        state = next((line.split("=", 1)[1].strip() for line in info.stdout.splitlines()
                      if line.strip().startswith("state =")), "unknown")
        pid = next((line.split("=", 1)[1].strip() for line in info.stdout.splitlines()
                    if line.strip().startswith("pid =")), None)
        print(f"Installed, {state}" + (f" (pid {pid})" if pid else ""))
    return 0


def cmd_logs(args) -> int:
    if not LOG_PATH.exists():
        print(f"No log yet at {LOG_PATH}", file=sys.stderr)
        return 1
    cmd = ["tail", "-n", str(args.lines)] + (["-F"] if args.follow else []) + [str(LOG_PATH)]
    try:
        return subprocess.call(cmd)
    except KeyboardInterrupt:
        return 0


# --- doctor ------------------------------------------------------------------------------------------

def cmd_doctor(_args) -> int:
    from comfier_agent.engines import MLX_PACKAGES, engine_names, installed
    from comfier_agent.resources import _host_ram_bytes

    problems = 0

    def report(ok: bool | None, text: str) -> None:
        nonlocal problems
        mark = {True: "✓", False: "✗", None: "·"}[ok]
        problems += ok is False
        print(f"{mark} {text}")

    report(True, f"comfier-agent {__version__}, Python {platform.python_version()} ({sys.executable})")
    apple = sys.platform == "darwin" and platform.machine() == "arm64"
    ram = _host_ram_bytes()[0]
    report(None, f"{platform.platform()}" + (f", {ram / 2**30:.0f} GB memory" if ram else ""))
    if not apple:
        report(None, "Not an Apple Silicon Mac: mflux and mlx-video won't be offered")

    config = load_config(sidecar=True)
    report(config.ok, f"Settings in {config.config_path}" + ("" if config.ok else f": {config.idle_reason}"))
    if config.frontend_url:
        report(*check_comfier(config.frontend_url))

    names = engine_names(config)
    report(bool(names), f"Engines: {', '.join(names) or 'none'}")
    for name, package in MLX_PACKAGES.items():
        if name in names:
            ok = installed(package)
            version = package_version(package) if ok else None
            report(ok, f"{name}: " + (f"{package} {version}" if ok else f"the {package} package isn't installed"))
    if "comfyui" in names:
        report(*check_comfyui(config.comfyui_url))

    disk = shutil.disk_usage(comfier_home() if comfier_home().exists() else Path.home())
    low = disk.free < config.min_free_disk_gb * 2**30
    report(not low, f"{disk.free / 2**30:.0f} GB free disk")
    if sys.platform == "darwin":
        if plist_path().exists():
            report(service_loaded(), "Service installed" + (" and running" if service_loaded() else ", not running"))
        else:
            report(None, "Service not installed (comfier-agent service install)")
    print("No problems found." if not problems else f"{problems} problem(s).")
    return 1 if problems else 0


def package_version(package: str) -> str | None:
    import importlib.metadata

    try:
        return importlib.metadata.version(package.replace("_", "-"))
    except importlib.metadata.PackageNotFoundError:
        return None


def check_comfyui(url: str) -> tuple[bool, str]:
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}/system_stats", timeout=5) as resp:
            version = json.load(resp).get("system", {}).get("comfyui_version")
            return True, f"ComfyUI {version or ''} at {url}".replace("  ", " ")
    except Exception as exc:  # noqa: BLE001
        return False, f"ComfyUI isn't answering at {url} ({exc}). Remove comfyui from the engines if this " \
                      "machine doesn't run it."


# --- pull, lock --------------------------------------------------------------------------------------

def cmd_pull(args) -> int:
    from comfier_agent.engines import installed

    if not installed("mflux"):
        print("mflux isn't installed (pip install 'comfier-agent[mflux]').", file=sys.stderr)
        return 1
    # The test image uses the GPU like a job does, so it takes the lock like one.
    return run_locked([sys.executable, "-m", "comfier_agent.workers.mflux_worker", "--pull", args.model,
                       *([args.command] if args.command else [])])


def cmd_lock(args) -> int:
    cmd = args.cmd[1:] if args.cmd[:1] == ["--"] else args.cmd
    if not cmd:
        print("usage: comfier-agent lock -- COMMAND [ARGS...]", file=sys.stderr)
        return 2
    return run_locked(cmd)


def run_locked(cmd: list[str]) -> int:
    """Run cmd holding the GPU lock, waiting for a running Comfier job to finish first."""
    from comfier_agent.gpu_lock import GpuLock

    lock = GpuLock(load_config(sidecar=True).gpu_lock_path)
    if not lock.acquire():
        print("Waiting for the Comfier job using the GPU to finish…", file=sys.stderr)
        lock.acquire(wait=True)
    try:
        return subprocess.call(cmd)
    except KeyboardInterrupt:
        return 130
    finally:
        lock.release()
