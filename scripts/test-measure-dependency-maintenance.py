#!/usr/bin/env python3
"""Tests for dependency-maintenance timeline measurements."""

import importlib.util
import pathlib
import json
import io
from unittest.mock import patch
from contextlib import redirect_stdout
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
            {"event": "reviewed", "user": {"type": "User"}, "submitted_at": pr["created_at"]},
            {"event": "reviewed", "user": {"type": "Bot"}, "submitted_at": pr["merged_at"]},
            {"event": "commented", "actor": {"type": "User"}, "created_at": "2026-10-04T00:00:00Z"},
            {"event": "head_ref_force_pushed", "actor": {"type": "User"}, "created_at": pr["merged_at"]},
        ]
        run = {"run_attempt": 3, "created_at": pr["created_at"], "run_started_at": pr["created_at"], "updated_at": pr["merged_at"]}
        self.assertEqual(measure.measure(pr, timeline, [run]), (2, 2, 2.5, 1))
        run["updated_at"] = "2026-11-01T00:00:00Z"
        self.assertIsNone(measure.measure(pr, timeline, [run])[1])
        self.assertIsNone(measure.measure(pr, [{"event": "reviewed", "user": {"type": "User"}}], [])[0])
        run["created_at"] = "2026-09-30T00:00:00Z"
        self.assertIsNone(measure.measure(pr, [], [run])[1])

    def test_main_historical_cohort(self):
        pr = {"created_at": "2026-09-30T00:00:00Z", "merged_at": "2026-10-15T00:00:00Z"}
        timeline = [{"event": "reviewed", "user": {"type": "User"}, "submitted_at": "2026-10-01T00:00:00Z"},
                    {"event": "commented", "actor": {"type": "User"}, "created_at": "2026-11-01T00:00:00Z"}]
        run = {"id": 1, "run_attempt": 2, "created_at": "2026-10-01T00:00:00Z", "run_started_at": "2026-11-01T00:00:00Z", "updated_at": "2026-11-01T00:00:00Z"}
        responses = [pr, [timeline], [[{"sha": "abc"}]], [{"workflow_runs": [run]}]]
        class Result:
            def __init__(self, value):
                self.stdout = json.dumps(value)
        output = io.StringIO()
        with patch.object(measure.subprocess, "run", side_effect=[Result(v) for v in responses]), \
             patch("sys.argv", ["measure", "--repo", "a/b", "--cycle", "oct", "--start", "2026-10-01", "--end", "2026-11-01", "--pr", "12"]), redirect_stdout(output):
            self.assertEqual(measure.main(), 0)
        self.assertIn("#12 | unknown | 1 | unknown | unknown | 15.00 | unknown | 0", output.getvalue())

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
