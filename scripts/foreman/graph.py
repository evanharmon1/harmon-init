"""Units, dependency edges, cycles, waves — and deterministic doneness.

A unit is a parent issue (its sub-issues ride along as the internal task
list). Edges come from native `blocked-by` (primary) or a `Depends-on: #n`
body trailer (fallback); both present and disagreeing fails loud.

Doneness is the hardened A3 rule: a foreman-managed dependency counts as
satisfied only when its issue is closed AND a marker-carrying foreman PR
merged into the discovered default branch; an external dependency counts
when closed as completed (not_planned needs an explicit human override).
"""

from __future__ import annotations

import graphlib
import re
from dataclasses import dataclass, field

from foreman import inputs as inputs_mod
from foreman.config import Config
from foreman.github import GitHub
from foreman.util import ForemanError

DEPENDS_ON_RE = re.compile(
    r"^depends-on:\s*(?P<refs>#\d+(?:\s*,\s*#\d+)*)\s*$", re.I | re.M
)
MARKER_RE = re.compile(r"<!--\s*foreman:unit=#(?P<number>\d+)\b[^>]*-->")


@dataclass
class Unit:
    number: int
    title: str
    state: str
    state_reason: str | None
    body: str
    url: str
    labels: list[str]
    issue_type: str | None
    milestone: str | None
    parent: int | None
    sub_issues: list[dict] = field(default_factory=list)
    blocked_by: list[int] = field(default_factory=list)
    inputs: inputs_mod.UnitInputs | None = None
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def open(self) -> bool:
        return self.state.upper() == "OPEN"


@dataclass
class Target:
    """The resolved dispatch target: units + edges + context."""

    label: str  # human description, e.g. "milestone 'M4'" or "issue #12"
    units: dict[int, Unit]
    external_deps: set[int]
    milestone: str | None = None
    mode: str = "labels"  # resolved input-source mode (fields | labels)


def _unit_from_issue(issue: dict) -> Unit:
    return Unit(
        number=issue["number"],
        title=issue.get("title") or "",
        state=issue.get("state") or "OPEN",
        state_reason=issue.get("stateReason"),
        body=issue.get("body") or "",
        url=issue.get("url") or "",
        labels=[entry["name"] for entry in issue.get("labels") or []],
        issue_type=(issue.get("issueType") or {}).get("name"),
        milestone=(issue.get("milestone") or {}).get("title"),
        parent=(issue.get("parent") or {}).get("number"),
    )


def _dependency_numbers(issue: dict, unit: Unit) -> list[int]:
    native = [entry["number"] for entry in issue.get("blockedBy") or []]
    match = DEPENDS_ON_RE.search(unit.body)
    trailer = (
        [int(ref.strip().lstrip("#")) for ref in match.group("refs").split(",")]
        if match
        else []
    )
    if native and trailer and set(native) != set(trailer):
        unit.errors.append(
            f"#{unit.number}: native blocked-by ({sorted(native)}) disagrees with "
            f"Depends-on trailer ({sorted(trailer)}) — fix one source"
        )
        return sorted(set(native))
    return sorted(set(native or trailer))


def load_target(
    gh: GitHub, cfg: Config, *, milestone: str | None = None, issue: int | None = None
) -> Target:
    if bool(milestone) == bool(issue):
        raise ForemanError("exactly one of --milestone or --issue is required")

    issues: dict[int, dict] = {}
    if issue:
        root = gh.issue(issue)
        issues[root["number"]] = root
        for sub in root.get("subIssues") or []:
            issues[sub["number"]] = gh.issue(sub["number"])
        label = f"issue #{issue}"
        ms_title = None
    else:
        ms = gh.resolve_milestone(milestone or "")
        ms_title = ms["title"]
        for number in gh.milestone_issue_numbers(ms_title):
            issues[number] = gh.issue(number)
        label = f"milestone '{ms_title}' (#{ms['number']})"

    # Parent-unit granularity: an issue whose parent is also in the target set
    # is a sub-issue of that unit, not a unit of its own.
    units: dict[int, Unit] = {}
    for number, data in issues.items():
        parent = (data.get("parent") or {}).get("number")
        if parent and parent in issues:
            continue
        units[number] = _unit_from_issue(data)

    for unit in units.values():
        data = issues[unit.number]
        subs = []
        for ref in data.get("subIssues") or []:
            sub_number = ref["number"]
            subs.append(issues.get(sub_number) or gh.issue(sub_number))
        unit.sub_issues = sorted(subs, key=lambda entry: entry["number"])
        unit.blocked_by = _dependency_numbers(data, unit)

    external: set[int] = set()
    for unit in units.values():
        for dep in unit.blocked_by:
            if dep not in units:
                external.add(dep)
                unit.warnings.append(
                    f"#{unit.number}: dependency #{dep} is outside the target set "
                    "(external — ready only when satisfied)"
                )
    return Target(label=label, units=units, external_deps=external, milestone=ms_title)


