"""Arming matrix: explicit approval, backend selection, holds, dual-source
fail-loud, and commit-type resolution (native issue type vs type: label)."""

from __future__ import annotations

import unittest

from foreman import inputs as inputs_mod
from foreman.config import Config
from foreman.tests.fakes import issue_json, make_github


class ArmingLabels(unittest.TestCase):
    def resolve(self, labels, *, cfg=None, issue_type=None):
        cfg = cfg or Config()
        gh, _runner = make_github(cfg)
        issue = issue_json(1, labels=labels, issue_type=issue_type)
        return inputs_mod.resolve(gh, cfg, issue, "labels")

    def test_unlabeled_issue_is_not_armed_under_strict_default(self):
        out = self.resolve([])
        self.assertFalse(out.armed)
        self.assertTrue(out.warnings)

    def test_approved_label_arms_with_default_backend(self):
        out = self.resolve(["foreman:approved"])
        self.assertTrue(out.armed)
        self.assertIsNone(out.backend)

    def test_backend_label_arms_and_selects(self):
        out = self.resolve(["foreman:claude"])
        self.assertTrue(out.armed)
        self.assertEqual(out.backend, "claude")

    def test_hold_beats_approval(self):
        out = self.resolve(["foreman:claude", "foreman:hold"])
        self.assertFalse(out.armed)
        self.assertTrue(out.hold)

    def test_conflicting_backends_fail_loud(self):
        out = self.resolve(["foreman:claude", "foreman:mock"])
        self.assertTrue(out.errors)

    def test_default_armed_mode_arms_without_labels(self):
        out = self.resolve([], cfg=Config(require_approval=False))
        self.assertTrue(out.armed)

    def test_default_armed_mode_still_honors_hold(self):
        out = self.resolve(["foreman:hold"], cfg=Config(require_approval=False))
        self.assertFalse(out.armed)


class FieldsMode(unittest.TestCase):
    def test_field_values_arm_and_override(self):
        cfg = Config()
        gh, runner = make_github(cfg)
        runner.when(
            ["api", "repos/owner/repo/issues/2/field-values"],
            [
                {"field": {"name": "foreman"}, "value": {"name": "claude"}},
                {"name": "foreman-budget-usd", "value": 35},
                {"name": "foreman-timeout-min", "value": 120},
            ],
        )
        out = inputs_mod.resolve(gh, cfg, issue_json(2), "fields")
        self.assertTrue(out.armed)
        self.assertEqual(out.backend, "claude")
        self.assertEqual(out.budget_usd, 35.0)
        self.assertEqual(out.timeout_min, 120)

    def test_dual_source_fails_loud_in_fields_mode(self):
        cfg = Config()
        gh, runner = make_github(cfg)
        runner.when(["api", "repos/owner/repo/issues/2/field-values"], [])
        out = inputs_mod.resolve(
            gh, cfg, issue_json(2, labels=["foreman:hold"]), "fields"
        )
        self.assertTrue(any("dual-sourced" in e for e in out.errors))

    def test_detect_mode_explicit_config_wins(self):
        cfg = Config(inputs="labels")
        gh, _runner = make_github(cfg)
        self.assertEqual(inputs_mod.detect_mode(gh, cfg), "labels")

    def test_detect_mode_auto_probes_org_fields(self):
        cfg = Config(inputs="auto")
        gh, runner = make_github(cfg)
        runner.when(["api", "orgs/owner/issue-fields"], "[]")
        self.assertEqual(inputs_mod.detect_mode(gh, cfg), "fields")

    def test_detect_mode_auto_falls_back_to_labels(self):
        cfg = Config(inputs="auto")
        gh, runner = make_github(cfg)
        runner.when(["api", "orgs/owner/issue-fields"], "", rc=1)
        self.assertEqual(inputs_mod.detect_mode(gh, cfg), "labels")


class CommitType(unittest.TestCase):
    def resolve(self, *, labels=None, issue_type=None):
        cfg = Config()
        gh, _runner = make_github(cfg)
        issue = issue_json(3, labels=labels or [], issue_type=issue_type)
        return inputs_mod.resolve(gh, cfg, issue, "labels")

    def test_native_issue_type_maps(self):
        self.assertEqual(self.resolve(issue_type="Bug").commit_type, "fix")

    def test_label_fallback(self):
        self.assertEqual(self.resolve(labels=["type:chore"]).commit_type, "chore")

    def test_disagreement_fails_loud(self):
        out = self.resolve(labels=["type:chore"], issue_type="Feature")
        self.assertTrue(any("disagrees" in e for e in out.errors))

    def test_agreement_is_fine(self):
        out = self.resolve(labels=["type:feat"], issue_type="Feature")
        self.assertFalse(out.errors)
        self.assertEqual(out.commit_type, "feat")

    def test_default_with_warning(self):
        out = self.resolve()
        self.assertEqual(out.commit_type, "feat")
        self.assertTrue(any("defaulting" in w for w in out.warnings))


if __name__ == "__main__":
    unittest.main()
