"""Graph mechanics: waves, cycles, Depends-on trailer conflicts, parent-unit
granularity via load_target over the fake transport."""

from __future__ import annotations

import unittest

from foreman.config import Config
from foreman.graph import Target, Unit, detect_cycle, load_target, waves
from foreman.tests.fakes import issue_json, make_github


def bare_unit(number: int, blocked_by: list[int] | None = None) -> Unit:
    return Unit(
        number=number,
        title=f"U{number}",
        state="OPEN",
        state_reason=None,
        body="",
        url="",
        labels=[],
        issue_type=None,
        milestone=None,
        parent=None,
        blocked_by=blocked_by or [],
    )


def target_of(*units: Unit) -> Target:
    return Target(label="test", units={u.number: u for u in units}, external_deps=set())


class WavesAndCycles(unittest.TestCase):
    def test_waves_follow_dependencies(self):
        target = target_of(
            bare_unit(1), bare_unit(2, [1]), bare_unit(3, [1]), bare_unit(4, [2, 3])
        )
        self.assertEqual(waves(target), [[1], [2, 3], [4]])

    def test_cycle_detected_with_path(self):
        target = target_of(bare_unit(1, [3]), bare_unit(2, [1]), bare_unit(3, [2]))
        cycle = detect_cycle(target)
        self.assertIsNotNone(cycle)
        self.assertGreaterEqual(len(cycle), 3)

    def test_no_cycle_returns_none(self):
        self.assertIsNone(detect_cycle(target_of(bare_unit(1), bare_unit(2, [1]))))


class LoadTarget(unittest.TestCase):
    def test_issue_mode_pulls_sub_issues_into_one_unit(self):
        cfg = Config()
        gh, runner = make_github(cfg)
        runner.when(["issue", "view", "10"], issue_json(10, sub_issues=[11, 12]))
        runner.when(["issue", "view", "11"], issue_json(11, parent=10))
        runner.when(["issue", "view", "12"], issue_json(12, parent=10))
        target = load_target(gh, cfg, issue=10)
        self.assertEqual(set(target.units), {10})
        self.assertEqual([s["number"] for s in target.units[10].sub_issues], [11, 12])

    def test_trailer_conflict_fails_loud(self):
        cfg = Config()
        gh, runner = make_github(cfg)
        body = "spec\n\nDepends-on: #5\n"
        runner.when(["issue", "view", "10"], issue_json(10, body=body, blocked_by=[6]))
        runner.when(["issue", "view", "6"], issue_json(6))
        target = load_target(gh, cfg, issue=10)
        self.assertTrue(any("disagrees" in e for e in target.units[10].errors))

    def test_trailer_alone_is_the_fallback(self):
        cfg = Config()
        gh, runner = make_github(cfg)
        runner.when(
            ["issue", "view", "10"], issue_json(10, body="Depends-on: #5, #6\n")
        )
        target = load_target(gh, cfg, issue=10)
        self.assertEqual(target.units[10].blocked_by, [5, 6])
        self.assertEqual(target.external_deps, {5, 6})


if __name__ == "__main__":
    unittest.main()
