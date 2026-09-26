"""Comfier model downloader for ComfyUI.

A node that downloads one model file into one of ComfyUI's models folders. Comfier queues it as a
one-node workflow through the normal /prompt API, so installing models needs no extra endpoints and
no ComfyUI-Manager configuration.

Install: copy this folder into ComfyUI/custom_nodes/ and restart ComfyUI.
Gated or members-only files: set HF_TOKEN and/or CIVITAI_TOKEN in ComfyUI's environment.
"""

import os
import urllib.error
import urllib.parse
import urllib.request

import folder_paths

try:
    from comfy.utils import ProgressBar
except ImportError:  # outside ComfyUI (tests)
    ProgressBar = None

CHUNK_SIZE = 8 * 1024 * 1024
TIMEOUT_SECONDS = 60
USER_AGENT = "comfier-downloader/1.0"
# Tokens are only ever sent to the site they belong to.
TOKEN_ENV = {"huggingface.co": "HF_TOKEN", "civitai.com": "CIVITAI_TOKEN"}


class _DropAuthOnHostChange(urllib.request.HTTPRedirectHandler):
    """Hugging Face and CivitAI redirect to signed CDN URLs that reject extra credentials,
    so the token isn't carried across a redirect to a different host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and _host(newurl) != _host(req.full_url):
            new.remove_header("Authorization")
        return new


def _host(url):
    return (urllib.parse.urlparse(url).hostname or "").lower()


def token_for(host):
    for domain, variable in TOKEN_ENV.items():
        if host == domain or host.endswith("." + domain):
            return os.environ.get(variable) or None
    return None


def resolve_target(directory, filename):
    """The absolute path to save to, refusing anything outside the chosen models folder."""
    directory = getattr(folder_paths, "map_legacy", lambda name: name)(directory.strip())
    if directory not in folder_paths.folder_names_and_paths:
        raise ValueError(f"ComfyUI has no models folder called {directory!r}")

    name = filename.strip().replace("\\", "/")
    parts = name.split("/")
    if not name or name.startswith("/") or any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"{filename!r} isn't a valid file name")

    extensions = folder_paths.folder_names_and_paths[directory][1]
    if extensions and os.path.splitext(name)[1].lower() not in extensions:
        raise ValueError(f"{directory} only accepts {', '.join(sorted(extensions))} files")

    base = os.path.realpath(folder_paths.get_folder_paths(directory)[0])
    target = os.path.realpath(os.path.join(base, *parts))
    if os.path.commonpath([base, target]) != base:
        raise ValueError(f"{filename!r} points outside the {directory} folder")
    return target


def fetch(url, target):
    """Streams url to target via a .part file, so a half-finished download is never picked up."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    token = token_for(_host(url))
    if token:
        request.add_header("Authorization", f"Bearer {token}")

    os.makedirs(os.path.dirname(target), exist_ok=True)
    partial = target + ".part"
    opener = urllib.request.build_opener(_DropAuthOnHostChange)
    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response, open(partial, "wb") as out:
            if response.headers.get_content_type() == "text/html":
                raise RuntimeError(
                    f"{url} is a web page, not a model file. Use the direct download link "
                    "(on Hugging Face, /resolve/ rather than /blob/)."
                )
            total = int(response.headers.get("Content-Length") or 0)
            progress = ProgressBar(total) if ProgressBar and total else None
            done = 0
            while chunk := response.read(CHUNK_SIZE):
                out.write(chunk)
                done += len(chunk)
                if progress:
                    progress.update_absolute(done, total)
        if total and done != total:
            raise IOError(f"The download stopped early ({done} of {total} bytes)")
        os.replace(partial, target)
        return done
    except urllib.error.HTTPError as error:
        error.close()
        hint = " Set HF_TOKEN or CIVITAI_TOKEN for ComfyUI if the file needs a login." if error.code in (401, 403) else ""
        raise RuntimeError(f"{url} returned HTTP {error.code}.{hint}") from error
    finally:
        if os.path.exists(partial):
            os.remove(partial)


class ComfierModelDownload:
    CATEGORY = "comfier"
    DESCRIPTION = "Downloads a model file into a ComfyUI models folder, unless it's already there."
    FUNCTION = "download"
    RETURN_TYPES = ()
    OUTPUT_NODE = True

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "url": ("STRING", {"default": "", "tooltip": "Direct link to the file"}),
                "directory": ("STRING", {"default": "checkpoints", "tooltip": "Models folder, e.g. vae or loras"}),
                "filename": ("STRING", {"default": "", "tooltip": "Name to save it as inside that folder"}),
            }
        }

    @classmethod
    def IS_CHANGED(cls, **_inputs):
        # Never reuse a cached result: the file may have been deleted since the last run.
        return float("nan")

    def download(self, url, directory, filename):
        target = resolve_target(directory, filename)
        if os.path.exists(target):
            return {"ui": {"text": [f"{filename} is already installed"]}}

        url = url.strip()
        if urllib.parse.urlparse(url).scheme not in ("http", "https") or not _host(url):
            raise ValueError("The download link must be an http(s) URL")

        size = fetch(url, target)
        return {"ui": {"text": [f"Downloaded {filename} ({size / 1_000_000:.1f} MB)"]}}


NODE_CLASS_MAPPINGS = {"ComfierModelDownload": ComfierModelDownload}
NODE_DISPLAY_NAME_MAPPINGS = {"ComfierModelDownload": "Download model (Comfier)"}

from .cleanup import register_routes

register_routes()
