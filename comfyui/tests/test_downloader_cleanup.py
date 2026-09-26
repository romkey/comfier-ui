"""Tests for Comfier cleanup helpers. Run with: python3 -m unittest discover -s comfyui/tests"""

import os
import sys
import tempfile
import types
import unittest

ROOTS = tempfile.mkdtemp()
INPUT = os.path.join(ROOTS, "input")
OUTPUT = os.path.join(ROOTS, "output")
TEMP = os.path.join(ROOTS, "temp")
for folder in (INPUT, OUTPUT, TEMP):
    os.makedirs(folder)

folder_paths = types.ModuleType("folder_paths")
folder_paths.get_directory_by_type = lambda name: {"input": INPUT, "output": OUTPUT, "temp": TEMP}.get(name)
sys.modules["folder_paths"] = folder_paths
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from comfier_downloader import cleanup  # noqa: E402


class CleanupTest(unittest.TestCase):
    def write(self, folder, *parts):
        path = os.path.join(folder, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(b"data")
        return path

    def test_deletes_output_and_temp_files(self):
        output = self.write(OUTPUT, "comfier_00001_.png")
        preview = self.write(TEMP, "preview.png")

        self.assertTrue(cleanup.delete_file("comfier_00001_.png", file_type="output"))
        self.assertTrue(cleanup.delete_file("preview.png", file_type="temp"))

        self.assertFalse(os.path.exists(output))
        self.assertFalse(os.path.exists(preview))

    def test_deletes_uploaded_input_images_with_subfolders(self):
        uploaded = self.write(INPUT, "comfier", "in.png")

        self.assertTrue(cleanup.delete_input_image("comfier/in.png"))
        self.assertFalse(os.path.exists(uploaded))

    def test_refuses_paths_outside_the_folder(self):
        with self.assertRaises(ValueError):
            cleanup.delete_file("evil.png", subfolder="../outside", file_type="output")


if __name__ == "__main__":
    unittest.main()
