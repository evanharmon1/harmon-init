"""The write contract, enforced: read-only mode blocks every mutation before
any gh call; identity assertion gates the first write; forbidden operations
(merge, issue close/edit/reopen) do not exist in the mutation surface at all.
"""

from __future__ import annotations

import inspect
import re
import unittest

from foreman import github as github_mod
from foreman.config import Config
from foreman.github import STATUS_MARKER
from foreman.tests.fakes import make_github
from foreman.util import ForemanError


def _mutations(gh):
    return [
        ("ensure_labels", lambda: gh.ensure_labels()),
        (
            "create_pr",
            lambda: gh.create_pr(title="t", body="b", head="h", base="main", labels=[]),
        ),
        ("edit_own_pr_body", lambda: gh.edit_own_pr_body(1, "b")),
        ("label_own_pr", lambda: gh.label_own_pr(1, add=["ready-to-merge"])),
        ("comment_own_pr", lambda: gh.comment_own_pr(1, "b")),
        (
            "upsert_status_comment",
            lambda: gh.upsert_status_comment(1, STATUS_MARKER + "\nb"),
        ),
        (
            "post_preflight_correction",
            lambda: gh.post_preflight_correction(1, "b", human_approved=True),
        ),
        ("resolve_review_thread", lambda: gh.resolve_review_thread("T_x")),
    ]


class ReadOnlyMode(unittest.TestCase):
    def test_every_mutation_refuses_in_read_only_mode(self):
        gh, runner = make_github()
        gh.read_only = True
        baseline = len(runner.calls)
        for name, call in _mutations(gh):
            with self.assertRaises(ForemanError, msg=name):
                call()
        # No gh process was ever invoked by a refused mutation.
        self.assertEqual(len(runner.calls), baseline)


class IdentityAssertion(unittest.TestCase):
    def test_wrong_identity_blocks_first_write(self):
        cfg = Config(expected_login="evanharmon1-bot")  # fake viewer is "bot"
        gh, runner = make_github(cfg)
        with self.assertRaises(ForemanError) as ctx:
            gh.ensure_labels()
        self.assertIn("identity assertion failed", str(ctx.exception))
        self.assertFalse(runner.called_with_prefix(["label"]))

    def test_matching_identity_allows_writes(self):
        cfg = Config(expected_login="bot")
        gh, runner = make_github(cfg)
        runner.when(["label", "create"], "")
        gh.ensure_labels()
        self.assertTrue(runner.called_with_prefix(["label", "create"]))


class GuardedChannels(unittest.TestCase):
    def test_preflight_comment_requires_human_approval(self):
        gh, runner = make_github()
        with self.assertRaises(ForemanError):
            gh.post_preflight_correction(1, "body", human_approved=False)
        self.assertFalse(runner.called_with_prefix(["api", "--method", "POST"]))

    def test_own_pr_guard_rejects_foreign_prs(self):
        gh, runner = make_github()
        runner.when(
            ["pr", "view", "9"],
            {"number": 9, "author": {"login": "human"}, "labels": [], "body": ""},
        )
        with self.assertRaises(ForemanError):
            gh.edit_own_pr_body(9, "new body")

    def test_label_namespace_is_enforced(self):
        gh, runner = make_github()
        runner.when(
            ["pr", "view", "9"],
            {"number": 9, "author": {"login": "bot"}, "labels": [], "body": ""},
        )
        with self.assertRaises(ForemanError):
            gh.label_own_pr(9, add=["priority:high"])

    def test_status_comment_edits_only_own_marked_comment(self):
        gh, runner = make_github()
        comments = [
            # A human comment carrying a forged marker must never be edited.
            {"id": 1, "body": STATUS_MARKER + " forged", "user": {"login": "human"}},
            {"id": 2, "body": STATUS_MARKER + " real", "user": {"login": "bot"}},
        ]
        runner.when(
            ["api", "repos/owner/repo/issues/7/comments", "--paginate", "--slurp"],
            [comments],
        )
        runner.when(
            ["api", "--method", "PATCH", "repos/owner/repo/issues/comments/2"], "{}"
        )
        gh.upsert_status_comment(7, STATUS_MARKER + "\nupdated")
        patches = runner.called_with_prefix(["api", "--method", "PATCH"])
        self.assertEqual(len(patches), 1)
        self.assertIn("comments/2", patches[0][3])

    def test_status_comment_requires_marker(self):
        gh, _runner = make_github()
        with self.assertRaises(ForemanError):
            gh.upsert_status_comment(7, "no marker here")


class ForbiddenOperationsAbsent(unittest.TestCase):
    """Merging, closing/reopening/editing issues, deleting others' comments —
    the write contract says these must not exist. Keep them nonexistent."""

    def test_no_forbidden_gh_invocations_in_source(self):
        source = inspect.getsource(github_mod)
        forbidden = [
            r"\"merge\"",  # gh pr merge — never; mergeable/mergeStateStatus fields are fine
            r"'merge'",
            r"issue\W+close",
            r"issue\W+reopen",
            r"issue\W+edit",
            r"issue\W+delete",
            r"\"DELETE\"",
            r"mergePullRequest",
            r"enablePullRequestAutoMerge",
        ]
        for pattern in forbidden:
            self.assertIsNone(
                re.search(pattern, source, re.I),
                f"forbidden operation pattern {pattern!r} found in github.py",
            )

    def test_no_merge_method_exists(self):
        gh, _runner = make_github()
        for name in dir(gh):
            self.assertNotIn(
                "merge",
                name.lower(),
                f"GitHub facade must not expose a merge-ish method: {name}",
            )


if __name__ == "__main__":
    unittest.main()
