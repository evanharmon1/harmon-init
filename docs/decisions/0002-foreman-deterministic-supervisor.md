# 2. Foreman: a deterministic supervisor for agent-driven delivery

Date: 2026-07-12

## Status

Accepted

## Context

A milestone contains well-specced issues with dependency edges. Working them
one at a time is safe but slow; working them all at once is chaos. Two real
milestone runs (omator M3/M4, issue #258's evidence base) showed the failure
modes: stored status fields lie after crashes, stacked PRs create rebase
cascades, subscription usage windows kill unattended agents, review-bot
round-trips eat half the effort, and "the agent says it's done" is not a
verification strategy.

## Decision

Build **foreman** (`scripts/foreman/`, `task foreman:*`), shipped by the
template to every generated repo, on these principles:

- **Deterministic supervisor over LLM orchestrator.** Scheduling, readiness,
  verification, and doneness are plain code; LLMs only produce artifacts
  (code, replies, analyses) that deterministic gates then measure. Zero
  tokens on coordination.
- **The human merge is the only graph-advancing event — permanently.** No
  auto-merge, no enabling flag, ever. Enforcement is server-side (ruleset,
  code-owner review, bot token without bypass or `workflows` write), with an
  identity assertion before foreman's first write.
- **Wave model over stacked PRs.** Every agent branches off the default
  branch; human merges unblock the next wave; merge freezes mean foreman
  idles by design. Same-wave file collisions are handled by the shepherd's
  post-merge rebase loop, not by stacking.
- **Parent issue = one unit = one PR**; sub-issues are the unit's internal
  task list.
- **Inputs are stored; derived state is never stored.** Human inputs live in
  issue bodies, native `blocked-by` edges, and the `foreman` issue field
  (org repos) or `foreman:*` labels (personal repos; issue fields are
  org-only). An `agentState` field was considered and rejected: it
  duplicates derivable facts, lies after crashes, and GitHub has no
  compare-and-swap. Projects are display-only.
- **Explicit arming by default** (v1 decision, flipping the spec draft):
  only issues carrying the `foreman` input dispatch; its value also selects
  the backend. `require_approval = false` opts a repo into default-armed.
- **Foreman opens PRs, not agents** (v1 decision): agents hand results over
  a validated sidecar contract (summary, handoff, human tasks, AC→test map,
  blocked question); foreman verifies with the repo's own `verify_command`
  (default full `task ci`), re-checks freshness (spec hash + eligibility)
  at push time, and assembles a deterministic, marker-carrying PR.
- **Hardened doneness**: a foreman-managed dependency is satisfied only via
  the merged-marker-PR chain (merged into the discovered default branch, by
  the bot, from a foreman attempt branch); external dependencies must be
  closed as completed, with an explicit `foreman:satisfied` human override.
- **Backend adapter seam**: `backends/<name>.sh` is the entire vendor
  surface; v1 ships `claude.sh` plus a hermetic `mock.sh` that proves the
  seam. Subscription billing is the v1 default (usage-window exhaustion is a
  planned pause via the signature catalog, not a failure); API-key billing
  is a config flip with the key exported only into the adapter process.

## Consequences

- Crashes, reboots, and multi-day unattended runs are safe by construction:
  every tick re-derives reality from GitHub + git.
- Humans stay the bottleneck by design — the merge queue is the throttle,
  and `foreman:status` exists to make that queue cheap to service.
- The write contract concentrates all GitHub mutations in one module,
  enforceable by tests (forbidden operations are absent, not discouraged).
- Two input tiers (fields vs labels) must be maintained until GitHub ships
  issue fields for personal accounts; the dual-source fail-loud rule guards
  the seam.
- Foreman's own tests, lint (ruff/black via uvx), and docs ship with the
  template's two-layer dogfood; drift is caught by `test:dogfood-parity`
  and the `use_foreman` render matrix in `test-template.sh`.
