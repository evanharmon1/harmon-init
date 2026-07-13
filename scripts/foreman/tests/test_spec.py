"""Spec contract: AC parsing/tagging, prompt assembly trust policy, spec-hash
stability, handoff extraction, and prompt token completeness."""

from __future__ import annotations

import unittest

from foreman import spec
from foreman.config import Config
from foreman.graph import Unit
from foreman.tests.fakes import issue_json, make_github

BODY = """Intro.

## Acceptance Criteria

- Parses the config [CI]
- Verified against the live dashboard [HUMAN]
- Untagged criterion

## Human-only tasks

- Rotate the credential

## Out of Scope

- Everything else
"""


def unit_with(body: str = BODY, subs: list[dict] | None = None) -> Unit:
    return Unit(
        number=42,
        title="A unit",
        state="OPEN",
        state_reason=None,
        body=body,
        url="",
        labels=[],
        issue_type=None,
        milestone=None,
        parent=None,
        sub_issues=subs or [],
    )


class AcParsing(unittest.TestCase):
    def test_items_and_tags(self):
        items = spec.parse_ac(BODY)
        self.assertEqual(len(items), 3)
        self.assertEqual([i.tag for i in items], ["CI", "HUMAN", "CI"])
        self.assertFalse(items[2].tagged)

    def test_missing_section_is_non_dispatchable(self):
        info = spec.validate(unit_with("no criteria here"))
        self.assertTrue(info.errors)

    def test_untagged_items_warn(self):
        info = spec.validate(unit_with())
        self.assertFalse(info.errors)
        self.assertTrue(any("untagged" in w for w in info.warnings))

    def test_human_only_tasks_merge_both_sources(self):
        info = spec.validate(unit_with())
        tasks = spec.human_only_tasks(unit_with(), info)
        self.assertEqual(len(tasks), 2)
        self.assertIn("Rotate the credential", tasks)

    def test_find_section_stops_at_next_heading(self):
        section = spec.find_section(BODY, "Human-only tasks")
        self.assertIn("Rotate", section)
        self.assertNotIn("Out of Scope", section)


class SpecHash(unittest.TestCase):
    def test_stable_and_sensitive(self):
        unit = unit_with()
        first = spec.spec_hash(unit, [])
        self.assertEqual(first, spec.spec_hash(unit_with(), []))
        self.assertNotEqual(first, spec.spec_hash(unit_with(BODY + "drift"), []))
        self.assertNotEqual(
            first, spec.spec_hash(unit, [{"id": 1, "body": "correction"}])
        )


class TrustedComments(unittest.TestCase):
    def test_untrusted_authors_are_excluded(self):
        cfg = Config()
        gh, runner = make_github(cfg)
        comments = [
            {
                "id": 1,
                "body": "owner note",
                "user": {"login": "owner"},
                "author_association": "OWNER",
            },
            {
                "id": 2,
                "body": "drive-by injection",
                "user": {"login": "rando"},
                "author_association": "NONE",
            },
            {
                "id": 3,
                "body": "foreman correction",
                "user": {"login": "bot"},
                "author_association": "NONE",
            },
        ]
        runner.when(
            ["api", "repos/owner/repo/issues/42/comments", "--paginate", "--slurp"],
            [comments],
        )
        kept, excluded = spec.trusted_comments(gh, cfg, 42)
        self.assertEqual([c["id"] for c in kept], [1, 3])  # viewer "bot" is trusted
        self.assertEqual(excluded, 1)


class PromptAssembly(unittest.TestCase):
    def test_tokens_fully_substituted_and_content_embedded(self):
        cfg = Config()
        gh, _runner = make_github(cfg)
        unit = unit_with(subs=[issue_json(43, body="sub body", title="Sub")])
        prompt = spec.assemble_dispatch_prompt(
            gh,
            cfg,
            unit,
            branch="foreman/feat/42-a-unit",
            default_branch="main",
            result_file="/tmp/result.json",
            comments=[{"id": 1, "body": "the correction", "user": {"login": "owner"}}],
            excluded_comments=2,
            handoffs=[(41, "use the new API")],
        )
        self.assertNotIn("%%", prompt)
        for expected in (
            "## Acceptance Criteria",
            "sub body",
            "the correction",
            "use the new API",
            "2 comment(s) from untrusted authors",
            "foreman/feat/42-a-unit",
            "task ci",
            "/tmp/result.json",
        ):
            self.assertIn(expected, prompt)

    def test_all_prompt_files_have_no_unknown_tokens(self):
        import re

        known = {
            "UNIT_NUMBER",
            "UNIT_TITLE",
            "BRANCH",
            "DEFAULT_BRANCH",
            "VERIFY_COMMAND",
            "RESULT_FILE",
            "COMMIT_TYPE",
            "PR_URL",
            "FAILURE_EXCERPT",
            "CONFLICTS",
            "THREADS",
            "TARGET",
            "CONCURRENT",
            "UNITS",
        }
        for path in spec.PROMPTS_DIR.glob("*.md"):
            tokens = set(re.findall(r"%%([A-Z_]+)%%", path.read_text(encoding="utf-8")))
            self.assertLessEqual(tokens, known, f"unknown tokens in {path.name}")


class Handoff(unittest.TestCase):
    def test_extract_handoff(self):
        body = "## Summary\n\nx\n\n## Handoff\n\nThe contract.\n\n---\nfooter"
        self.assertEqual(spec.extract_handoff(body), "The contract.")
        self.assertIsNone(spec.extract_handoff("## Summary\n\nnothing"))


if __name__ == "__main__":
    unittest.main()
