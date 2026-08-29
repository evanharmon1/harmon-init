# 8. Dev flow v2 — the session orchestrates; results are schema-bound

Date: 2026-08-29

## Status

Proposed — becomes Accepted when the anchor spec merges
(evanharmon1/harmon-devkit#665).

Extends [ADR 0007](0007-rigor-and-strategy-axes.md): rigor and strategy stay
the two primary axes, and this record adds the execution model those axes
select — who decides what during a run, and what form the evidence takes.
**Amends ADR 0007 D4, D8, and D9** where they define the `shepherd` cap as
bounding CI, human-review, and Codex findings alike: under this record the
renamed `integration` cap bounds Codex re-review cycles only, answering CI
and human findings is unconditional, and fix pushes in that stage are bounded
by a separate `remediation` cap whose terminal action is escalation. ADR 0007
carries the reciprocal notice.
Authoritative requirements live in harmon-devkit's `specs/dev-flow-v2.md` —
the reviewed revision is
[3509de7](https://github.com/evanharmon1/harmon-devkit/blob/3509de75c73d4615362825155c3e1e3aa42cda77/specs/dev-flow-v2.md),
and the `main` path becomes the live link once #665 merges;
on any conflict the spec wins. Planned under the "Dev flow v2" milestones in
harmon-devkit, harmon-init (#1080–#1082, #1113), and ponderousdev/foreman.

## Context

The dev loop's hardest decisions — *is this review round converging?* and *is
this finding real?* — were made by feel inside the session running the loop,
from ~470 lines of prose in `AGENTS.md`. The retro of ponderousdev/omator#397
(seven confidence-stage rounds, 67 findings, both stages capped with P1s every
round, most round-2 findings about round-1's own fixes) showed that a loop
whose exit is a judgement can neither stop itself nor be tuned afterwards,
because nothing it decided was recorded in a form a script could read.

v2 makes the flow deterministic where determinism is reliable: agents fill
roles and return schema-validated results; scripts compute round exit,
provenance, rendering, and the readiness gate from that evidence and from
`.devflow.toml`. Two decisions in that design are hard to reverse and would
puzzle a later reader, so they are recorded here.

## Decision

### D1 — The orchestrator is the session, and it may override a computed exit only upward

The **orchestrator** is the session that dispatched the roles — an
interactive Claude Code session or a Foreman-dispatched headless one — with
one procedure for both. It owns severity adjudication, dispositions, the PR
body, and promotion to ready-for-review. When the exit script says
`converged` and the stage cap and budget still have headroom, the orchestrator
may spend one more round with a recorded reason — a converged final round at
the cap is final;
when it says `diverging`, the orchestrator must change approach (a `delete`
or `restructure` disposition on the findings that feed on earlier fixes) or
stop; when it says `capped` with P0/P1 remaining, the orchestrator escalates
to a human. It may never turn a computed `continue` or `diverging` into an
exit.

**Not** an orchestrator *agent*: a dispatched agent's context is exactly what
a dispatcher must not accumulate, headless and interactive runs would then
run different loops, and a second decision-maker is a second place for the
harmon-devkit#276-style drift this design removes. **Not** a downward override: the
determinism thesis is that a script's "keep going" is evidence, and a session
that can overrule it with "looks fine" has the v1 loop back with extra steps.
Upward is safe because it only ever buys more review.

### D2 — Briefs are free-form; results are schema-bound

The orchestrator → agent brief is prose: what to do, what the previous rounds
found, what the change is for. The agent → orchestrator result is JSON
validated on receipt against a shared envelope (`schema`, `role`, `status`,
`head`, `produced_at`, `producer`, `run`) and a per-role payload
(implementer, reviewer, integrator). Reviewer output is immutable; the
orchestrator's adjudication is a separate record keyed by finding id, and
every script reads the adjudicated view.

**Not** schema-bound briefs: a brief's job is to carry judgement and context
downward, which a schema flattens, and nothing downstream parses it — the
upward result is what exits, renderers, Foreman, and the retro read, so that
is where the contract has to be. **Not** letting the orchestrator edit the
reviewer's output in place: the raw output is how reviewer-vs-orchestrator
disagreement is measured, which is the calibration signal for the reviewer's
tier.

### D3 — Consequences carried into this repository

- `.devflow.toml` gains `[caps.*]` (renamed from `[review.*]`; keys
  `challenge`, `review`, `integration`, `min_rounds`), `[gates]`,
  `[convergence]` (a composed predicate catalog), `[role.*]` tier baselines,
  and `[stage.*].finders[]`; the legacy shape is refused (#1081).
- The integration cap bounds Codex re-review cycles only; answering human and
  CI findings is uncapped, which is why a policy may lower it.
- `AGENTS.md`'s Dev Loop shrinks to the stage table, the constitution rules,
  and references (#1082); the pre-PR gate is `task security` on a head that
  already carries a round-gate marker (#1080).
- Foreman consumes the same contracts in its own Python; it never wraps the
  skills. Conformance fixtures shipped by harmon-devkit are the shared test.

## Consequences

- A run leaves a replayable record, so convergence policy is tuned from data
  rather than argued from prose.
- Every generated repo takes the v2 shape in one `copier update`; there is no
  dual-shape period.
- The success metric — the share of kicked-off issues reaching
  ready-for-review with zero human interventions — is computable from retained
  artifacts alone.
