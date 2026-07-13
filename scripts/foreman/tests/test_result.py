"""Result-contract validation: the agent→foreman handoff channel."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from foreman import backend as backend_mod

VALID = {
    "schema": 1,
    "status": "completed",
    "summary": "Did the thing.",
    "handoff": "New API at x().",
    "human_tasks": ["verify dashboard"],
    "proposed_pr_title": "feat(x): do the thing",
    "ac_test_map": [
        {"criterion": "parses config [CI]", "tests": ["tests/test_x.py::test_a"]}
    ],
    "blocked_question": None,
}


class ResultContract(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.run_dir = base / "run"
        self.worktree = base / "wt"
        self.run_dir.mkdir()
        self.worktree.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, data) -> None:
        (self.run_dir / "result.json").write_text(json.dumps(data), encoding="utf-8")

    def test_valid_completed(self):
        self.write(VALID)
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertEqual(errors, [])
        self.assertEqual(contract.status, "completed")
        self.assertEqual(contract.human_tasks, ["verify dashboard"])

    def test_missing_file_without_blocked_md_is_an_error(self):
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertIsNone(contract)
        self.assertTrue(errors)

    def test_blocked_md_fallback(self):
        (self.worktree / "BLOCKED.md").write_text("Which auth flow?", encoding="utf-8")
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertEqual(errors, [])
        self.assertEqual(contract.status, "blocked")
        self.assertEqual(contract.blocked_question, "Which auth flow?")

    def test_invalid_json(self):
        (self.run_dir / "result.json").write_text("{nope", encoding="utf-8")
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertIsNone(contract)
        self.assertTrue(any("valid JSON" in e for e in errors))

    def test_completed_requires_summary_and_ac_map(self):
        data = dict(VALID, summary="", ac_test_map=[])
        self.write(data)
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertIsNone(contract)
        self.assertTrue(any("summary" in e for e in errors))
        self.assertTrue(any("ac_test_map" in e for e in errors))

    def test_blocked_requires_question(self):
        self.write({"schema": 1, "status": "blocked"})
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertIsNone(contract)
        self.assertTrue(errors)

    def test_bad_schema_and_status(self):
        self.write({"schema": 2, "status": "done?"})
        contract, errors = backend_mod.read_result(self.run_dir, self.worktree)
        self.assertIsNone(contract)
        self.assertTrue(any("schema" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
