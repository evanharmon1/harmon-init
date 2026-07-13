"""Per-unit dispatch pipeline: isolate → prompt → agent → verify → freshness
gate → push → PR → status comment. Bounded concurrency across units.

Idempotent by derivation: a unit with an existing attempt branch or open PR
is skipped — no state file records "dispatched"; git and GitHub do.
"""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from foreman import backend as backend_mod
from foreman import pr as pr_mod
from foreman import report, spec, verify, worktree
from foreman.config import Config
from foreman.github import GitHub
from foreman.graph import Target, Unit, dependency_satisfied
from foreman.util import ForemanError, info, write_text

RETRIGGER_SUBJECT = "chore: retrigger ci (foreman)"


@dataclass
class Outcome:
    unit: Unit
    status: (
        str  # pr-open | failed | blocked | waiting | skipped | held | not-armed | stale
    )
    branch: str = ""
    pr_url: str = ""
    detail: str = ""
    cost_usd: float | None = None
    duration_s: float = 0.0

    @property
    def dispatched(self) -> bool:
        return self.status == "pr-open"


def eligibility(
    gh: GitHub, cfg: Config, target: Target
) -> tuple[list[Unit], list[Outcome]]:
    """Split units into ready-to-dispatch and skipped (with reasons)."""
    ready: list[Unit] = []
    skipped: list[Outcome] = []
    remote_name = worktree.remote(cfg)
    for number in sorted(target.units):
        unit = target.units[number]
        inp = unit.inputs
        assert inp is not None, "inputs must be resolved before eligibility"
        if not unit.open:
            skipped.append(Outcome(unit, "skipped", detail="already closed"))
            continue
        if unit.errors or (inp and inp.errors):
            problems = "; ".join(unit.errors + inp.errors)
            skipped.append(Outcome(unit, "failed", detail=f"contract: {problems}"))
            continue
        if inp.hold:
            skipped.append(Outcome(unit, "held", detail="foreman=hold"))
            continue
        if not inp.armed:
            skipped.append(
                Outcome(unit, "not-armed", detail="no foreman approval input")
            )
            continue
        spec_info = spec.validate(unit)
        if spec_info.errors:
            skipped.append(Outcome(unit, "failed", detail="; ".join(spec_info.errors)))
            continue
        unmet = []
        for dep in unit.blocked_by:
            dep_inputs = target.units[dep].inputs if dep in target.units else None
            done = dependency_satisfied(
                gh, cfg, dep, inputs=dep_inputs, mode=target.mode
            )
            if not done.satisfied:
                unmet.append(f"#{dep} ({done.how})")
        if unmet:
            skipped.append(
                Outcome(unit, "waiting", detail=f"blocked by {', '.join(unmet)}")
            )
            continue
        attempts = worktree.attempt_branches(cfg, remote_name, unit.number)
        open_prs = [p for p in gh.prs(state="open") if p["headRefName"] in attempts]
        if open_prs:
            skipped.append(
                Outcome(
                    unit,
                    "skipped",
                    branch=open_prs[0]["headRefName"],
                    pr_url=open_prs[0]["url"],
                    detail="open PR exists (in flight)",
                )
            )
            continue
        in_flight = [b for b in attempts if gh.branch_exists_remote(b)]
        if in_flight:
            skipped.append(
                Outcome(
                    unit,
                    "skipped",
                    branch=in_flight[0],
                    detail="attempt branch exists (in flight or awaiting retry/cleanup)",
                )
            )
            continue
        ready.append(unit)
    return ready, skipped


