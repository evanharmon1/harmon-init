"""Shepherd classification: check-rollup bucketing and the signature catalog."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from foreman import signatures as signatures_mod
from foreman.config import Config
from foreman.github import GitHub
from foreman.shepherd import (
    classify_checks,
    ready_label_is_authoritative,
    shepherd_pr,
    trusted_review_threads,
)
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

    def test_pending_legacy_status_is_not_green(self):
        # A legacy commit status has no `status` field and carries its state
        # where a check run carries its conclusion, so a pending one used to
        # fall through both pending tests and read as green.
        self.assertEqual(
            classify_checks([{"context": "ci", "state": "PENDING"}])[0], "pending"
        )
        self.assertEqual(
            classify_checks([{"context": "ci", "state": "EXPECTED"}])[0], "pending"
        )
        self.assertEqual(
            classify_checks([{"context": "ci", "state": "SUCCESS"}])[0], "green"
        )


class ReadinessLabelAuthority(unittest.TestCase):
    def test_default_policy_accepts_readiness_label(self):
        self.assertTrue(
            ready_label_is_authoritative(
                ["foreman-dispatched", "ready-to-merge"],
                require_codex_cloud_review=False,
            )
        )

    def test_cloud_review_policy_ignores_stale_readiness_label(self):
        self.assertFalse(
            ready_label_is_authoritative(
                ["foreman-dispatched", "ready-to-merge"],
                require_codex_cloud_review=True,
            )
        )


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
            thread("Copilot", "NONE"),
            thread("bot", "NONE"),
            thread("rando", "NONE"),
            {"id": "empty", "comments": {"nodes": []}},
        ]
        kept, excluded = trusted_review_threads(gh, cfg, threads)
        self.assertEqual([item["id"] for item in kept], ["owner", "Copilot", "bot"])
        self.assertEqual(excluded, 2)

    def test_any_untrusted_reply_excludes_the_thread(self):
        cfg = Config()
        gh, _runner = make_github(cfg)
        thread = {
            "id": "mixed",
            "comments": {
                "nodes": [
                    {
                        "author": {"login": "Copilot"},
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
    HEAD = "d15ea5e"

    @classmethod
    def github(
        cls, merge_state: str, mergeable: str, *, draft: bool = True
    ) -> MagicMock:
        """A foreman PR as GitHub actually reports it.

        `merge_state` and `draft` are not independent: GitHub reports
        mergeStateStatus=DRAFT while the draft flag is set, and CLEAN only
        becomes reachable after promotion. Pass the pair that can co-occur.
        """
        gh = MagicMock(spec=GitHub)
        gh.pr_status.return_value = {
            "number": 23,
            "title": "Example",
            "url": "https://github.com/owner/repo/pull/23",
            "headRefName": "foreman/feat/17-example",
            "headRefOid": cls.HEAD,
            "isDraft": draft,
            "reviewDecision": "",
            "baseRefName": "main",
            "mergeStateStatus": merge_state,
            "mergeable": mergeable,
            "statusCheckRollup": [
                {"name": "verify", "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"name": "security", "status": "COMPLETED", "conclusion": "SUCCESS"},
            ],
            "labels": [],
        }
        gh.required_checks.return_value = {"verify", "security"}
        gh.behind_by.return_value = 0
        # Gate re-read, then (for a draft) the post-promotion confirmation.
        gh.pr_head.side_effect = [
            {"state": "OPEN", "isDraft": draft, "headRefOid": cls.HEAD},
            {"state": "OPEN", "isDraft": False, "headRefOid": cls.HEAD},
        ]
        gh.review_threads.return_value = []
        gh.viewer.return_value = "bot"
        return gh

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_blocked_non_draft_pr_is_not_labelled(self, _remote):
        gh = self.github("BLOCKED", "MERGEABLE", draft=False)
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "healthy")
        gh.label_own_pr.assert_not_called()
        gh.ready_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_blocked_draft_is_still_promoted(self, _remote):
        # Observed live on harmon-init#520: a draft in a repo whose ruleset
        # requires code-owner review reports BLOCKED, not DRAFT — the draft flag
        # does not win mergeStateStatus' precedence order. BLOCKED means "the
        # required review has not happened", which is precisely what promoting
        # asks for, so an allowlist of DRAFT/CLEAN would deadlock the handoff.
        gh = self.github("BLOCKED", "MERGEABLE")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "promoted")
        gh.ready_own_pr.assert_called_once_with(23)
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_unknown_merge_state_never_promotes(self, _remote):
        gh = self.github("UNKNOWN", "MERGEABLE")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "healthy")
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_draft_merge_state_still_reaches_the_promotion_gate(self, _remote):
        # The regression this guards: a draft reports mergeStateStatus=DRAFT,
        # never CLEAN, so gating promotion on CLEAN alone made it dead code and
        # left every foreman draft sitting at "healthy, mergeState=DRAFT".
        gh = self.github("DRAFT", "MERGEABLE")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "promoted")
        gh.ready_own_pr.assert_called_once_with(23)
        self.assertIn("promoted to ready for human review", work.detail)
        # Not mergeable yet — a just-promoted PR has not been reviewed, so it
        # must not carry the merge label or enter the suggested merge order.
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_clean_non_draft_pr_is_labelled_not_promoted_again(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE", draft=False)
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "ready")
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_called_once_with(23, add=["ready-to-merge"])

    @patch("foreman.shepherd.worktree.push")
    @patch("foreman.shepherd.worktree.rebase_onto", return_value=True)
    @patch("foreman.shepherd.worktree.merge_tree_conflicts", return_value=[])
    @patch("foreman.shepherd.worktree.fetch")
    @patch("foreman.shepherd._ensure_worktree", return_value=Path("."))
    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_conflicting_draft_is_rebased_despite_the_draft_merge_state(
        self, _remote, _worktree, _fetch, conflicts, _rebase, _push
    ):
        # DRAFT can stand in front of a conflicting branch; `mergeable` is
        # computed independently, so the rebase path must consult it too.
        gh = self.github("DRAFT", "CONFLICTING")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        conflicts.assert_called_once()
        self.assertEqual(work.state, "rebased")
        gh.ready_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.push")
    @patch("foreman.shepherd.worktree.rebase_onto", return_value=True)
    @patch("foreman.shepherd.worktree.merge_tree_conflicts", return_value=[])
    @patch("foreman.shepherd.worktree.fetch")
    @patch("foreman.shepherd._ensure_worktree", return_value=Path("."))
    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_stale_draft_is_rebased_not_promoted(
        self, _remote, _worktree, _fetch, _conflicts, _rebase, _push
    ):
        # DRAFT masks BEHIND the way it masks BLOCKED, and staleness has no
        # `mergeable`-style field of its own, so the branch is compared to base
        # directly. Promoting a stale draft would hand a human a PR the gate
        # says must not be BEHIND.
        gh = self.github("DRAFT", "MERGEABLE")
        gh.behind_by.return_value = 3
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        gh.behind_by.assert_called_once_with("main", "foreman/feat/17-example")
        self.assertEqual(work.state, "rebased")
        gh.ready_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_staleness_is_not_queried_for_a_non_draft(self, _remote):
        # A non-draft reports BEHIND itself, so the extra round trip is only
        # worth making while DRAFT is masking it.
        gh = self.github("CLEAN", "MERGEABLE", draft=False)
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        gh.behind_by.assert_not_called()
        self.assertEqual(work.state, "ready")

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_requested_changes_block_the_handoff(self, _remote):
        gh = self.github("DRAFT", "MERGEABLE")
        gh.pr_status.return_value["reviewDecision"] = "CHANGES_REQUESTED"
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "escalated")
        self.assertIn("requested changes", work.detail)
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_head_moving_during_the_gate_defers_promotion(self, _remote):
        gh = self.github("DRAFT", "MERGEABLE")
        gh.pr_head.side_effect = [
            {"state": "OPEN", "isDraft": True, "headRefOid": "beefbee"}
        ]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "settling")
        self.assertIn("head moved", work.detail)
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_closed_pr_is_never_promoted(self, _remote):
        gh = self.github("DRAFT", "MERGEABLE")
        gh.pr_head.side_effect = [
            {"state": "CLOSED", "isDraft": True, "headRefOid": self.HEAD}
        ]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "escalated")
        self.assertIn("refusing to promote", work.detail)
        gh.ready_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_empty_check_rollup_is_not_evidence_of_a_green_head(self, _remote):
        # classify_checks calls an empty rollup green — right for display, wrong
        # for a one-way handoff. GitHub fills the rollup asynchronously.
        gh = self.github("DRAFT", "MERGEABLE")
        gh.pr_status.return_value["statusCheckRollup"] = []
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "settling")
        self.assertIn("required check(s) not reported yet", work.detail)
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_partial_rollup_waits_for_the_required_checks(self, _remote):
        # The narrow window this closes: GitHub registers checks incrementally,
        # so one fast check can be green while a required workflow has not
        # appeared. DRAFT masks the BLOCKED that would otherwise reveal it.
        gh = self.github("DRAFT", "MERGEABLE")
        gh.pr_status.return_value["statusCheckRollup"] = [
            {"name": "verify", "status": "COMPLETED", "conclusion": "SUCCESS"}
        ]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "settling")
        self.assertIn("security", work.detail)
        gh.ready_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_legacy_status_contexts_satisfy_required_checks(self, _remote):
        # Commit statuses carry `context` where check runs carry `name`.
        gh = self.github("DRAFT", "MERGEABLE")
        gh.pr_status.return_value["statusCheckRollup"] = [
            {"name": "verify", "status": "COMPLETED", "conclusion": "SUCCESS"},
            {"context": "security", "state": "SUCCESS"},
        ]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "promoted")
        gh.ready_own_pr.assert_called_once_with(23)

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_branch_without_required_checks_escalates(self, _remote):
        # A repo whose branch ruleset was never imported enforces nothing, so
        # there is no CI result to certify — that needs a human, not a handoff.
        gh = self.github("DRAFT", "MERGEABLE")
        gh.required_checks.return_value = set()
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "escalated")
        self.assertIn("no required checks", work.detail)
        gh.ready_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_unknown_mergeability_defers_promotion(self, _remote):
        # GitHub computes mergeability asynchronously, so it reads UNKNOWN for a
        # while after every push. "Not known to conflict" is not "mergeable".
        gh = self.github("DRAFT", "UNKNOWN")
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "settling")
        self.assertIn("mergeability still UNKNOWN", work.detail)
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_unreadable_draft_state_refuses_to_promote(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE")
        gh.pr_head.side_effect = [{"state": "OPEN", "headRefOid": self.HEAD}]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "escalated")
        self.assertIn("draft state", work.detail)
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_unreadable_gated_head_defers_promotion(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE")
        del gh.pr_status.return_value["headRefOid"]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "settling")
        gh.ready_own_pr.assert_not_called()
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_unconfirmed_promotion_escalates_without_labelling(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE")
        # The promotion command returned, but the PR is still draft: treat the
        # transition as unproven rather than reporting a handoff that may not
        # have happened.
        gh.pr_head.side_effect = [
            {"state": "OPEN", "isDraft": True, "headRefOid": self.HEAD},
            {"state": "OPEN", "isDraft": True, "headRefOid": self.HEAD},
        ]
        work = shepherd_pr(gh, Config(), Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "escalated")
        self.assertIn("not confirmed", work.detail)
        gh.label_own_pr.assert_not_called()

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_cloud_review_requirement_fails_closed_to_manual_shepherd(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE")
        cfg = Config(require_codex_cloud_review=True)
        gh.pr_status.return_value["labels"] = [{"name": "ready-to-merge"}]
        work = shepherd_pr(gh, cfg, Path("."), {"number": 23, "_unit": 17}, [])
        self.assertEqual(work.state, "escalated")
        self.assertIn("manual shepherd", work.detail)
        gh.label_own_pr.assert_called_once_with(23, remove=["ready-to-merge"])

    @patch("foreman.shepherd.worktree.remote", return_value="origin")
    def test_cloud_review_requirement_removes_readiness_while_checks_run(self, _remote):
        gh = self.github("CLEAN", "MERGEABLE")
        gh.pr_status.return_value["statusCheckRollup"] = [
            {"status": "IN_PROGRESS", "conclusion": ""}
        ]
        gh.pr_status.return_value["labels"] = [{"name": "ready-to-merge"}]

        work = shepherd_pr(
            gh,
            Config(require_codex_cloud_review=True),
            Path("."),
            {"number": 23, "_unit": 17},
            [],
        )

        self.assertEqual(work.state, "settling")
        gh.label_own_pr.assert_called_once_with(23, remove=["ready-to-merge"])


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
