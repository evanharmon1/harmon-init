"""Command-line interface. Taskfile targets are thin wrappers over these
subcommands: plan, preflight, dispatch, shepherd, watch, status, retry,
cleanup. plan/status/preflight-draft are read-only by construction
(github.GitHub.read_only) — the write contract is enforced, not promised.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from foreman import backend as backend_mod
from foreman import dispatch as dispatch_mod
from foreman import inputs as inputs_mod
from foreman import report, shepherd as shepherd_mod, spec, watch as watch_mod, worktree
from foreman.config import Config, load as load_config
from foreman.github import Gh, GitHub
from foreman.graph import (
    Target,
    dependency_satisfied,
    detect_cycle,
    prepare_target,
    waves,
)
from foreman.util import ForemanError, error, info, repo_root, warn, write_text


def _add_target_args(parser: argparse.ArgumentParser, *, required: bool = True) -> None:
    group = parser.add_mutually_exclusive_group(required=required)
    group.add_argument("--milestone", help="milestone number or exact title")
    group.add_argument(
        "--issue", type=int, help="single issue number (with its sub-issues)"
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="foreman",
        description="Deterministic supervisor: dispatch ready issues to headless "
        "agents, verify, open PRs, shepherd them to mergeable. Humans merge.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser(
        "plan", help="dry run: graph, waves, ready set (no side effects)"
    )
    _add_target_args(p_plan)

    p_preflight = sub.add_parser(
        "preflight",
        help="read-only agent analysis of the target; drafts correction comments",
    )
    _add_target_args(p_preflight)
    p_preflight.add_argument(
        "--post",
        action="store_true",
        help="post the human-reviewed drafted comments from .foreman/preflight/comments/",
    )

    p_dispatch = sub.add_parser(
        "dispatch", help="dispatch ready units → verify → open PRs"
    )
    _add_target_args(p_dispatch)
    p_dispatch.add_argument("--max-parallel", type=int, default=None)

    sub.add_parser(
        "shepherd", help="repair CI, adjudicate reviews, rebase, report merge order"
    )

    p_watch = sub.add_parser(
        "watch", help="loop plan→dispatch→shepherd with heartbeats"
    )
    _add_target_args(p_watch)
    p_watch.add_argument("--interval", default="5m", help="tick interval (300, 5m, 1h)")
    p_watch.add_argument(
        "--budget-usd", type=float, default=None, help="aggregate stop budget"
    )

    p_status = sub.add_parser("status", help="read-only snapshot + human-action queue")
    _add_target_args(p_status)

    p_retry = sub.add_parser("retry", help="re-dispatch a unit whose PR a human closed")
    p_retry.add_argument("--unit", type=int, required=True)

    sub.add_parser(
        "cleanup", help="prune worktrees + foreman branches for closed units"
    )
    return parser


def _context(read_only: bool) -> tuple[Config, Path, GitHub]:
    root = repo_root()
    cfg = load_config(root)
    gh = GitHub(Gh(), cfg)
    gh.read_only = read_only
    return cfg, root, gh


def _print_plan(gh: GitHub, cfg: Config, target: Target) -> int:
    remote_name = worktree.remote(cfg)
    print(f"Target: {target.label}")
    print(f"Inputs: {inputs_mod.describe_mode(target.mode, cfg)}")
    print(f"Base:   {remote_name}/{gh.default_branch()}")
    print()

    cycle = detect_cycle(target)
    if cycle:
        error("dependency cycle: " + " -> ".join(f"#{n}" for n in cycle))
        return 1

    fail_loud = False
    ready, skipped = dispatch_mod.eligibility(gh, cfg, target)
    by_number = {o.unit.number: o for o in skipped}
    print("Waves (dependency order):")
    for index, wave in enumerate(waves(target), 1):
        print(f"  wave {index}:")
        for number in wave:
            unit = target.units[number]
            spec_info = spec.validate(unit)
            if unit in ready:
                state = "READY"
            elif not unit.open:
                state = "closed"
            else:
                outcome = by_number.get(number)
                state = outcome.status if outcome else "waiting"
            notes = []
            for dep in unit.blocked_by:
                dep_inputs = target.units[dep].inputs if dep in target.units else None
                done = dependency_satisfied(
                    gh, cfg, dep, inputs=dep_inputs, mode=target.mode
                )
                mark = "✓" if done.satisfied else "✗"
                notes.append(f"{mark}#{dep} ({done.how})")
                for note in done.warnings:
                    warn(note)
            problems = (
                unit.errors
                + (unit.inputs.errors if unit.inputs else [])
                + spec_info.errors
            )
            if problems:
                fail_loud = True
            line = f"    #{number} [{state}] {unit.title}"
            commit_type = unit.inputs.commit_type if unit.inputs else cfg.default_type
            line += f"  (type={commit_type}"
            if notes:
                line += f"; deps: {', '.join(notes)}"
            line += ")"
            print(line)
            for problem in problems:
                print(f"      ERROR: {problem}")
            for warning in spec_info.warnings + (
                unit.inputs.warnings if unit.inputs else []
            ):
                print(f"      note: {warning}")
    print()
    print(f"Ready now: {', '.join('#' + str(u.number) for u in ready) or '(none)'}")

    notices = _concurrent_activity(gh, target)
    if notices:
        print()
        print(
            "Concurrent-activity notice (collisions possible — preflight should look):"
        )
        for notice in notices:
            print(f"  - {notice}")
    return 1 if fail_loud else 0


def _concurrent_activity(gh: GitHub, target: Target) -> list[str]:
    notices = []
    for ms in gh.milestones(state="open"):
        if target.milestone and ms["title"] == target.milestone:
            continue
        if ms.get("open_issues"):
            notices.append(
                f"open milestone '{ms['title']}' with {ms['open_issues']} open issue(s)"
            )
    others = [
        p
        for p in gh.prs(state="open")
        if "foreman-dispatched"
        not in [label["name"] for label in p.get("labels") or []]
    ]
    if others:
        notices.append(
            f"{len(others)} open non-foreman PR(s) may land on the default branch mid-run"
        )
    return notices


def cmd_plan(args: argparse.Namespace) -> int:
    cfg, _root, gh = _context(read_only=True)
    target = prepare_target(gh, cfg, milestone=args.milestone, issue=args.issue)
    return _print_plan(gh, cfg, target)


def cmd_dispatch(args: argparse.Namespace) -> int:
    cfg, root, gh = _context(read_only=False)
    backend_mod.assert_backend_version(cfg)
    target = prepare_target(gh, cfg, milestone=args.milestone, issue=args.issue)
    cycle = detect_cycle(target)
    if cycle:
        error(
            "refusing to dispatch: dependency cycle "
            + " -> ".join(f"#{n}" for n in cycle)
        )
        return 1
    outcomes = dispatch_mod.run_dispatch(
        gh, cfg, root, target, max_parallel=args.max_parallel
    )
    statuses = [
        report.UnitStatus(
            unit=o.unit,
            state=o.status,
            branch=o.branch,
            pr_url=o.pr_url,
            detail=o.detail,
        )
        for o in outcomes
    ]
    print()
    print(report.summary_table(statuses))
    failed = [o for o in outcomes if o.status in ("failed", "blocked", "stale")]
    for outcome in failed:
        print(f"\n#{outcome.unit.number} {outcome.status}: {outcome.detail}")
    return 1 if failed else 0


def cmd_shepherd(_args: argparse.Namespace) -> int:
    cfg, root, gh = _context(read_only=False)
    backend_mod.assert_backend_version(cfg)
    shep = shepherd_mod.run_shepherd(gh, cfg, root)
    if shep.worked:
        rows = [
            [f"#{w.unit_number}", f"PR #{w.number}", w.state, w.detail[:70]]
            for w in shep.worked
        ]
        print(report.table(["unit", "pr", "state", "detail"], rows))
    if shep.ready_order:
        print()
        print("Suggested merge order (foreman never merges):")
        for index, (number, url) in enumerate(shep.ready_order, 1):
            print(f"  {index}. #{number}  {url}")
    if shep.environmental:
        print()
        for number, detail in sorted(shep.environmental.items()):
            print(f"NEEDS HUMAN #{number}: {detail}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    cfg, root, gh = _context(read_only=True)
    target = prepare_target(gh, cfg, milestone=args.milestone, issue=args.issue)
    open_prs = shepherd_mod.open_foreman_prs(gh)
    prs_by_unit = {p["_unit"]: p for p in open_prs}
    statuses: list[report.UnitStatus] = []
    human_tasks: dict[int, list[str]] = {}
    blocked: dict[int, str] = {}
    ready: list[shepherd_mod.PrWork] = []
    for number in sorted(target.units):
        unit = target.units[number]
        spec_info = spec.validate(unit)
        tasks = spec.human_only_tasks(unit, spec_info) if not spec_info.errors else []
        if tasks and unit.open:
            human_tasks[number] = tasks
        if not unit.open:
            done = dependency_satisfied(
                gh, cfg, number, inputs=unit.inputs, mode=target.mode
            )
            statuses.append(
                report.UnitStatus(unit=unit, state="merged", detail=done.how)
            )
            continue
        pr = prs_by_unit.get(number)
        if pr:
            status = gh.pr_status(pr["number"])
            checks_state, _failed = shepherd_mod.classify_checks(
                status.get("statusCheckRollup")
            )
            labels = [label["name"] for label in status.get("labels") or []]
            state = "ready-to-merge" if "ready-to-merge" in labels else "pr-open"
            if state == "ready-to-merge":
                ready.append(
                    shepherd_mod.PrWork(
                        number=pr["number"],
                        unit_number=number,
                        branch=status["headRefName"],
                        url=status["url"],
                        title=status["title"],
                    )
                )
            statuses.append(
                report.UnitStatus(
                    unit=unit,
                    state=state,
                    branch=status["headRefName"],
                    pr_url=status["url"],
                    checks=checks_state,
                    detail=status["title"],
                )
            )
            continue
        blocked_file = root / cfg.runtime_dir / "units" / str(number) / "result.json"
        detail = ""
        if blocked_file.exists():
            contract, _errors = backend_mod.read_result(
                blocked_file.parent, worktree.worktree_path(cfg, root, unit)
            )
            if contract and contract.status == "blocked" and contract.blocked_question:
                blocked[number] = contract.blocked_question
                detail = "blocked on a question"
        outcome_state = "waiting"
        if unit.inputs and unit.inputs.hold:
            outcome_state = "held"
        elif unit.inputs and not unit.inputs.armed:
            outcome_state = "not-armed"
        statuses.append(
            report.UnitStatus(unit=unit, state=outcome_state, detail=detail)
        )
    print(report.summary_table(statuses))
    print()
    print(
        report.human_queue(
            merge_order=shepherd_mod.merge_order(gh, ready),
            human_tasks=human_tasks,
            blocked=blocked,
            environmental={},
        )
    )
    return 0


def cmd_retry(args: argparse.Namespace) -> int:
    cfg, root, gh = _context(read_only=False)
    backend_mod.assert_backend_version(cfg)
    target = prepare_target(gh, cfg, milestone=None, issue=args.unit)
    unit = target.units[args.unit]
    if not unit.open:
        error(f"#{args.unit} is closed — nothing to retry")
        return 1
    remote_name = worktree.remote(cfg)
    attempts = worktree.attempt_branches(cfg, remote_name, unit.number)
    open_prs = [p for p in gh.prs(state="open") if p["headRefName"] in attempts]
    if open_prs:
        error(
            f"#{args.unit} still has an open PR ({open_prs[0]['url']}) — close it first"
        )
        return 1
    stale_wt = worktree.worktree_path(cfg, root, unit)
    if stale_wt.exists():
        info(f"removing preserved worktree {stale_wt}")
        worktree.remove(stale_wt)
    outcome = dispatch_mod.dispatch_unit(gh, cfg, root, unit, mode=target.mode)
    print(
        report.summary_table(
            [
                report.UnitStatus(
                    unit=unit,
                    state=outcome.status,
                    branch=outcome.branch,
                    pr_url=outcome.pr_url,
                    detail=outcome.detail,
                )
            ]
        )
    )
    return 0 if outcome.dispatched else 1


def cmd_cleanup(_args: argparse.Namespace) -> int:
    cfg, root, gh = _context(read_only=False)
    remote_name = worktree.remote(cfg)
    worktree.fetch(remote_name)
    import re as _re

    from foreman.util import run as _run

    pattern = _re.compile(rf"^{_re.escape(cfg.branch_prefix)}/[^/]+/(?P<number>\d+)-")
    by_unit: dict[int, list[str]] = {}
    refs = _run(["git", "ls-remote", "--heads", remote_name]).stdout
    local = _run(
        ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads/"]
    ).stdout
    names = {
        line.split("\t")[1][len("refs/heads/") :]
        for line in refs.splitlines()
        if "\t" in line
    }
    names.update(name for name in local.split() if name)
    for name in sorted(names):
        match = pattern.match(name)
        if match:
            by_unit.setdefault(int(match.group("number")), []).append(name)

    removed = 0
    for number, branches in sorted(by_unit.items()):
        issue = gh.issue(number)
        if (issue.get("state") or "").upper() != "CLOSED":
            continue
        if any(gh.prs(head=branch, state="open") for branch in branches):
            continue
        for branch in branches:
            info(f"cleanup: deleting branch {branch} (unit #{number} closed)")
            worktree.delete_branch(cfg, remote_name, branch)
            removed += 1
        for path in (root / cfg.worktrees_dir).glob(f"{number}-*"):
            worktree.remove(path)
        pr_wt = root / cfg.worktrees_dir / f"pr-{number}"
        if pr_wt.exists():
            worktree.remove(pr_wt)
    info(f"cleanup: removed {removed} branch(es); in-flight units untouched")
    return 0


def cmd_preflight(args: argparse.Namespace) -> int:
    cfg, root, gh = _context(read_only=not args.post)
    comments_dir = root / cfg.runtime_dir / "preflight" / "comments"
    if args.post:
        posted = 0
        for path in sorted(comments_dir.glob("*.md")):
            number = int(path.stem)
            body = path.read_text(encoding="utf-8").strip()
            if not body:
                continue
            gh.post_preflight_correction(number, body, human_approved=True)
            path.rename(path.with_suffix(".posted"))
            posted += 1
            info(f"posted correction comment on #{number}")
        if not posted:
            warn(f"no draft comments found in {comments_dir}")
        return 0

    backend_mod.assert_backend_version(cfg)
    target = prepare_target(gh, cfg, milestone=args.milestone, issue=args.issue)
    bodies = []
    for number in sorted(target.units):
        unit = target.units[number]
        comments, _excluded = spec.trusted_comments(gh, cfg, number)
        bodies.append(f"# Unit #{number}: {unit.title}\n\n{unit.body}")
        for sub in unit.sub_issues:
            bodies.append(
                f"## Sub-issue #{sub['number']}: {sub.get('title','')}\n\n{sub.get('body') or ''}"
            )
        for comment in comments:
            bodies.append(f"### Comment on #{number}\n\n{comment.get('body') or ''}")
    tokens = {
        "TARGET": target.label,
        "CONCURRENT": "\n".join(_concurrent_activity(gh, target)) or "(none detected)",
        "UNITS": "\n\n---\n\n".join(bodies),
    }
    prompt = spec.load_prompt("preflight", tokens)
    run_dir = root / cfg.runtime_dir / "preflight"
    run_dir.mkdir(parents=True, exist_ok=True)
    prompt_file = run_dir / "prompt.md"
    write_text(prompt_file, prompt)
    adapter = backend_mod.adapter_path(cfg.backend)
    os.environ["FOREMAN_READONLY"] = "1"
    try:
        result = backend_mod.run_backend(
            cfg,
            adapter,
            cwd=root,
            unit_run_dir=run_dir,
            prompt_file=prompt_file,
            timeout_min=cfg.shepherd_timeout_min,
        )
    finally:
        os.environ.pop("FOREMAN_READONLY", None)
    findings_src = run_dir / "adapter-stdout.log"
    findings = findings_src.read_text(encoding="utf-8") if findings_src.exists() else ""
    findings_file = run_dir / "findings.md"
    write_text(findings_file, findings)
    drafted = _extract_draft_comments(findings)
    comments_dir.mkdir(parents=True, exist_ok=True)
    for number, body in drafted.items():
        write_text(comments_dir / f"{number}.md", body)
    info(f"preflight findings: {findings_file}")
    if drafted:
        info(
            f"{len(drafted)} drafted correction comment(s) in {comments_dir} — review/edit "
            "them, then run: task foreman:preflight -- --post"
        )
    else:
        info("no correction comments drafted")
    return 0 if result.ok else 1


def _extract_draft_comments(findings: str) -> dict[int, str]:
    import re as _re

    drafted: dict[int, str] = {}
    parts = _re.split(r"^## DRAFT COMMENT FOR #(\d+)\s*$", findings, flags=_re.M)
    for index in range(1, len(parts) - 1, 2):
        number = int(parts[index])
        body = parts[index + 1].split("\n## ")[0].strip()
        if body:
            drafted[number] = body
    return drafted


def cmd_watch(args: argparse.Namespace) -> int:
    cfg, root, _gh = _context(read_only=False)
    backend_mod.assert_backend_version(cfg)
    return watch_mod.run_watch(
        cfg,
        root,
        milestone=args.milestone,
        issue=args.issue,
        interval_s=watch_mod.parse_interval(args.interval),
        budget_usd=args.budget_usd,
    )


_COMMANDS = {
    "plan": cmd_plan,
    "preflight": cmd_preflight,
    "dispatch": cmd_dispatch,
    "shepherd": cmd_shepherd,
    "watch": cmd_watch,
    "status": cmd_status,
    "retry": cmd_retry,
    "cleanup": cmd_cleanup,
}


def main(argv: list[str] | None = None) -> int:
    if sys.version_info < (3, 11):
        print("foreman: Python >= 3.11 required (tomllib)", file=sys.stderr)
        return 2
    args = _parser().parse_args(argv)
    try:
        return _COMMANDS[args.command](args)
    except ForemanError as exc:
        error(str(exc))
        return 1
    except KeyboardInterrupt:
        error("interrupted")
        return 130
