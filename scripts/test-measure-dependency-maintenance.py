#!/usr/bin/env python3
"""Tests for dependency-maintenance timeline measurements."""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "measure", pathlib.Path(__file__).with_name("measure-dependency-maintenance.py")
)
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class MeasureTests(unittest.TestCase):
    def test_observed_events_and_attempts(self):
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-03T12:00:00Z"}
        timeline = [
            {"event": "commented", "actor": {"type": "User"}},
            {"event": "reviewed", "actor": {"type": "Bot"}},
            {"event": "head_ref_force_pushed", "actor": {"type": "User"}},
            {"event": "labeled", "actor": {"type": "User"}},
        ]
        self.assertEqual(measure.measure(pr, timeline, [{"run_attempt": 3}, {"run_attempt": 1}]), (2, 2, 2.5, 1))

    def test_bound_cited_records_and_incomplete_measure(self):
        data = {"repo": "a/b", "cycle": "oct", "pull_requests": [{
            "number": 12,
            "interventions": {"complete": True, "records": ["run:1", "timeline:2"]},
            "rebases": {"complete": False, "records": ["run:3"]},
        }]}
        self.assertEqual(measure.load_evidence(data, "a/b", "oct", [12]), {12: {"interventions": 2}})
        with self.assertRaises(ValueError):
            measure.load_evidence(data, "a/b", "nov", [12])
        data["pull_requests"][0]["interventions"]["records"].append("run:1")
        with self.assertRaises(ValueError):
            measure.load_evidence(data, "a/b", "oct", [12])

    def test_empty_evidence_does_not_invent_activity(self):
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-01T00:00:00Z"}
        self.assertEqual(measure.measure(pr, [], []), (0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main()
