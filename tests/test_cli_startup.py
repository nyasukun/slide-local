"""Narrow source regressions for UI startup, which is not in the core test binary."""
from pathlib import Path
import unittest


class CLIStartupTests(unittest.TestCase):
    def test_startup_does_not_launch_ollama_gui(self):
        source = (Path(__file__).resolve().parents[1] / "NativeApp.swift").read_text()
        startup = source.split("func start() async {", 1)[1].split("func refreshQueue()", 1)[0]
        self.assertNotIn('["-gj", "-a", "Ollama"]', startup)

    def test_disconnected_user_gets_service_recovery_instruction(self):
        source = (Path(__file__).resolve().parents[1] / "NativeApp.swift").read_text()
        refresh = source.split("func refreshModels() async {", 1)[1].split("func refreshQueue()", 1)[0]
        self.assertIn("brew services start ollama", refresh)
        self.assertIn("モデルを再読み込み", refresh)


if __name__ == "__main__":
    unittest.main()
