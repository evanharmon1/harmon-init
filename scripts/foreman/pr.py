"""Deterministic PR opening: freshness gate, machine-readable markers,
Conventional-Commit titles, Closes/Refs wiring, Handoff + Human-only-tasks
sections. The agent never opens PRs — foreman does, after its own verify.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from foreman.backend import ResultContract
from foreman.config import Config
from foreman.github import GitHub
from foreman.graph import Unit, dependency_satisfied
from foreman.spec import spec_hash, trusted_comments
from foreman.util import warn

TITLE_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?: (?P<subject>.+)$"
)
MAX_TITLE = 100


def marker(unit_number: int, spec_hash_hex: str, base_sha: str) -> str:
    return (
        f"<!-- foreman:unit=#{unit_number} spec-hash={spec_hash_hex} "
        f"base={base_sha} schema=1 -->"
    )


@dataclass
class Freshness:
    ok: bool
    problems: list[str] = field(default_factory=list)


def freshness_check(
    gh: GitHub,
    cfg: Config,
    unit: Unit,
    *,
    recorded_hash: str,
    branch: str,
    mode: str | None = None,
) -> Freshness:
    """Re-check eligibility + spec drift immediately before push/PR-create."""
    problems: list[str] = []
    issue = gh.issue(unit.number, fresh=True)
    if (issue.get("state") or "").upper() != "OPEN":
        problems.append("issue is no longer open")
    fresh_unit_body = issue.get("body") or ""
    comments, _ = trusted_comments(gh, cfg, unit.number)
    check_unit = Unit(
        number=unit.number,
        title=issue.get("title") or unit.title,
        state=issue.get("state") or "OPEN",
        state_reason=issue.get("stateReason"),
        body=fresh_unit_body,
        url=unit.url,
        labels=[entry["name"] for entry in issue.get("labels") or []],
        issue_type=unit.issue_type,
        milestone=unit.milestone,
        parent=unit.parent,
        sub_issues=[
            gh.issue(sub["number"], fresh=True) for sub in issue.get("subIssues") or []
        ],
    )
    if spec_hash(check_unit, comments) != recorded_hash:
        problems.append(
            "spec drifted since dispatch (issue/sub-issue/comment content changed)"
        )
    for dep in unit.blocked_by:
        done = dependency_satisfied(gh, cfg, dep, mode=mode)
        if not done.satisfied:
            problems.append(f"dependency #{dep} regressed to unsatisfied ({done.how})")
    existing = gh.prs(head=branch, state="open")
    if existing:
        problems.append(f"an open PR already exists for {branch}: {existing[0]['url']}")
    return Freshness(ok=not problems, problems=problems)


def pr_title(cfg: Config, unit: Unit, result: ResultContract) -> str:
    commit_type = unit.inputs.commit_type if unit.inputs else cfg.default_type
    proposed = (result.proposed_pr_title or "").strip()
    match = TITLE_RE.match(proposed)
    if match:
        scope = f"({match.group('scope')})" if match.group("scope") else ""
        title = f"{commit_type}{scope}: {match.group('subject')}"
    else:
        if proposed:
            warn(f"#{unit.number}: proposed_pr_title not conventional; regenerating")
        title = f"{commit_type}: {unit.title}"
    if len(title) > MAX_TITLE:
        title = title[: MAX_TITLE - 1].rstrip() + "…"
    return title


def pr_body(
    cfg: Config,
    unit: Unit,
    result: ResultContract,
    *,
    human_tasks: list[str],
    spec_hash_hex: str,
    base_sha: str,
) -> str:
    lines: list[str] = []
    lines.append(marker(unit.number, spec_hash_hex, base_sha))
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(result.summary.strip() or "_(no summary provided)_")
    lines.append("")

    lines.append("## Test evidence (acceptance criteria → tests)")
    lines.append("")
    lines.append(
        "_Reviewing these tests is reviewing the spec interpretation — the mapping "
        "below is the agent's claim, verified only for existence by CI._"
    )
    lines.append("")
    for entry in result.ac_test_map:
        tests = ", ".join(f"`{t}`" for t in entry.get("tests", [])) or "_none_"
        lines.append(f"- {entry.get('criterion', '').strip()} → {tests}")
    lines.append("")

    close_word = "Refs" if human_tasks else "Closes"
    if human_tasks:
        lines.append("## Human-only tasks (this PR must NOT auto-close the parent)")
        lines.append("")
        for task in human_tasks:
            lines.append(f"- [ ] {task}")
        lines.append("")
    lines.append(f"{close_word} #{unit.number}")
    for sub in unit.sub_issues:
        if (sub.get("state") or "").upper() == "OPEN":
            lines.append(f"Closes #{sub['number']}")
    lines.append("")

    lines.append("## Handoff")
    lines.append("")
    lines.append(
        result.handoff.strip() or "_(nothing downstream depends on internals here)_"
    )
    lines.append("")
    lines.append("---")
    lines.append(
        f"_Opened by foreman after a green `{ ' '.join(cfg.verify_command) }` in the unit's "
        "worktree. Merging is a human decision; foreman never merges._"
    )
    return "\n".join(lines) + "\n"


def open_pr(
    gh: GitHub,
    cfg: Config,
    unit: Unit,
    *,
    title: str,
    body: str,
    branch: str,
    base: str,
) -> str:
    gh.ensure_labels()
    url = gh.create_pr(
        title=title, body=body, head=branch, base=base, labels=["foreman-dispatched"]
    )
    return url
