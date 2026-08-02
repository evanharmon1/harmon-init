"""Shepherd: keep open foreman PRs healthy until a human merges them.

Deterministic triggers → bounded agent actions:
  red CI      → classify by signature first (environmental: retry once via
                empty commit, then human queue; quota_wait: idle; otherwise
                mechanical: resume the agent with the failing excerpt)
  behind/dirty→ merge-tree dry-run; clean rebases are mechanical, conflicted
                ones go to the agent (rebase additively, re-verify, push)
  unresolved review-bot threads → resume the agent to adjudicate each finding
                (apply or decline-with-reasoning; blanket-accepting prohibited)
  readiness gate passes → promote the draft to ready for review, label
                ready-to-merge, and report a dependency-aware suggested merge
                order.

The gate is AGENTS.md's ("Dev Loop" → "Readiness gate"), reduced to the part
foreman can decide deterministically: green checks, every review thread
dispositioned, mergeStateStatus=CLEAN, reviewDecision not CHANGES_REQUESTED,
and the head unchanged between the checks above and the promotion itself.
Anything unproven leaves the PR draft — promotion notifies CODEOWNERS and
cannot be unsent, so "not yet established" must never promote speculatively.

Foreman never merges. `gh run rerun` is assumed unavailable to the bot token;
the CI retrigger primitive is an empty commit.
"""

from __future__ import annotations

import graphlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from foreman import backend as backend_mod
from foreman import signatures as signatures_mod
from foreman import spec, verify, worktree
from foreman.config import Config
from foreman.dispatch import RETRIGGER_SUBJECT
from foreman.github import GitHub
from foreman.graph import MARKER_RE
from foreman.util import info, warn, write_text

MAX_AGENT_ACTIONS_PER_PR = 2  # per shepherd run; watch ticks give more rounds


@dataclass
class PrWork:
    number: int
    unit_number: int
    branch: str
    url: str
    title: str
    state: str = (
        # promoted = draft handed to a human; ready = mergeable, feeds merge order
        "healthy"  # healthy | fixed | rebased | adjudicated | waiting | escalated | settling | promoted | ready
    )
    detail: str = ""
    actions: int = 0


@dataclass
class ShepherdReport:
    worked: list[PrWork] = field(default_factory=list)
    ready_order: list[tuple[int, str]] = field(default_factory=list)
    environmental: dict[int, str] = field(default_factory=dict)
    waiting: dict[int, str] = field(default_factory=dict)
    cost_usd: float = 0.0


def open_foreman_prs(gh: GitHub) -> list[dict]:
    prs = []
    for pr in gh.prs(label="foreman-dispatched", state="open"):
        match = MARKER_RE.search(pr.get("body") or "")
        if match:
            pr["_unit"] = int(match.group("number"))
            prs.append(pr)
    return prs


def classify_checks(rollup: list[dict] | None) -> tuple[str, list[dict]]:
    """(green|red|pending, failed contexts) from a statusCheckRollup list."""
    failed: list[dict] = []
    pending = False
    for ctx in rollup or []:
        status = (ctx.get("status") or "").upper()
        conclusion = (ctx.get("conclusion") or ctx.get("state") or "").upper()
        if conclusion in (
            "FAILURE",
            "TIMED_OUT",
            "ACTION_REQUIRED",
            "CANCELLED",
            "ERROR",
        ):
            failed.append(ctx)
        elif (
            # A legacy commit status carries its state where a check run carries
            # its conclusion, and no `status` field at all — so without these two
            # a pending required context reads as green.
            conclusion in ("PENDING", "EXPECTED")
            or status in ("QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED")
            or (not conclusion and status not in ("COMPLETED",))
        ):
            pending = True
    if failed:
        return "red", failed
    if pending:
        return "pending", []
    return "green", []


def ready_label_is_authoritative(
    labels: list[str], *, require_codex_cloud_review: bool
) -> bool:
    """Whether read-only reporting may trust Foreman's readiness label."""
    return "ready-to-merge" in labels and not require_codex_cloud_review