def dispatch_unit(
    gh: GitHub, cfg: Config, root: Path, unit: Unit, *, mode: str | None = None
) -> Outcome:
    started = time.monotonic()
    remote_name = worktree.remote(cfg)
    default_branch = gh.default_branch()
    base = f"{remote_name}/{default_branch}"

    existing = worktree.attempt_branches(cfg, remote_name, unit.number)
    branch = worktree.next_attempt_branch(worktree.branch_name(cfg, unit), existing)
    wt_path = worktree.worktree_path(cfg, root, unit)
    if wt_path.exists():
        return Outcome(
            unit,
            "skipped",
            branch=branch,
            detail=f"worktree already exists ({wt_path}) — run foreman:retry or cleanup",
        )

    run_dir = backend_mod.unit_dir(cfg, root, unit.number)
    comments, excluded = spec.trusted_comments(gh, cfg, unit.number)
    recorded_hash = spec.spec_hash(unit, comments)
    base_sha = worktree.base_sha(remote_name, default_branch)
    write_text(
        run_dir / "dispatch-meta.txt",
        f"spec_hash={recorded_hash}\nbase_sha={base_sha}\nbranch={branch}\n",
    )

    handoffs = spec.collect_handoffs(gh, cfg, unit)
    prompt_text = spec.assemble_dispatch_prompt(
        gh,
        cfg,
        unit,
        branch=branch,
        default_branch=default_branch,
        result_file=str(run_dir / "result.json"),
        comments=comments,
        excluded_comments=excluded,
        handoffs=handoffs,
    )
    prompt_file = run_dir / "prompt.md"
    write_text(prompt_file, prompt_text)

    worktree.add(wt_path, branch, base)
    outcome = _run_agent_and_verify(
        gh,
        cfg,
        unit,
        wt_path,
        run_dir,
        prompt_file,
        branch,
        base,
        recorded_hash,
        base_sha,
        mode=mode,
    )
    outcome.duration_s = time.monotonic() - started
    _post_status(gh, unit, outcome)
    if outcome.status == "pr-open":
        worktree.remove(wt_path)  # PR branch is pushed; shepherd recreates on demand
    return outcome


