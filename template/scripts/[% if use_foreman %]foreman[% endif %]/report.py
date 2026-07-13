"""Human-facing output: summary tables, the per-unit status comment
(single, marker-identified, edited in place), and the consolidated
human-action queue. Display only — never read back for decisions.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from foreman.github import STATUS_MARKER, GitHub
from foreman.graph import Unit
from foreman.util import utc_now_iso, warn


def table(headers: list[str], rows: list[list[str]]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    def fmt(cells: list[str]) -> str:
        return "  ".join(
            cell.ljust(widths[index]) for index, cell in enumerate(cells)
        ).rstrip()

    lines = [fmt(headers), fmt(["-" * w for w in widths])]
    lines.extend(fmt(row) for row in rows)
    return "\n".join(lines)


@dataclass
class UnitStatus:
    """One unit's snapshot for the status comment + summary row."""

    unit: Unit
    state: str  # dispatched | pr-open | ready-to-merge | failed | blocked | held | waiting | merged
    branch: str = ""
    pr_url: str = ""
    checks: str = ""
    blockers: list[str] = field(default_factory=list)
    human_tasks: list[str] = field(default_factory=list)
    blocked_question: str = ""
    detail: str = ""


STATE_ICONS = {
    "dispatched": "🚧",
    "pr-open": "🔃",
    "ready-to-merge": "✅",
    "failed": "⚠️",
    "blocked": "❓",
    "held": "⏸",
    "waiting": "⏳",
    "merged": "🎉",
    "skipped": "⏭",
    "not-armed": "🔒",
}


def status_comment_body(status: UnitStatus) -> str:
    icon = STATE_ICONS.get(status.state, "•")
    lines = [
        STATUS_MARKER,
        "",
        f"**Foreman unit status: {icon} {status.state}**",
        "",
    ]
    if status.branch:
        lines.append(f"- Branch: `{status.branch}`")
    if status.pr_url:
        lines.append(f"- PR: {status.pr_url}")
    if status.checks:
        lines.append(f"- Checks: {status.checks}")
    for blocker in status.blockers:
        lines.append(f"- Blocker: {blocker}")
    if status.blocked_question:
        lines.append("")
        lines.append("**BLOCKED — needs a human answer:**")
        lines.append("")
        lines.append("> " + status.blocked_question.replace("\n", "\n> "))
    if status.human_tasks:
        lines.append("")
        lines.append("**Human-only tasks (foreman never attempts these):**")
        lines.append("")
        for task in status.human_tasks:
            lines.append(f"- [ ] {task}")
    if status.detail:
        lines.append("")
        lines.append(status.detail)
    lines.append("")
    lines.append(
        f"_Updated {utc_now_iso()} — this comment is edited in place by foreman; "
        "it is display-only and never read back for decisions._"
    )
    return "\n".join(lines) + "\n"


def update_status_comment(gh: GitHub, status: UnitStatus) -> None:
    try:
        gh.upsert_status_comment(status.unit.number, status_comment_body(status))
    except Exception as exc:  # display-only: never fail a run over a comment
        warn(f"#{status.unit.number}: status comment update failed: {exc}")


def summary_table(statuses: list[UnitStatus]) -> str:
    rows = []
    for status in statuses:
        icon = STATE_ICONS.get(status.state, "•")
        rows.append(
            [
                f"#{status.unit.number}",
                f"{icon} {status.state}",
                status.branch or "-",
                status.pr_url or "-",
                status.detail[:60] if status.detail else "-",
            ]
        )
    return table(["unit", "status", "branch", "pr", "detail"], rows)


def human_queue(
    *,
    merge_order: list[tuple[int, str]],
    human_tasks: dict[int, list[str]],
    blocked: dict[int, str],
    environmental: dict[int, str],
) -> str:
    """The consolidated 'what needs a human' list (most-repeated chore in M4)."""
    lines: list[str] = ["Human action queue:"]
    if merge_order:
        lines.append("")
        lines.append("  Pending merges (suggested dependency-aware order):")
        for position, (number, url) in enumerate(merge_order, 1):
            lines.append(f"    {position}. #{number}  {url}")
    if blocked:
        lines.append("")
        lines.append("  Blocked questions:")
        for number, question in sorted(blocked.items()):
            first = question.strip().splitlines()[0] if question.strip() else ""
            lines.append(f"    - #{number}: {first}")
    if human_tasks:
        lines.append("")
        lines.append("  Human-only tasks:")
        for number, tasks in sorted(human_tasks.items()):
            for task in tasks:
                lines.append(f"    - #{number}: {task}")
    if environmental:
        lines.append("")
        lines.append("  Environmental failures (fix the environment, not the code):")
        for number, detail in sorted(environmental.items()):
            lines.append(f"    - #{number}: {detail}")
    if len(lines) == 1:
        lines.append("  (empty — nothing waiting on a human)")
    return "\n".join(lines)
