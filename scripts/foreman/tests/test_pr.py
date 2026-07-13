"""PR assembly: markers, Conventional-Commit titles, Closes vs Refs when
human-only tasks exist."""

from __future__ import annotations

import unittest

from foreman import pr as pr_mod
from foreman.backend import ResultContract
from foreman.config import Config
from foreman.graph import MARKER_RE, Unit
from foreman.inputs import UnitInputs
from foreman.tests.fakes import issue_json


def unit(subs=None) -> Unit:
    u = Unit(
        number=42,
        title="Add the widget",
        state="OPEN",
        state_reason=None,
        body="## Acceptance Criteria\n\n- works [CI]\n",
        url="",
        labels=[],
        issue_type=None,
        milestone=None,
        parent=None,
        sub_issues=subs or [],
    )
    u.inputs = UnitInputs(armed=True, commit_type="feat")
    return u


def contract(**kwargs) -> ResultContract:
    base = dict(
        status="completed",
        summary="Widget added.",
        handoff="Widget API: w().",
        proposed_pr_title="feat(widget): add the widget",
        ac_test_map=[{"criterion": "works [CI]", "tests": ["t::a"]}],
    )
    base.update(kwargs)
    return ResultContract(**base)


class Titles(unittest.TestCase):
    def test_conventional_proposal_kept_with_type_coerced(self):
        u = unit()
        u.inputs.commit_type = "fix"
        title = pr_mod.pr_title(Config(), u, contract())
        self.assertEqual(title, "fix(widget): add the widget")

    def test_non_conventional_proposal_regenerated(self):
        title = pr_mod.pr_title(
            Config(), unit(), contract(proposed_pr_title="Adds widget!!")
        )
        self.assertEqual(title, "feat: Add the widget")

    def test_length_capped(self):
        long = contract(proposed_pr_title="feat: " + "x" * 200)
        self.assertLessEqual(len(pr_mod.pr_title(Config(), unit(), long)), 100)


class Bodies(unittest.TestCase):
    def body(self, *, human_tasks=None, subs=None):
        return pr_mod.pr_body(
            Config(),
            unit(subs=subs),
            contract(),
            human_tasks=human_tasks or [],
            spec_hash_hex="abc123",
            base_sha="def456",
        )

    def test_marker_is_parseable(self):
        match = MARKER_RE.search(self.body())
        self.assertIsNotNone(match)
        self.assertEqual(int(match.group("number")), 42)

    def test_closes_parent_and_open_subs(self):
        subs = [issue_json(43), issue_json(44, state="CLOSED")]
        body = self.body(subs=subs)
        self.assertIn("Closes #42", body)
        self.assertIn("Closes #43", body)
        self.assertNotIn("Closes #44", body)

    def test_human_tasks_switch_closes_to_refs(self):
        body = self.body(human_tasks=["rotate credential"])
        self.assertIn("Refs #42", body)
        self.assertNotIn("Closes #42", body)
        self.assertIn("rotate credential", body)

    def test_handoff_and_test_evidence_present(self):
        body = self.body()
        self.assertIn("## Handoff", body)
        self.assertIn("Widget API", body)
        self.assertIn("works [CI]", body)
        self.assertIn("`t::a`", body)
        self.assertIn("foreman never merges", body)


if __name__ == "__main__":
    unittest.main()
