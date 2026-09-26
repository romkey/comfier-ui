"""HTTP cleanup routes for Comfier backends."""

import os

ALLOWED_TYPES = frozenset({"input", "output", "temp"})


def delete_file(filename, subfolder="", file_type="output"):
    """Removes one file from an input/output/temp folder, refusing paths outside it."""
    import folder_paths

    file_type = file_type if file_type in ALLOWED_TYPES else "output"
    base = folder_paths.get_directory_by_type(file_type)
    if not base:
        raise ValueError(f"ComfyUI has no {file_type!r} folder")

    name = os.path.basename(str(filename).replace("\\", "/"))
    if not name or name in {".", ".."}:
        raise ValueError(f"{filename!r} isn't a valid file name")

    directory = base
    subfolder = str(subfolder or "").replace("\\", "/").strip("/")
    if subfolder:
        directory = os.path.join(base, subfolder)
        if os.path.commonpath([os.path.abspath(directory), os.path.abspath(base)]) != os.path.abspath(base):
            raise ValueError(f"{subfolder!r} points outside the {file_type} folder")

    path = os.path.join(directory, name)
    if os.path.isfile(path):
        os.remove(path)
        return True
    return False


def delete_input_image(name):
    """Removes an uploaded input image, including optional subfolder/name paths."""
    cleaned = str(name).strip().replace("\\", "/")
    if not cleaned:
        return False

    subfolder, filename = cleaned.rsplit("/", 1) if "/" in cleaned else ("", cleaned)
    return delete_file(filename, subfolder=subfolder, file_type="input")


def register_routes():
    try:
        from aiohttp import web
        from server import PromptServer
    except ImportError:
        return

    routes = PromptServer.instance.routes

    @routes.post("/comfier/cleanup")
    async def comfier_cleanup(request):
        data = await request.json()
        deleted = []
        skipped = []

        for file_desc in data.get("files") or []:
            if not isinstance(file_desc, dict):
                continue
            filename = file_desc.get("filename")
            if not filename:
                continue
            if delete_file(filename, file_desc.get("subfolder", ""), file_desc.get("type", "output")):
                deleted.append(filename)
            else:
                skipped.append(filename)

        input_image = data.get("input_image")
        if input_image:
            if delete_input_image(input_image):
                deleted.append(input_image)
            else:
                skipped.append(input_image)

        prompt_id = data.get("prompt_id")
        if prompt_id:
            PromptServer.instance.prompt_queue.delete_history_item(prompt_id)

        return web.json_response({"deleted": deleted, "skipped": skipped})