def trusted_review_threads(
    gh: GitHub, cfg: Config, threads: list[dict]
) -> tuple[list[dict], int]:
    """Threads safe to embed in prompts + count requiring human handling."""
    kept: list[dict] = []
    excluded = 0
    viewer = gh.viewer().casefold()
    trusted_senders = {login.casefold() for login in cfg.review_sender_trust}
    trusted_associations = set(cfg.comment_trust)
    for thread in threads:
        comments = (thread.get("comments") or {}).get("nodes") or []
        safe = bool(comments)
        for comment in comments:
            author = (comment.get("author") or {}).get("login", "")
            association = comment.get("authorAssociation", "")
            if (
                association not in trusted_associations
                and author.casefold() != viewer
                and author.casefold() not in trusted_senders
            ):
                safe = False
                break
        if safe:
            kept.append(thread)
        else:
            excluded += 1
    return kept, excluded


def _failure_text(gh: GitHub, failed: list[dict]) -> str:
    parts = []
    for ctx in failed[:5]:
        name = ctx.get("name") or ctx.get("context") or "check"
        parts.append(f"### Failing check: {name}")
        url = ctx.get("detailsUrl") or ctx.get("targetUrl") or ""
        if "/actions/runs/" in url:
            log = gh.run_log_failed(url)
            if log:
                parts.append("```text\n" + log[-8000:] + "\n```")
        elif url:
            parts.append(f"(external check: {url})")
    return "\n\n".join(parts)


def _ensure_worktree(
    cfg: Config, root: Path, unit_number: int, branch: str, remote_name: str
) -> Path:
    path = root / cfg.worktrees_dir / f"pr-{unit_number}"
    if not path.exists():
        worktree.fetch(remote_name)
        local = worktree.attempt_branches(cfg, remote_name, unit_number)
        if branch in local:
            try:
                worktree.add_existing_branch(path, branch)
            except Exception:  # noqa: BLE001 -- fall back to a fresh add
                worktree.add(path, branch, f"{remote_name}/{branch}")
        else:
            worktree.add(path, branch, f"{remote_name}/{branch}")
    return path


def _resume_agent(
    gh: GitHub,
    cfg: Config,
    root: Path,
    work: PrWork,
    prompt_name: str,
    tokens: dict[str, str],
    *,
    allow_github: bool = False,
) -> backend_mod.BackendResult:
    run_dir = backend_mod.unit_dir(cfg, root, work.unit_number)
    prompt = spec.load_prompt(prompt_name, tokens)
    prompt_file = run_dir / f"{prompt_name}.md"
    write_text(prompt_file, prompt)
    adapter = backend_mod.adapter_path(cfg.backend)
    caps = backend_mod.capabilities(adapter)
    session_file = run_dir / "session"
    resume_ref = None
    if "resume" in caps and session_file.exists():
        for line in session_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("SESSION_REF="):
                resume_ref = line.split("=", 1)[1].strip() or None
                break
    wt_path = _ensure_worktree(
        cfg, root, work.unit_number, work.branch, worktree.remote(cfg)
    )
    if resume_ref is None:
        # No session to resume: prepend the deterministic resume-state.
        state_path = backend_mod.write_resume_state(
            run_dir, wt_path, "fresh shepherd invocation"
        )
        prompt = state_path.read_text(encoding="utf-8") + "\n\n---\n\n" + prompt
        write_text(prompt_file, prompt)
    return backend_mod.run_backend(
        cfg,
        adapter,
        cwd=wt_path,
        unit_run_dir=run_dir,
        prompt_file=prompt_file,
        timeout_min=cfg.shepherd_timeout_min,
        resume_ref=resume_ref,
        allow_github=allow_github,
    )


def _common_tokens(gh: GitHub, cfg: Config, work: PrWork) -> dict[str, str]:
    return {
        "PR_URL": work.url,
        "BRANCH": work.branch,
        "UNIT_NUMBER": str(work.unit_number),
        "DEFAULT_BRANCH": gh.default_branch(),
        "VERIFY_COMMAND": " ".join(cfg.verify_command),
    }


