"""Resolve a real executable without starting Ollama or changing services."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

try:
    from ollama_cli import resolve_ollama_binary
except ImportError:
    resolve_ollama_binary = None


class OllamaCLITests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(resolve_ollama_binary, "CLI resolver is not implemented")
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()

    def executable(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        return str(path)

    def test_explicit_path_overrides_path_search(self):
        explicit = self.executable("custom/ollama")
        self.executable("bin/ollama")
        self.assertEqual(resolve_ollama_binary({
            "OLLAMA_BIN": explicit, "PATH": str(self.root / "bin")
        }), explicit)

    def test_invalid_explicit_path_does_not_fall_back(self):
        self.executable("bin/ollama")
        for invalid in (str(self.root / "missing"), str(self.root), ""):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(RuntimeError, "OLLAMA_BIN"):
                resolve_ollama_binary({"OLLAMA_BIN": invalid, "PATH": str(self.root / "bin")})

    def test_non_executable_explicit_file_is_rejected(self):
        path = self.root / "not-executable"
        path.write_text("not executable")
        with self.assertRaisesRegex(RuntimeError, "OLLAMA_BIN"):
            resolve_ollama_binary({"OLLAMA_BIN": str(path), "PATH": ""})

    def test_cli_on_path_is_used_before_gui(self):
        cli = self.executable("bin/ollama")
        self.assertEqual(resolve_ollama_binary({"PATH": str(self.root / "bin")}), cli)

    def test_gui_fallback_when_path_empty(self):
        cli = self.executable("Ollama.app/Contents/Resources/ollama")
        with patch("ollama_cli.GUI_BINARY", cli):
            self.assertEqual(resolve_ollama_binary({"PATH": ""}), cli)

    def test_missing_all_candidates_explains_recovery(self):
        with patch("ollama_cli.GUI_BINARY", str(self.root / "missing")):
            with self.assertRaisesRegex(RuntimeError, "brew install ollama"):
                resolve_ollama_binary({"PATH": ""})

    def test_explicit_path_with_spaces_and_relative_path(self):
        cli = self.executable("space dir/ollama")
        relative = os.path.relpath(cli)
        self.assertEqual(resolve_ollama_binary({"OLLAMA_BIN": relative, "PATH": ""}), cli)


if __name__ == "__main__":
    unittest.main()
