"""Shepherd classification: check-rollup bucketing and the signature catalog."""

from __future__ import annotations

import unittest

from foreman import signatures as signatures_mod
from foreman.shepherd import classify_checks


class ClassifyChecks(unittest.TestCase):
    def test_all_green(self):
        rollup = [
            {"status": "COMPLETED", "conclusion": "SUCCESS"},
            {"status": "COMPLETED", "conclusion": "SKIPPED"},
            {"status": "COMPLETED", "conclusion": "NEUTRAL"},
        ]
        state, failed = classify_checks(rollup)
        self.assertEqual(state, "green")
        self.assertEqual(failed, [])

    def test_failure_wins_over_pending(self):
        rollup = [
            {"status": "IN_PROGRESS", "conclusion": ""},
            {"status": "COMPLETED", "conclusion": "FAILURE", "name": "verify"},
        ]
        state, failed = classify_checks(rollup)
        self.assertEqual(state, "red")
        self.assertEqual(failed[0]["name"], "verify")

    def test_pending_when_running(self):
        state, _ = classify_checks([{"status": "QUEUED", "conclusion": ""}])
        self.assertEqual(state, "pending")

    def test_empty_rollup_is_green(self):
        self.assertEqual(classify_checks([])[0], "green")
        self.assertEqual(classify_checks(None)[0], "green")

    def test_legacy_status_contexts(self):
        state, failed = classify_checks([{"state": "FAILURE", "context": "ci/legacy"}])
        self.assertEqual(state, "red")
        self.assertEqual(failed[0]["context"], "ci/legacy")


class SignatureCatalog(unittest.TestCase):
    def setUp(self):
        self.catalog = signatures_mod.load()

    def test_seeded_environment_signatures(self):
        sig = signatures_mod.match(
            "Error: DeploymentQuotaReached for team", self.catalog
        )
        self.assertIsNotNone(sig)
        self.assertEqual(sig.action, "environment")
        sig = signatures_mod.match(
            "The job was not started because recent account payments have failed",
            self.catalog,
        )
        self.assertEqual(sig.action, "environment")

    def test_quota_wait_signature(self):
        sig = signatures_mod.match(
            "You have hit your usage limit. Limit will reset at 3pm", self.catalog
        )
        self.assertIsNotNone(sig)
        self.assertEqual(sig.action, "quota_wait")

    def test_no_match_returns_none(self):
        self.assertIsNone(
            signatures_mod.match("TypeError: x is not a function", self.catalog)
        )


if __name__ == "__main__":
    unittest.main()
