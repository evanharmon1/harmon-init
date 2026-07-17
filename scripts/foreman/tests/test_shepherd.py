"""Shepherd classification: check-rollup bucketing and the signature catalog."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from foreman import signatures as signatures_mod
from foreman.config import Config
from foreman.github import GitHub
from foreman.shepherd import classify_checks, shepherd_pr, trusted_review_threads
from foreman.tests.fakes import make_github
from foreman.util import ForemanError


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


class TrustedReviewThreads(unittest.TestCase):
    def test_untrusted_authors_are_excluded(self):
        cfg = Config()
        gh, _runner = make_github(cfg)

        def thread(author: str, association: str) -> dict:
            return {
                "id": author,
                "comments": {
                    "nodes": [
                        {
                            "author": {"login": author},
                            "authorAssociation": association,
                            "body": f"finding from {author}",
                        }
                    ]
                },
            }

        threads = [
            thread("owner", "OWNER"),
            thread("CodeRabbitAI", "NONE"),
            thread("bot", "NONE"),
            thread("rando", "NONE"),
            {"id": "empty", "comments": {"nodes": []}},
        ]
        kept, excluded = trusted_review_threads(gh, cfg, threads)
        self.assertEqual(
            [item["id"] for item in kept], ["owner", "CodeRabbitAI", "bot"]
        )
        self.assertEqual(excluded, 2)

    def test_any_untrusted_reply_excludes_the_thread(self):
        cfg = Config()
        gh, _runner = make_github(cfg)
        thread = {
            "id": "mixed",
            "comments": {
                "nodes": [
                    {
                        "author": {"login": "coderabbitai"},
                        "authorAssociation": "NONE",
                    },
                    {
                        "author": {"login": "rando"},
                        "authorAssociation": "NONE",
                    },
                ]
            },
        }
        kept, excluded = trusted_review_threads(gh, cfg, [thread])
        self.assertEqual(kept, [])
        self.assertEqual(excluded, 1)


class ReviewThreadRetrieval(unittest.TestCase):
    @staticmethod
    def response(nodes: object) -> dict:
        return {
            "data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": nodes}}}}
        }

    def test_valid_empty_thread_list_is_distinct_from_failure(self):
        gh, runner = make_github()
        runner.when(["api", "graphql"], self.response([]))
        self.assertEqual(gh.review_threads(17), [])

    def test_graphql_errors_fail_closed(self):
        gh, runner = make_github()
        response = self.response([])
        response["errors"] = [{"message": "partial response"}]
        runner.when(["api", "graphql"], response)
        with self.assertRaisesRegex(ForemanError, "indeterminate GraphQL response"):
            gh.review_threads(17)

    def test_malformed_thread_list_fails_closed(self):
        gh, runner = make_github()
        runner.when(["api", "graphql"], self.response(None))
        with self.assertRaisesRegex(ForemanError, "invalid thread list"):
            gh.review_threads(17)


class MergeReadiness(unittest.TestCase):
    @staticmethod
    def github(merge_state: str, mergeable: str) -> MagicMock:
        gh = MagicMock(spec=GitHub)
        gh.pr_status.return_value = {
            "number": 23,
            "title": "Example",
            "url": "https://github.com/owner/repo/pull/23",
            "headRefName": "foreman/feat/17-example",
            "mergeStateStatus": merge_state,
            "mergeable": mergeable,
            "statusCheckRollup": [],
        }
        gh.review_threads.return_value = []
        gh.viewer.return_value = "bot"
        return gh

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_mergeable_but_blocked_pr_is_not_ready(self, _remote):
        gh = self.github("BLOCKED", "MERGEABLE")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "healthy")
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_clean_pr_is_ready(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "ready")
        gh.label_own_pr.assert_called_once_with(23, add=["ready-to-merge"])


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
