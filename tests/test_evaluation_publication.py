"""Published evaluation artifacts must omit the withheld user-provided case."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "docs/model-evaluations"


class EvaluationPublicationTests(unittest.TestCase):
    def test_baselines_omit_private_case_and_disclose_public_counts(self):
        data = json.loads((ROOT / "2026-11-17-short-english-results.json").read_text())
        self.assertNotIn("01", [row["id"] for row in data["cases"]])
        self.assertEqual(len(data["cases"]), 47)
        for model in data["models"].values():
            self.assertNotIn("01", [row["id"] for row in model["results"]])
            self.assertEqual(len(model["results"]), 47)
            self.assertEqual(model["statistics"]["cases"], 48)  # Original tested count.
        self.assertEqual(data["publication"]["withheld_case_ids"], ["01"])
        self.assertNotIn("reported_title", data["gemma_review"])

    def test_app_outputs_omit_private_case_and_disclose_public_counts(self):
        data = json.loads((ROOT / "2026-11-17-gemma-app-integration.json").read_text())
        self.assertNotIn("01", [row["id"] for row in data["short_outputs"]])
        self.assertEqual(len(data["short_outputs"]), 52)
        self.assertEqual(data["publication"]["withheld_case_ids"], ["01"])


if __name__ == "__main__":
    unittest.main()