def detect_cycle(target: Target) -> list[int] | None:
    sorter: graphlib.TopologicalSorter = graphlib.TopologicalSorter()
    for unit in target.units.values():
        internal = [dep for dep in unit.blocked_by if dep in target.units]
        sorter.add(unit.number, *internal)
    try:
        sorter.prepare()
    except graphlib.CycleError as exc:
        return list(exc.args[1])
    return None


def waves(target: Target) -> list[list[int]]:
    """Topological waves over internal edges (visualization + merge order)."""
    sorter: graphlib.TopologicalSorter = graphlib.TopologicalSorter()
    for unit in target.units.values():
        sorter.add(
            unit.number, *[dep for dep in unit.blocked_by if dep in target.units]
        )
    sorter.prepare()
    result: list[list[int]] = []
    while sorter.is_active():
        batch = sorted(sorter.get_ready())
        result.append(batch)
        sorter.done(*batch)
    return result


# ── doneness ─────────────────────────────────────────────────────────


@dataclass
class Doneness:
    satisfied: bool
    how: str
    warnings: list[str] = field(default_factory=list)


def foreman_prs_for_issue(gh: GitHub, cfg: Config, number: int) -> list[dict]:
    """Closing PRs that carry this unit's foreman marker, with merge facts."""
    issue = gh.issue(number)
    marked = []
    for ref in issue.get("closedByPullRequestsReferences") or []:
        pr = gh.pr_view(
            ref["number"],
            "number,url,body,merged,mergedAt,baseRefName,headRefName,author,state",
        )
        match = MARKER_RE.search(pr.get("body") or "")
        if match and int(match.group("number")) == number:
            marked.append(pr)
    return marked


def _branch_matches_unit(cfg: Config, branch: str, number: int) -> bool:
    return bool(re.match(rf"^{re.escape(cfg.branch_prefix)}/[^/]+/{number}-", branch))


def dependency_satisfied(
    gh: GitHub,
    cfg: Config,
    number: int,
    *,
    inputs: inputs_mod.UnitInputs | None = None,
    mode: str | None = None,
) -> Doneness:
    issue = gh.issue(number)
    if inputs is None and mode:
        inputs = inputs_mod.resolve(gh, cfg, issue, mode)
    if inputs is not None and inputs.satisfied_override:
        return Doneness(True, "human override (foreman=satisfied)")
    if (issue.get("state") or "OPEN").upper() != "CLOSED":
        return Doneness(False, "open")

    marked_prs = foreman_prs_for_issue(gh, cfg, number)
    if marked_prs and not (inputs is not None and inputs.external):
        expected_author = cfg.expected_login or gh.viewer()
        default_branch = gh.default_branch()
        for pr in marked_prs:
            problems = []
            if not pr.get("merged"):
                problems.append("not merged")
            if pr.get("baseRefName") != default_branch:
                problems.append(
                    f"base is {pr.get('baseRefName')}, not {default_branch}"
                )
            if (pr.get("author") or {}).get("login") != expected_author:
                problems.append(f"author is {(pr.get('author') or {}).get('login')}")
            if not _branch_matches_unit(cfg, pr.get("headRefName") or "", number):
                problems.append(
                    f"head branch {pr.get('headRefName')!r} not a foreman attempt"
                )
            if not problems:
                return Doneness(
                    True, f"foreman PR #{pr['number']} merged into {default_branch}"
                )
        return Doneness(
            False,
            "closed, but no foreman PR satisfies the merge chain",
            warnings=[
                f"#{number}: closed with foreman-marked PR(s) "
                f"({', '.join('#' + str(pr['number']) for pr in marked_prs)}) that did not "
                "merge cleanly into the default branch — resolve manually or mark "
                "foreman:satisfied"
            ],
        )

    reason = (issue.get("stateReason") or "").lower()
    if reason == "not_planned" and not cfg.allow_not_planned:
        return Doneness(
            False,
            "closed as not_planned",
            warnings=[
                f"#{number}: closed as not planned — remove the dependency edge or mark it "
                "foreman:satisfied if this is intentional"
            ],
        )
    how = (
        "external: closed as completed"
        if reason != "not_planned"
        else "external: not_planned (allowed by config)"
    )
    return Doneness(True, how)


def prepare_target(
    gh: GitHub, cfg: Config, *, milestone: str | None = None, issue: int | None = None
) -> Target:
    """Load the target and resolve human inputs for every unit."""
    target = load_target(gh, cfg, milestone=milestone, issue=issue)
    target.mode = inputs_mod.detect_mode(gh, cfg)
    for unit in target.units.values():
        unit.inputs = inputs_mod.resolve(gh, cfg, gh.issue(unit.number), target.mode)
    return target
