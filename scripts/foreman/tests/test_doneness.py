"""The hardened doneness truth table (spec amendment A3)."""

from __future__ import annotations

import unittest

from foreman.config import Config
from foreman.graph import dependency_satisfied
from foreman.inputs import UnitInputs
from foreman.tests.fakes import issue_json, make_github, pr_json


def cfg_with_bot() -> Config:
    return Config(expected_login="bot")


class ExternalDependencies(unittest.TestCase):
    def test_open_issue_is_unsatisfied(self):
        gh, runner = make_github(cfg_with_bot())
        runner.when(["issue", "view", "5"], issue_json(5, state="OPEN"))
        done = dependency_satisfied(gh, cfg_with_bot(), 5)
        self.assertFalse(done.satisfied)
        self.assertEqual(done.how, "open")

    def test_closed_completed_counts_and_says_how(self):
        gh, runner = make_github(cfg_with_bot())
        runner.when(
            ["issue", "view", "5"],
            issue_json(5, state="CLOSED", state_reason="completed"),
        )
        done = dependency_satisfied(gh, cfg_with_bot(), 5)
        self.assertTrue(done.satisfied)
        self.assertIn("external", done.how)

    def test_not_planned_blocks_by_default(self):
        gh, runner = make_github(cfg_with_bot())
        runner.when(
            ["issue", "view", "5"],
            issue_json(5, state="CLOSED", state_reason="not_planned"),
        )
        done = dependency_satisfied(gh, cfg_with_bot(), 5)
        self.assertFalse(done.satisfied)
        self.assertTrue(done.warnings)

    def test_not_planned_allowed_by_config(self):
        cfg = Config(expected_login="bot", allow_not_planned=True)
        gh, runner = make_github(cfg)
        runner.when(
            ["issue", "view", "5"],
            issue_json(5, state="CLOSED", state_reason="not_planned"),
        )
        self.assertTrue(dependency_satisfied(gh, cfg, 5).satisfied)

    def test_human_override_wins_even_when_open(self):
        gh, runner = make_github(cfg_with_bot())
        runner.when(["issue", "view", "5"], issue_json(5, state="OPEN"))
        inputs = UnitInputs(satisfied_override=True)
        done = dependency_satisfied(gh, cfg_with_bot(), 5, inputs=inputs)
        self.assertTrue(done.satisfied)
        self.assertIn("override", done.how)


class ForemanManagedDependencies(unittest.TestCase):
    def _gh(self, *, pr_kwargs: dict):
        cfg = cfg_with_bot()
        gh, runner = make_github(cfg)
        runner.when(
            ["issue", "view", "7"],
            issue_json(7, state="CLOSED", state_reason="completed", closed_by_prs=[90]),
        )
        runner.when(["pr", "view", "90"], pr_json(90, unit=7, **pr_kwargs))
        return gh, cfg

    def test_full_chain_satisfies(self):
        gh, cfg = self._gh(pr_kwargs={})
        done = dependency_satisfied(gh, cfg, 7)
        self.assertTrue(done.satisfied)
        self.assertIn("PR #90 merged into main", done.how)

    def test_unmerged_marker_pr_fails_loud(self):
        gh, cfg = self._gh(pr_kwargs={"merged": False})
        done = dependency_satisfied(gh, cfg, 7)
        self.assertFalse(done.satisfied)
        self.assertTrue(done.warnings)

    def test_wrong_base_branch_fails(self):
        gh, cfg = self._gh(pr_kwargs={"base": "develop"})
        self.assertFalse(dependency_satisfied(gh, cfg, 7).satisfied)

    def test_wrong_author_fails(self):
        gh, cfg = self._gh(pr_kwargs={"author": "impostor"})
        self.assertFalse(dependency_satisfied(gh, cfg, 7).satisfied)

    def test_non_foreman_branch_fails(self):
        gh, cfg = self._gh(pr_kwargs={"head": "feat/7-manual"})
        self.assertFalse(dependency_satisfied(gh, cfg, 7).satisfied)

    def test_external_marker_treats_issue_as_external(self):
        gh, cfg = self._gh(pr_kwargs={"merged": False})
        inputs = UnitInputs(external=True)
        done = dependency_satisfied(gh, cfg, 7, inputs=inputs)
        self.assertTrue(done.satisfied)
        self.assertIn("external", done.how)


if __name__ == "__main__":
    unittest.main()