def shepherd_pr(gh: GitHub, cfg: Config, root: Path, pr: dict, catalog) -> PrWork:
    status = gh.pr_status(pr["number"])
    work = PrWork(
        number=pr["number"],
        unit_number=pr["_unit"],
        branch=status["headRefName"],
        url=status["url"],
        title=status["title"],
    )
    remote_name = worktree.remote(cfg)
    status_labels = {entry["name"] for entry in status.get("labels") or []}
    if cfg.require_codex_cloud_review and "ready-to-merge" in status_labels:
        gh.label_own_pr(work.number, remove=["ready-to-merge"])
    checks_state, failed = classify_checks(status.get("statusCheckRollup"))

    if checks_state == "pending":
        work.state, work.detail = "settling", "checks still running"
        return work

    if checks_state == "red":
        failure_text = _failure_text(gh, failed)
        sig = signatures_mod.match(failure_text, catalog)
        if sig and sig.action == "quota_wait":
            work.state, work.detail = (
                "waiting",
                f"quota signature '{sig.name}' — waiting for reset",
            )
            return work
        if sig and sig.action == "environment":
            wt_path = _ensure_worktree(
                cfg, root, work.unit_number, work.branch, remote_name
            )
            retries = worktree.count_retrigger_commits(
                wt_path, f"{remote_name}/{gh.default_branch()}", RETRIGGER_SUBJECT
            )
            if retries == 0:
                worktree.empty_commit(wt_path, RETRIGGER_SUBJECT)
                worktree.push(wt_path, remote_name, work.branch, first=False)
                work.state, work.detail = (
                    "fixed",
                    f"environmental '{sig.name}': retried once (empty commit)",
                )
            else:
                work.state = "escalated"
                work.detail = (
                    f"environmental '{sig.name}' persisted after retry — needs a human"
                )
            return work
        # Mechanical (or novel) failure → one bounded agent fix.
        work.actions += 1
        tokens = _common_tokens(gh, cfg, work)
        tokens["FAILURE_EXCERPT"] = failure_text or json.dumps(failed[:3], indent=2)
        result = _resume_agent(gh, cfg, root, work, "shepherd-ci-fix", tokens)
        work_dir = _ensure_worktree(
            cfg, root, work.unit_number, work.branch, remote_name
        )
        if result.ok and not worktree.is_clean(work_dir):
            work.state, work.detail = (
                "escalated",
                "agent left uncommitted changes after CI fix",
            )
        elif result.ok:
            worktree.push(work_dir, remote_name, work.branch, first=False)
            work.state, work.detail = "fixed", "agent pushed a CI fix"
        else:
            work.state, work.detail = (
                "escalated",
                "agent could not fix CI (see unit log)",
            )
        if result.cost_usd:
            work.detail += f" (${result.cost_usd:.2f})"
        return work

    merge_state = (status.get("mergeStateStatus") or "").upper()
    base_branch = status.get("baseRefName") or gh.default_branch()
    # A draft reports mergeStateStatus=DRAFT — the draft flag is itself what
    # blocks the merge — so DRAFT stands in front of BEHIND and DIRTY alike.
    # `mergeable` is computed independently of the draft flag and catches
    # conflicts; staleness has no such field, so ask git how far behind the
    # branch is rather than trusting a status the draft flag overwrote.
    mergeable = (status.get("mergeable") or "").upper()
    stale = merge_state == "DRAFT" and gh.behind_by(base_branch, work.branch) > 0
    if merge_state in ("BEHIND", "DIRTY") or mergeable == "CONFLICTING" or stale:
        wt_path = _ensure_worktree(
            cfg, root, work.unit_number, work.branch, remote_name
        )
        worktree.fetch(remote_name)
        base_ref = f"{remote_name}/{gh.default_branch()}"
        conflicts = worktree.merge_tree_conflicts(wt_path, base_ref)
        if not conflicts:
            if worktree.rebase_onto(wt_path, base_ref):
                worktree.push(wt_path, remote_name, work.branch, first=False)
                work.state, work.detail = (
                    "rebased",
                    "mechanical rebase onto fresh default branch",
                )
            else:
                work.state, work.detail = (
                    "escalated",
                    "mechanical rebase unexpectedly failed",
                )
            return work
        work.actions += 1
        tokens = _common_tokens(gh, cfg, work)
        tokens["CONFLICTS"] = "\n".join(f"- {c}" for c in conflicts)
        result = _resume_agent(gh, cfg, root, work, "shepherd-rebase", tokens)
        if result.ok:
            ok, _tail = verify.run_verify(
                cfg, wt_path, backend_mod.unit_dir(cfg, root, work.unit_number)
            )
            if ok:
                worktree.push(wt_path, remote_name, work.branch, first=False)
                work.state, work.detail = (
                    "rebased",
                    f"agent resolved {len(conflicts)} conflict(s), verify green",
                )
            else:
                work.state, work.detail = "escalated", "post-rebase verification failed"
        else:
            work.state, work.detail = "escalated", "agent could not resolve the rebase"
        return work

    unresolved = [t for t in gh.review_threads(work.number) if not t.get("isResolved")]
    threads, excluded_threads = trusted_review_threads(gh, cfg, unresolved)
    if threads:
        work.actions += 1
        rendered = []
        for thread in threads[:20]:
            comments = (thread.get("comments") or {}).get("nodes") or []
            first = comments[0] if comments else {}
            author = (first.get("author") or {}).get("login", "reviewer")
            rendered.append(
                f"- thread `{thread['id']}` on `{thread.get('path') or 'PR'}` by @{author}:\n"
                f"  > " + (first.get("body") or "").strip().replace("\n", "\n  > ")
            )
        tokens = _common_tokens(gh, cfg, work)
        tokens["THREADS"] = "\n".join(rendered)
        result = _resume_agent(
            gh,
            cfg,
            root,
            work,
            "shepherd-adjudicate",
            tokens,
            allow_github=True,
        )
        wt_path = _ensure_worktree(
            cfg, root, work.unit_number, work.branch, remote_name
        )
        if result.ok:
            if worktree.is_clean(wt_path) is False:
                work.state, work.detail = (
                    "escalated",
                    "agent left uncommitted adjudication changes",
                )
                return work
            if worktree.commits_ahead(wt_path, f"{remote_name}/{work.branch}") > 0:
                worktree.push(wt_path, remote_name, work.branch, first=False)
            remaining = [
                t for t in gh.review_threads(work.number) if not t.get("isResolved")
            ]
            if remaining:
                work.state = "escalated"
                if excluded_threads:
                    work.detail = (
                        f"{excluded_threads} review thread(s) from untrusted authors "
                        f"require human handling; {len(remaining)} total still undispositioned"
                    )
                else:
                    work.detail = (
                        f"{len(remaining)} review thread(s) still undispositioned"
                    )
            else:
                work.state, work.detail = (
                    "adjudicated",
                    f"{len(threads)} thread(s) dispositioned",
                )
        else:
            work.state, work.detail = "escalated", "adjudication agent failed"
        return work

    if excluded_threads:
        work.state = "escalated"
        work.detail = (
            f"{excluded_threads} unresolved review thread(s) from untrusted authors "
            "require human handling"
        )
        return work

    # Two transitions, one gate. CLEAN is unreachable while the PR is a draft,
    # so testing for it alone would make the promotion below dead code:
    #   DRAFT → promote to ready for review (the human handoff)
    #   CLEAN → label ready-to-merge (mergeable now; the human decides)
    # A promoted PR usually reports BLOCKED next (code-owner review pending) and
    # only becomes CLEAN once approved, so the label still means what it always
    # did and only `ready` feeds the suggested merge order.
    if merge_state in ("DRAFT", "CLEAN"):
        if cfg.require_codex_cloud_review:
            work.state, work.detail = (
                "escalated",
                "current-head Codex cloud review requires manual shepherd completion",
            )
            return work
        if (status.get("reviewDecision") or "").upper() == "CHANGES_REQUESTED":
            work.state, work.detail = (
                "escalated",
                "a reviewer requested changes — needs a human, not a handoff",
            )
            return work
        # "Nothing failed" is not "the required checks passed". classify_checks
        # reports on whatever has shown up, and GitHub registers checks
        # incrementally, so one fast check can be green while a required workflow
        # has not appeared at all. `mergeStateStatus` cannot settle it either —
        # DRAFT masks the BLOCKED that missing required checks would otherwise
        # produce. Ask the base branch what it enforces and compare.
        required = gh.required_checks(base_branch)
        if not required:
            work.state, work.detail = (
                "escalated",
                (
                    "base branch enforces no required checks — nothing to certify "
                    "for a handoff; import the branch ruleset or promote by hand"
                ),
            )
            return work
        reported = {
            name
            for name in (
                (ctx.get("name") or ctx.get("context"))
                for ctx in status.get("statusCheckRollup") or []
            )
            if name
        }
        missing = sorted(required - reported)
        if missing:
            work.state, work.detail = (
                "settling",
                f"required check(s) not reported yet: {', '.join(missing)}",
            )
            return work
        # Mergeability is computed asynchronously, so it reads UNKNOWN for a
        # while after every push. The rebase path above only acts on a definite
        # CONFLICTING; UNKNOWN reaches here, and "not known to conflict" is not
        # the same as mergeable.
        if mergeable != "MERGEABLE":
            work.state, work.detail = (
                "settling",
                f"mergeability still {mergeable or 'UNKNOWN'} — re-gating next tick",
            )
            return work
        # Re-read the head immediately before the one-way promotion: a push
        # landing since the gate snapshot invalidates every result above it.
        # Every read below fails CLOSED — a field that is missing or unreadable
        # is "unknown", never "unchanged".
        head = gh.pr_head(work.number)
        if (head.get("state") or "").upper() != "OPEN":
            work.state, work.detail = (
                "escalated",
                f"PR is {head.get('state') or 'UNKNOWN'} — refusing to promote",
            )
            return work
        gated_head = status.get("headRefOid")
        if not gated_head or head.get("headRefOid") != gated_head:
            work.state, work.detail = (
                "settling",
                "head moved or unreadable during the readiness gate — re-gating",
            )
            return work
        is_draft = head.get("isDraft")
        if is_draft not in (True, False):
            work.state, work.detail = (
                "escalated",
                "could not read the PR's draft state — refusing to promote",
            )
            return work
        if is_draft:
            gh.ready_own_pr(work.number)
            confirmed = gh.pr_head(work.number)
            if (
                confirmed.get("isDraft") is not False
                or confirmed.get("headRefOid") != gated_head
            ):
                work.state, work.detail = (
                    "escalated",
                    "promotion to ready for review not confirmed on the gated head",
                )
                return work
            # Deliberately NOT "ready": the merge order is for PRs a human can
            # merge now, and this one has not been reviewed yet. The next tick
            # sees a non-draft PR and labels it once GitHub reports CLEAN.
            work.state, work.detail = (
                "promoted",
                "readiness gate passed — promoted to ready for human review",
            )
            return work
        # Already non-draft (idempotent re-entry: never a second ready event).
        if merge_state != "CLEAN":
            work.state, work.detail = (
                "healthy",
                f"ready for review; mergeState={merge_state}",
            )
            return work
        gh.label_own_pr(work.number, add=["ready-to-merge"])
        work.state, work.detail = (
            "ready",
            "green, adjudicated, mergeState=CLEAN — awaiting human merge",
        )
    else:
        work.state, work.detail = "healthy", f"mergeState={merge_state or 'UNKNOWN'}"
    return work


