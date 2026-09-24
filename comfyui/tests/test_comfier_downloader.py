"""Tests for the Comfier downloader node. Run with: python3 -m unittest discover -s comfyui/tests"""

import http.server
import os
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

MODELS = tempfile.mkdtemp()
EXTENSIONS = {".safetensors", ".ckpt"}

folder_paths = types.ModuleType("folder_paths")
folder_paths.folder_names_and_paths = {
    "checkpoints": ([os.path.join(MODELS, "checkpoints")], EXTENSIONS),
    "vae": ([os.path.join(MODELS, "vae")], EXTENSIONS),
}
folder_paths.get_folder_paths = lambda name: folder_paths.folder_names_and_paths[name][0]
sys.modules["folder_paths"] = folder_paths
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import comfier_downloader  # noqa: E402

PAYLOAD = b"model-bytes" * 1000


class Handler(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        Handler.seen.append((self.headers["Host"].split(":")[0], self.path, self.headers.get("Authorization")))
        port = self.server.server_address[1]
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{port}/file")
            self.end_headers()
        elif self.path == "/file":
            self.send_response(200)
            self.send_header("Content-Length", str(len(PAYLOAD)))
            self.end_headers()
            self.wfile.write(PAYLOAD)
        elif self.path == "/page":
            body = b"<!doctype html><html><body>model card</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/short":
            self.send_response(200)
            self.send_header("Content-Length", str(len(PAYLOAD)))
            self.end_headers()
            self.wfile.write(PAYLOAD[:100])
        else:
            self.send_response(401)
            self.end_headers()

    def log_message(self, *_args):
        pass


class DownloaderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Handler.seen.clear()
        self.node = comfier_downloader.ComfierModelDownload()

    def download(self, path, filename, directory="checkpoints"):
        return self.node.download(self.base + path, directory, filename)

    def target(self, *parts):
        return os.path.join(MODELS, *parts)

    def test_downloads_into_the_models_folder(self):
        result = self.download("/file", "sd15.safetensors")

        with open(self.target("checkpoints", "sd15.safetensors"), "rb") as saved:
            self.assertEqual(PAYLOAD, saved.read())
        self.assertIn("Downloaded sd15.safetensors", result["ui"]["text"][0])
        self.assertFalse(os.path.exists(self.target("checkpoints", "sd15.safetensors.part")))

    def test_creates_subfolders(self):
        self.download("/file", "sdxl/base.safetensors", directory="vae")

        self.assertTrue(os.path.exists(self.target("vae", "sdxl", "base.safetensors")))

    def test_skips_files_that_are_already_there(self):
        self.download("/file", "existing.safetensors")
        Handler.seen.clear()

        result = self.download("/file", "existing.safetensors")

        self.assertEqual([], Handler.seen)
        self.assertIn("already installed", result["ui"]["text"][0])

    def test_refuses_names_that_escape_the_folder(self):
        for name in ["../evil.safetensors", "/etc/evil.safetensors", "a/../../evil.safetensors", ""]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.download("/file", name)
        self.assertEqual([], Handler.seen)

    def test_refuses_unknown_folders_and_extensions(self):
        with self.assertRaisesRegex(ValueError, "no models folder"):
            self.download("/file", "x.safetensors", directory="custom_nodes")
        with self.assertRaisesRegex(ValueError, "only accepts"):
            self.download("/file", "payload.py")

    def test_refuses_non_http_links(self):
        with self.assertRaisesRegex(ValueError, "http"):
            self.node.download("file:///etc/passwd", "checkpoints", "passwd.safetensors")

    def test_sends_the_token_only_to_its_own_host(self):
        with mock.patch.dict(comfier_downloader.TOKEN_ENV, {"127.0.0.1": "TEST_TOKEN"}), \
             mock.patch.dict(os.environ, {"TEST_TOKEN": "secret"}):
            self.download("/redirect", "gated.safetensors")

        self.assertEqual(
            [("127.0.0.1", "/redirect", "Bearer secret"), ("localhost", "/file", None)],
            Handler.seen,
        )

    def test_explains_login_failures(self):
        with self.assertRaisesRegex(RuntimeError, "HTTP 401.*HF_TOKEN"):
            self.download("/private", "private.safetensors")
        self.assertFalse(os.path.exists(self.target("checkpoints", "private.safetensors.part")))

    def test_discards_truncated_downloads(self):
        with self.assertRaises(Exception):
            self.download("/short", "short.safetensors")

        self.assertFalse(os.path.exists(self.target("checkpoints", "short.safetensors")))
        self.assertFalse(os.path.exists(self.target("checkpoints", "short.safetensors.part")))

    def test_refuses_web_pages(self):
        with self.assertRaisesRegex(RuntimeError, "web page.*/resolve/"):
            self.download("/page", "card.safetensors")

        self.assertFalse(os.path.exists(self.target("checkpoints", "card.safetensors")))
        self.assertFalse(os.path.exists(self.target("checkpoints", "card.safetensors.part")))

    def test_token_matching_includes_subdomains_only(self):
        with mock.patch.dict(os.environ, {"HF_TOKEN": "hf"}):
            self.assertEqual("hf", comfier_downloader.token_for("huggingface.co"))
            self.assertEqual("hf", comfier_downloader.token_for("cdn.huggingface.co"))
            self.assertIsNone(comfier_downloader.token_for("nothuggingface.co"))


if __name__ == "__main__":
    unittest.main()
