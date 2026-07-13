"""Fake `gh` transport: canned responses keyed by argv prefix, full call
recording, and a hard failure on any un-stubbed invocation — so a test can
assert not just what foreman did, but that it did nothing else.
"""

from __future__ import annotations

import json

from foreman.config import Config
from foreman.github import Gh, GitHub

REPO_VIEW = {
    "nameWithOwner": "owner/repo",
    "owner": {"login": "owner"},
    "name": "repo",
    "defaultBranchRef": {"name": "main"},
    "visibility": "PUBLIC",
}


class FakeRunner:
    def __init__(self):
        self.calls: list[tuple[list[str], str | None]] = []
        self._stubs: list[tuple[list[str], int, str]] = []

    def when(self, prefix: list[str], stdout: object = "", rc: int = 0) -> "FakeRunner":
        text = stdout if isinstance(stdout, str) else json.dumps(stdout)
        self._stubs.append((prefix, rc, text))
        return self

    def __call__(self, argv: list[str], input_text: str | None) -> tuple[int, str, str]:
        self.calls.append((list(argv), input_text))
        for prefix, rc, out in self._stubs:
            if argv[: len(prefix)] == prefix:
                return rc, out, ""
        raise AssertionError(f"unexpected gh call: {argv}")

    def called_with_prefix(self, prefix: list[str]) -> list[list[str]]:
        return [argv for argv, _ in self.calls if argv[: len(prefix)] == prefix]


def make_github(cfg: Config | None = None) -> tuple[GitHub, FakeRunner]:
    runner = FakeRunner()
    runner.when(["repo", "view"], REPO_VIEW)
    runner.when(["api", "user", "--jq", ".login"], "bot\n")
    gh = GitHub(Gh(runner), cfg or Config())
    return gh, runner


def issue_json(
    number: int,
    *,
    state: str = "OPEN",
    state_reason: str | None = None,
    body: str = "",
    title: str | None = None,
    labels: list[str] | None = None,
    issue_type: str | None = None,
    blocked_by: list[int] | None = None,
    sub_issues: list[int] | None = None,
    parent: int | None = None,
    closed_by_prs: list[int] | None = None,
) -> dict:
    return {
        "number": number,
        "title": title or f"Unit {number}",
        "state": state,
        "stateReason": state_reason,
        "body": body,
        "url": f"https://github.com/owner/repo/issues/{number}",
        "labels": [{"name": name} for name in labels or []],
        "milestone": None,
        "issueType": {"name": issue_type} if issue_type else None,
        "parent": {"number": parent} if parent else None,
        "subIssues": [{"number": n} for n in sub_issues or []],
        "blockedBy": [{"number": n} for n in blocked_by or []],
        "closedByPullRequestsReferences": [{"number": n} for n in closed_by_prs or []],
    }


def pr_json(
    number: int,
    *,
    unit: int | None = None,
    merged: bool = True,
    base: str = "main",
    head: str | None = None,
    author: str = "bot",
    body: str | None = None,
) -> dict:
    marker = (
        f"<!-- foreman:unit=#{unit} spec-hash=x base=y schema=1 -->" if unit else ""
    )
    return {
        "number": number,
        "url": f"https://github.com/owner/repo/pull/{number}",
        "body": body if body is not None else marker,
        "merged": merged,
        "mergedAt": "2026-07-12T00:00:00Z" if merged else None,
        "baseRefName": base,
        "headRefName": head or (f"foreman/feat/{unit}-x" if unit else "feature/x"),
        "author": {"login": author},
        "state": "MERGED" if merged else "OPEN",
    }
