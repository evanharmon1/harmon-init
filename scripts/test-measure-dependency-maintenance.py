#!/usr/bin/env python3
"""Tests for dependency-maintenance timeline measurements."""

import importlib.util
import pathlib
import json
import io
import subprocess
import sys
from unittest.mock import patch
from contextlib import redirect_stdout, redirect_stderr
import unittest

spec = importlib.util.spec_from_file_location(
    "measure", pathlib.Path(__file__).with_name("measure-dependency-maintenance.py")
)
measure = importlib.util.module_from_spec(spec)
previous_bytecode_setting = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    spec.loader.exec_module(measure)
finally:
    sys.dont_write_bytecode = previous_bytecode_setting


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
        run["updated_at"] = pr["merged_at"]
        run["created_at"] = "2026-09-30T00:00:00Z"
        self.assertIsNone(measure.measure(pr, [], [run])[1])

    def test_single_attempt_crosses_lifetime(self):
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-03T00:00:00Z"}
        run = {"run_attempt": 1, "created_at": "2026-09-30T00:00:00Z", "run_started_at": pr["created_at"], "updated_at": "2026-10-04T00:00:00Z"}
        self.assertEqual(measure.measure(pr, [], [run])[1], 0)
        run["run_attempt"] = 2
        self.assertIsNone(measure.measure(pr, [], [run])[1])

    def test_cli_errors(self):
        base = ["measure", "--repo", "a/b", "--cycle", "oct", "--start", "2026-10-01", "--end", "2026-11-01", "--pr", "12"]
        for flag, value, diagnostic in [("--start", "2026-10-32", "day"), ("--start", "2026-10-01T00:00:00+02:00", "Invalid isoformat string"), ("--end", "2026-11-01T00:00:00Z", "Invalid isoformat string")]:
            args = base.copy()
            args[args.index(flag) + 1] = value
            with self.subTest(flag=flag, value=value), patch("sys.argv", args), \
                 patch.object(measure.subprocess, "run", side_effect=AssertionError("subprocess forbidden")) as run, \
                 redirect_stderr(io.StringIO()) as err, redirect_stdout(io.StringIO()) as out:
                self.assertEqual(measure.main(), 1)
                self.assertEqual(out.getvalue(), "")
                self.assertIn("Unable to measure:", err.getvalue())
                self.assertIn(diagnostic, err.getvalue())
                run.assert_not_called()
        error = subprocess.CalledProcessError(1, ["gh"], stderr="access denied")
        with patch("sys.argv", base), patch.object(measure.subprocess, "run", side_effect=error), redirect_stderr(io.StringIO()) as err, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(measure.main(), 1)
            self.assertIn("access denied", err.getvalue())
            self.assertEqual(out.getvalue(), "")

    def test_malformed_pr_response(self):
        args = ["measure", "--repo", "a/b", "--cycle", "oct", "--start", "2026-10-01", "--end", "2026-11-01", "--pr", "12"]
        for value in ([], None, "invalid", 42):
            result = subprocess.CompletedProcess(["gh"], 0, stdout=json.dumps(value))
            with self.subTest(value=value), patch("sys.argv", args), \
                 patch.object(measure.subprocess, "run", return_value=result) as run, \
                 redirect_stderr(io.StringIO()) as err, redirect_stdout(io.StringIO()) as out:
                self.assertEqual(measure.main(), 1)
                self.assertEqual(out.getvalue(), "")
                self.assertIn("PR #12 response must be a JSON object", err.getvalue())
                self.assertEqual(run.call_count, 1)

    def test_cli_malformed_timeline_entry(self):
        args = ["measure", "--repo", "a/b", "--cycle", "oct", "--start", "2026-10-01", "--end", "2026-11-01", "--pr", "12", "--pr", "13"]
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-03T00:00:00Z"}
        for entry in (None, [], "invalid", 42):
            responses = [pr, [[]], [[]], pr, [[entry]], [[]]]
            results = [subprocess.CompletedProcess(["gh"], 0, stdout=json.dumps(value)) for value in responses]
            with self.subTest(entry=entry), patch("sys.argv", args), \
                 patch.object(measure.subprocess, "run", side_effect=results) as run, \
                 redirect_stderr(io.StringIO()) as err, redirect_stdout(io.StringIO()) as out:
                self.assertEqual(measure.main(), 1)
                self.assertEqual(out.getvalue(), "")
                self.assertIn("Unable to measure: timeline entry must be a JSON object", err.getvalue())
                self.assertEqual(run.call_count, 6)

    def test_cli_unavailable_timeline_evidence(self):
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-03T00:00:00Z"}
        timeline = [{"event": "reviewed", "user": {"type": "User"}},
                    {"event": "head_ref_force_pushed", "actor": {"type": "Bot"}}]
        responses = [pr, [timeline], [[]]]
        results = [subprocess.CompletedProcess(["gh"], 0, stdout=json.dumps(value)) for value in responses]
        args = ["measure", "--repo", "a/b", "--cycle", "oct", "--start", "2026-10-01", "--end", "2026-11-01", "--pr", "12"]
        with patch("sys.argv", args), patch.object(measure.subprocess, "run", side_effect=results), \
             redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()) as err:
            self.assertEqual(measure.main(), 0)
            self.assertIn("#12 | unknown | 0 | 2.00 | unknown", out.getvalue())
            self.assertEqual(err.getvalue(), "")

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
        self.assertIn("#12 | 1 | unknown | 15.00 | 0", output.getvalue())

    def test_cli_reports_paginated_observed_proxies(self):
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-03T00:00:00Z"}
        timeline = [[{"event": "reviewed", "user": {"type": "User"}, "submitted_at": pr["created_at"]}],
                    [{"event": "head_ref_force_pushed", "actor": {"type": "Bot"}, "created_at": pr["merged_at"]}]]
        run = {"id": 1, "run_attempt": 3, "created_at": pr["created_at"],
               "run_started_at": pr["created_at"], "updated_at": pr["merged_at"]}
        responses = [pr, timeline, [[{"sha": "abc"}], [{"sha": "def"}]],
                     [{"workflow_runs": [run]}, {"workflow_runs": []}],
                     [{"workflow_runs": [run]}]]
        class Result:
            def __init__(self, value):
                self.stdout = json.dumps(value)
        output = io.StringIO()
        with patch.object(measure.subprocess, "run", side_effect=[Result(v) for v in responses]), \
             patch("sys.argv", ["measure", "--repo", "a/b", "--cycle", "oct", "--start", "2026-10-01", "--end", "2026-11-01", "--pr", "12"]), redirect_stdout(output):
            self.assertEqual(measure.main(), 0)
        self.assertIn("#12 | 1 | 2 | 2.00 | 1", output.getvalue())
        self.assertIn("human timeline actions (proxy)", output.getvalue())
        self.assertNotIn("actual interventions", output.getvalue())

    def test_empty_evidence_does_not_invent_activity(self):
        pr = {"created_at": "2026-10-01T00:00:00Z", "merged_at": "2026-10-01T00:00:00Z"}
        self.assertEqual(measure.measure(pr, [], []), (0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main()
