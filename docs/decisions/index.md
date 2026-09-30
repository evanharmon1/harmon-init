# Decisions (ADRs)

Append-only records of why each choice was made — they stop an agent from
"helpfully" undoing a deliberate choice, and justify **deviations from best
practice**.

Each record captures one choice: its context, the decision, and the **explicit
"not" reasoning** (what was rejected and why). **Supersede, don't edit:** to
change a decision, add a new ADR that supersedes the old one and mark the old
one's status.

- One ADR per file, named `YYYY-MM-DD-<kebab-title>.md` — the date the
  record was filed, fixed at creation and never changed by a later status
  change (a `Proposed` record keeps its filing date when accepted; the
  `Status` line carries the outcome). Records from before this convention
  keep their numbered `NNNN-` names; both forms are valid. The one
  exception is the seed record below: the project template maintains it,
  so a template update re-titles a numbered seed to the date form.
- Start with
  [2026-06-19-record-architecture-decisions.md](2026-06-19-record-architecture-decisions.md)
  — the meta-ADR for the process. The project template maintains it: its
  name and `Date:` come from the `decisions_seed_date` answer recorded when
  the repository was scaffolded (or when an update first introduced the
  date form), so updates keep improving its content without renaming it.
  Copy it as the starting point for new ADRs — the copy is an ordinary
  record and nothing in its body is seed-specific.
- [2026-07-12-foreman-deterministic-supervisor.md](2026-07-12-foreman-deterministic-supervisor.md)
  — Foreman: a deterministic supervisor for agent-driven delivery
  (Accepted; distribution superseded; arming amended by 2026-08-07).
- [2026-07-14-release-gated-deploys-for-static-sites.md](2026-07-14-release-gated-deploys-for-static-sites.md)
  — release-gated production deploys for static sites (Accepted).
- [2026-08-03-operator-gh-login-in-the-dev-devcontainer.md](2026-08-03-operator-gh-login-in-the-dev-devcontainer.md)
  — the dev devcontainer authenticates as the operator, not the bot (Accepted).
- [2026-08-07-unified-agent-vocabulary.md](2026-08-07-unified-agent-vocabulary.md)
  — use one model-centric agent vocabulary and registry (Accepted; amends 2026-07-12 arming).
- [2026-08-16-method-and-tier-axes.md](2026-08-16-method-and-tier-axes.md)
  — method and tier strategy axes (Accepted; D4 superseded by 2026-08-24).
- [2026-08-24-rigor-and-strategy-axes.md](2026-08-24-rigor-and-strategy-axes.md)
  — rigor and strategy execution-policy axes (Accepted; amended by 2026-08-29 Dev flow v2).
- [2026-08-25-versioned-devflow-compatibility-contract.md](2026-08-25-versioned-devflow-compatibility-contract.md)
  — version the devflow compatibility contract (Accepted).
- [2026-08-29-dev-flow-v2-orchestrator-and-results.md](2026-08-29-dev-flow-v2-orchestrator-and-results.md)
  — Dev flow v2: the session orchestrates; results are schema-bound
  (Accepted; D2 amended by 2026-09-13).
- [2026-08-29-name-decision-records-by-date.md](2026-08-29-name-decision-records-by-date.md)
  — name decision records by date instead of sequence number (Accepted).
- [2026-09-01-adopt-openspec.md](2026-09-01-adopt-openspec.md) — superseded
  by the decision to retire the root-only OpenSpec workflow.
- [2026-09-02-remove-guard-process-kill-hook.md](2026-09-02-remove-guard-process-kill-hook.md)
  — the process-kill guard hook is removed; the hard rule binds the agent directly (Accepted).
- [2026-09-13-brief-envelope-schema-bound-free-form-body.md](2026-09-13-brief-envelope-schema-bound-free-form-body.md)
  — briefs get a schema-bound envelope around a free-form body (Accepted; amends 2026-08-29 D2).
- [2026-09-23-retire-openspec-workflow.md](2026-09-23-retire-openspec-workflow.md)
  — OpenSpec is retired in favor of the existing issue, ADR, and plain-spec workflow (Accepted).
- [2026-09-29-agent-posture-three-posture-model.md](2026-09-29-agent-posture-three-posture-model.md)
  — proposed: a third devcontainer posture, **agent**, for unattended runs,
  never looser than bot on any axis.