def _run_agent_and_verify(
    gh: GitHub,
    cfg: Config,
    unit: Unit,
    wt_path: Path,
    run_dir: Path,
    prompt_file: Path,
    branch: str,
    base: str,
    recorded_hash: str,
    base_sha: str,
    *,
    mode: str | None = None,
) -> Outcome:
    inp = unit.inputs
    backend_name = inp.backend if inp and inp.backend else cfg.backend
    adapter = backend_mod.adapter_path(backend_name)
    timeout_min = (
        inp.timeout_min if inp and inp.timeout_min else cfg.dispatch_timeout_min
    )

    result = backend_mod.run_backend(
        cfg,
        adapter,
        cwd=wt_path,
        unit_run_dir=run_dir,
        prompt_file=prompt_file,
        timeout_min=timeout_min,
    )
    if result.quota_wait:
        backend_mod.write_resume_state(
            run_dir, wt_path, "backend usage window exhausted"
        )
        return Outcome(
            unit,
            "waiting",
            branch=branch,
            cost_usd=result.cost_usd,
            detail="backend usage limit reached — will resume after the window resets",
        )
    if result.timed_out:
        backend_mod.write_resume_state(
            run_dir, wt_path, f"agent timed out after {timeout_min}m"
        )
        return Outcome(
            unit,
            "failed",
            branch=branch,
            cost_usd=result.cost_usd,
            detail=f"agent timed out after {timeout_min}m (session preserved)",
        )

    contract, contract_errors = backend_mod.read_result(run_dir, wt_path)
    if contract is not None and contract.status == "blocked":
        backend_mod.write_resume_state(run_dir, wt_path, "agent blocked on a question")
        return Outcome(
            unit,
            "blocked",
            branch=branch,
            cost_usd=result.cost_usd,
            detail=(
                (contract.blocked_question or "").strip().splitlines()[0]
                if contract.blocked_question
                else "blocked without a question"
            ),
        )
    if result.returncode != 0:
        backend_mod.write_resume_state(
            run_dir, wt_path, f"agent exited {result.returncode}"
        )
        return Outcome(
            unit,
            "failed",
            branch=branch,
            cost_usd=result.cost_usd,
            detail=f"agent exited {result.returncode} (worktree + session preserved)",
        )
    if contract is None:
        backend_mod.write_resume_state(run_dir, wt_path, "invalid result contract")
        return Outcome(
            unit,
            "failed",
            branch=branch,
            cost_usd=result.cost_usd,
            detail="result contract invalid: " + "; ".join(contract_errors),
        )

    if worktree.commits_ahead(wt_path, base) == 0:
        backend_mod.write_resume_state(run_dir, wt_path, "agent made no commits")
        return Outcome(
            unit,
            "failed",
            branch=branch,
            cost_usd=result.cost_usd,
            detail="agent completed but made no commits",
        )
    if not worktree.is_clean(wt_path):
        backend_mod.write_resume_state(
            run_dir, wt_path, "uncommitted changes left in worktree"
        )
        return Outcome(
            unit,
            "failed",
            branch=branch,
            cost_usd=result.cost_usd,
            detail="agent left uncommitted changes in the worktree",
        )

    ok, verify_tail = verify.run_verify(cfg, wt_path, run_dir)
    if not ok:
        backend_mod.write_resume_state(
            run_dir, wt_path, "verification failed:\n\n" + verify_tail
        )
        return Outcome(
            unit,
            "failed",
            branch=branch,
            cost_usd=result.cost_usd,
            detail=f"verification failed ({' '.join(cfg.verify_command)})",
        )

    fresh = pr_mod.freshness_check(
        gh, cfg, unit, recorded_hash=recorded_hash, branch=branch, mode=mode
    )
    if not fresh.ok:
        backend_mod.write_resume_state(
            run_dir, wt_path, "freshness gate: " + "; ".join(fresh.problems)
        )
        return Outcome(
            unit,
            "stale",
            branch=branch,
            cost_usd=result.cost_usd,
            detail="not pushed — " + "; ".join(fresh.problems),
        )

    spec_info = spec.validate(unit)
    human_tasks = spec.human_only_tasks(unit, spec_info)
    remote_name = worktree.remote(cfg)
    worktree.push(wt_path, remote_name, branch, first=True)
    title = pr_mod.pr_title(cfg, unit, contract)
    body = pr_mod.pr_body(
        cfg,
        unit,
        contract,
        human_tasks=human_tasks,
        spec_hash_hex=recorded_hash,
        base_sha=base_sha,
    )
    url = pr_mod.open_pr(
        gh, cfg, unit, title=title, body=body, branch=branch, base=gh.default_branch()
    )
    return Outcome(
        unit,
        "pr-open",
        branch=branch,
        pr_url=url,
        cost_usd=result.cost_usd,
        detail=title,
    )


def _post_status(gh: GitHub, unit: Unit, outcome: Outcome) -> None:
    spec_info = spec.validate(unit)
    status = report.UnitStatus(
        unit=unit,
        state=outcome.status,
        branch=outcome.branch,
        pr_url=outcome.pr_url,
        blockers=[outcome.detail] if outcome.status in ("failed", "stale") else [],
        human_tasks=(
            spec.human_only_tasks(unit, spec_info) if not spec_info.errors else []
        ),
        blocked_question=outcome.detail if outcome.status == "blocked" else "",
    )
    report.update_status_comment(gh, status)


def run_dispatch(
    gh: GitHub,
    cfg: Config,
    root: Path,
    target: Target,
    *,
    max_parallel: int | None = None,
) -> list[Outcome]:
    ready, outcomes = eligibility(gh, cfg, target)
    if ready:
        info(
            f"dispatching {len(ready)} unit(s): {', '.join('#' + str(u.number) for u in ready)}"
        )
    workers = max(1, max_parallel or cfg.max_parallel)
    if ready:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(dispatch_unit, gh, cfg, root, unit, mode=target.mode): unit
                for unit in ready
            }
            for future, unit in futures.items():
                try:
                    outcomes.append(future.result())
                except ForemanError as exc:
                    outcomes.append(Outcome(unit, "failed", detail=str(exc)))
    outcomes.sort(key=lambda o: o.unit.number)
    return outcomes
