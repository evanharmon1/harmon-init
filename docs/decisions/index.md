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
  `Status` line carries the outcome). Records filed under the older numbered
  `NNNN-` convention are renamed to the date form
  ([2026-09-30-rename-numbered-decision-records-by-date.md](2026-09-30-rename-numbered-decision-records-by-date.md)).
  The seed record below follows the same rule through its own mechanism:
  the project template maintains it, so a template update re-titles a
  numbered seed to the date form.
- Start with
  [2026-06-19-record-architecture-decisions.md](2026-06-19-record-architecture-decisions.md)
  — the meta-ADR for the process (Accepted). The project template maintains
  it: its
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
  — use one model-centric agent vocabulary and registry (Accepted; amends 2026-07-12 arming;
  partly superseded by 2026-09-30 (issue classification)).
- [2026-08-16-method-and-tier-axes.md](2026-08-16-method-and-tier-axes.md)
  — method and tier strategy axes (Accepted; D4 superseded by 2026-08-24; amended and partly
  superseded by 2026-09-30 (issue classification)).
- [2026-08-24-rigor-and-strategy-axes.md](2026-08-24-rigor-and-strategy-axes.md)
  — rigor and strategy execution-policy axes (Accepted; amended by 2026-08-29 (Dev flow v2) and
  2026-09-30 (issue classification)).
- [2026-08-25-versioned-devflow-compatibility-contract.md](2026-08-25-versioned-devflow-compatibility-contract.md)
  — version the devflow compatibility contract (Accepted).
- [2026-08-29-dev-flow-v2-orchestrator-and-results.md](2026-08-29-dev-flow-v2-orchestrator-and-results.md)
  — Dev flow v2: the session orchestrates; results are schema-bound
  (Accepted; D2 amended by 2026-09-13).
- [2026-08-29-name-decision-records-by-date.md](2026-08-29-name-decision-records-by-date.md)
  — name decision records by date instead of sequence number
  (Accepted; amended by 2026-09-30).
- [2026-09-01-adopt-openspec.md](2026-09-01-adopt-openspec.md)
  — adopt OpenSpec for spec-driven changes at the repo root (Superseded by 2026-09-23).
- [2026-09-02-remove-guard-process-kill-hook.md](2026-09-02-remove-guard-process-kill-hook.md)
  — the process-kill guard hook is removed; the hard rule binds the agent directly (Accepted).
- [2026-09-13-brief-envelope-schema-bound-free-form-body.md](2026-09-13-brief-envelope-schema-bound-free-form-body.md)
  — briefs get a schema-bound envelope around a free-form body
  (Accepted; amends 2026-08-29 (Dev flow v2) D2).
- [2026-09-23-retire-openspec-workflow.md](2026-09-23-retire-openspec-workflow.md)
  — OpenSpec is retired in favor of the existing issue, ADR, and plain-spec workflow (Accepted).
- [2026-09-29-agent-posture-three-posture-model.md](2026-09-29-agent-posture-three-posture-model.md)
  — three postures: dev, bot, and agent (Proposed).
- [2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md](2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
  — classify issues by impact, risk, and complexity, and derive the tier
  (Accepted; amended by 2026-10-01 (Tier as a label), 2026-10-01 (Priority AI axis) and
  2026-10-05 (filing rule and organization walk)).
- [2026-09-30-rename-numbered-decision-records-by-date.md](2026-09-30-rename-numbered-decision-records-by-date.md)
  — rename numbered decision records by date (Accepted).
- [2026-10-01-store-the-tier-as-a-label-on-every-owner-type.md](2026-10-01-store-the-tier-as-a-label-on-every-owner-type.md)
  — store the Tier as a label on every owner type (Accepted; amends 2026-09-30 (issue classification) D2).
- [2026-10-01-add-a-priority-ai-axis-suggested-by-agents.md](2026-10-01-add-a-priority-ai-axis-suggested-by-agents.md)
  — add a Priority (AI) axis, p0–p4, suggested by agents (Accepted; amends 2026-09-30 (issue classification) D2 and D3).
- [2026-10-05-file-unclassified-issues-with-needs-triage-and-walk-organizations-standalone.md](2026-10-05-file-unclassified-issues-with-needs-triage-and-walk-organizations-standalone.md)
  — file unclassified issues with needs-triage and walk organizations standalone
  (Accepted; amends 2026-09-30 (issue classification) D4 and D6).