def merge_order(gh: GitHub, ready: list[PrWork]) -> list[tuple[int, str]]:
    """Dependency-aware suggested order among ready PRs (topo by blocked-by)."""
    by_unit = {w.unit_number: w for w in ready}
    sorter: graphlib.TopologicalSorter = graphlib.TopologicalSorter()
    for unit_number in by_unit:
        deps = [
            entry["number"]
            for entry in (gh.issue(unit_number).get("blockedBy") or [])
            if entry["number"] in by_unit
        ]
        sorter.add(unit_number, *deps)
    ordered = list(sorter.static_order())
    return [(n, by_unit[n].url) for n in ordered]


def run_shepherd(gh: GitHub, cfg: Config, root: Path) -> ShepherdReport:
    out = ShepherdReport()
    catalog = signatures_mod.load()
    prs = open_foreman_prs(gh)
    if not prs:
        info("shepherd: no open foreman PRs")
        return out
    for pr in prs:
        try:
            work = shepherd_pr(gh, cfg, root, pr, catalog)
        except Exception as exc:  # noqa: BLE001 -- keep shepherding the rest
            warn(f"shepherd: PR #{pr['number']} failed: {exc}")
            work = PrWork(
                number=pr["number"],
                unit_number=pr["_unit"],
                branch=pr.get("headRefName", ""),
                url=pr.get("url", ""),
                title=pr.get("title", ""),
                state="escalated",
                detail=str(exc),
            )
        out.worked.append(work)
        if work.state == "escalated":
            out.environmental[work.unit_number] = work.detail
        if work.state == "waiting":
            out.waiting[work.unit_number] = work.detail
    ready = [w for w in out.worked if w.state == "ready"]
    out.ready_order = merge_order(gh, ready)
    return out
