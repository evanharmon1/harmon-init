# 7. Rigor and strategy execution-policy axes

Date: 2026-08-24

## Status

Accepted — a **pending amendment** to D3 (the `[review.*]` tables become `[caps.*]`), D4, D8, and D9 is proposed by
[ADR 0008](0008-dev-flow-v2-orchestrator-and-results.md) and takes effect
when that record becomes Accepted; until then these decisions stand as
written. ADR 0008 amends D4, D8, and D9 where they define
the `shepherd` cap as bounding CI, human-review, and Codex findings alike:
the renamed `integration` cap bounds Codex re-review cycles only, and a
separate `remediation` cap bounds fix pushes in that stage.

Supersedes [ADR 0006](0006-method-and-tier-axes.md) D4 (the method rank and
its `[method]` table are retired along with `method:*`) and amends its D5
(resolution order and conflict handling below now covers `rigor:*` and
`strategy:*` as the primary label inputs, not `tier:*`/`method:*`; see
D7/D8 below for what changes and what does not). ADR 0006's D1–D3, D6, D7's
tier-ladder content, and D8 stand unchanged — the `[tier.*]` model they
describe is byte-for-byte the same table this ADR re-scopes to per-role
resolution. Authoritative requirements live in
[`specs/issue-strategy.md`](../../specs/issue-strategy.md); on any conflict
the spec wins. Planned under evanharmon1/harmon-init#1047, following the
milestone "Issue strategy overhaul" that ADR 0006 opened; #1048 (schema
version, language-neutral fixtures, a conformance harness) is a later,
narrower follow-up this ADR does not implement.

## Context

`.devflow.toml` grew its round-cap vocabulary (`rigor`, but scoped only to
challenge/review/shepherd caps) and its strategy vocabulary (`tier` for
model routing, `method` for execution topology) as three separate primary
axes, each with its own top-level default. In practice a human asking for
more or less confidence, effort, and budget on a change had to reason about
three independent knobs to say one thing, and the vocabulary did not
coordinate the settings that actually drive cost: model strength by role,
review depth, agent topology, concurrency, and total effort move together
in practice, not independently.

This ADR establishes `rigor` (how much confidence, effort, depth, and
budget) and `strategy` (how the work is organized and performed) as the two
primary axes. Review policy, per-role model tier, and budget envelope
become rigor's lower-level components rather than peer choices; `method` is
retired in favor of `strategy`, which adds topology fields ADR 0006's
`method` never had (planning, delegation, coordination, selection,
synthesis, human gates) and drops the fixed conflict rank that made
`method` resolvable in the first place — deliberately; see D7.

AI challenge, review, and shepherd passes remain heuristic confidence and
cost controls layered on top of the repository's actually-enforcing
mechanisms — deterministic tests, CI, security scanners, branch protection,
and human merge/release approval. Nothing in this ADR changes that
relationship; D3 and D8 below restate it precisely because the new review
policies make zero- and one-round configurations first-class rather than
edge cases the old floor forbade.

## Decision

### D1 — Two primary axes; lower-level controls are not peers

`rigor` answers *how much*; `strategy` answers *how*. Model tier, review
policy, and budget envelope are **components of a rigor level**, not
independent top-level defaults — `.devflow.toml` has exactly two selection
defaults, `default_rigor` and `default_strategy`. **Not:** `default_tier`
and `default_method` as peer top-level scalars (ADR 0006's shape) — that
model made "how much" a human had to reconstruct from three uncoordinated
choices instead of stating once.

### D2 — A rigor level names three ROLE tiers, not one

Each `[rigor.*]` level sets `orchestrator_tier`, `implementer_tier`, and
`reviewer_tier` independently, plus a `review` policy reference and a
`budget` reference. **Not:** a single tier shared by every role acting on
the issue. The orchestrator planning the work, the implementer writing it,
and the reviewer checking it are different jobs with different minimum
capability needs — collapsing them to one tier either overpays for the
cheapest role or underpays for the most demanding one. Built-in levels
satisfy `orchestrator_tier >= implementer_tier` and `reviewer_tier >=
implementer_tier` under the ladder order (ADR 0006 D2); an attributable
explicit override may violate either invariant but must be recorded and
disclosed as an off-profile decision rather than silently accepted.

### D3 — Zero- and one-round review policies are valid, not a floor violation

`[review.none]` (0/0/0, `min_rounds` 0) and `[review.driveby]` (1/1/1,
`min_rounds` 1) are shipped, first-class policies. **Not:** the prior
floor of "challenge and review are >= 2, because the exit condition needs
two consecutive adjudicated-clean rounds." That floor existed only to
protect a design where a single low cap made any one finding an instant
escalation; the general rule replacing it — `0 <= min_rounds <=
min(challenge, review)` (D9 has the full bound, including why `shepherd` is
never part of it) — makes a capped-clean final round its own valid exit at
any cap, including 1, and makes an all-zero `challenge`/`review` policy
(nothing self-generated enabled) simply skip the heuristic stage rather
than trip a floor meant for a different failure mode. Zero AI review rounds
is a legitimate choice at low rigor precisely because the heuristic layer
was never the thing enforcing correctness — the deterministic gates still
run unconditionally (D8).

### D4 — Shepherd varies by review policy

`shepherd` ranges 1 through 6 across the six shipped review policies
instead of holding one repository-wide value regardless of chosen depth.
**Not:** shepherd pinned uniform across every rigor level, which is what
this file shipped previously with the rationale "lowering it abandons
reviews that are already unanswered." That protection is preserved a
different way: shepherd is no longer an independently-tunable knob a level
author could quietly turn down in isolation to dodge unanswered review
traffic — it is one field inside a single named, versioned review-policy
bundle (`[review.<name>]`) that a human selects as a whole via `rigor`.
Picking a shallower bundle is a visible, disclosed rigor/strategy decision
with its own review-depth consequences throughout, not a targeted edit to
just the field that bounds other people's findings.

### D5 — Unqualified `tier:<value>` refines the implementer only

An unqualified `tier:<value>` label or override targets the **implementer**
role alone; `orchestrator_tier` and `reviewer_tier` keep the resolved
rigor's own profile values unless a scoped `tier:orchestrator:<value>` /
`tier:reviewer:<value>` names them explicitly. **Not:** an unqualified tier
setting all three roles uniformly, which is what a single `default_tier`
scalar implicitly did before three roles existed. The implementer is the
role a human means by an unscoped "use a cheaper/stronger model" — its cost
and capability dominate a typical change, while the orchestrator's planning
judgment and the reviewer's floor are worth holding at the rigor's own
profile even when someone is optimizing implementer spend. A human who
means a different specific role reaches for the scoped label instead of
overloading the unqualified one.

### D6 — Constitutional gates are not configurable by any strategy

`strategy.human_gates` is drawn from a fixed set of ten pause points
(`after-discovery`, `after-plan`, `before-delegation`, `before-selection`,
`before-synthesis`, `before-scope-expansion`, `before-budget-escalation`,
`before-publication`, `before-ready-for-review`, `each-phase`).
Constitutional approvals — merge, release, destructive actions,
credential-store writes, and security-relevant settings — are never in
that list, and a strategy naming one is a validation error, not a stricter
gate. **Not:** letting `human_gates` express them, which would make an
already-established hard rule (this repository's AGENTS.md Hard Rules, the
operator's own Constitution, branch protection, CODEOWNERS) reachable
through a strategy choice — effectively a config-level way to soften a
safety gate that was never meant to be a tunable. Those approvals stay
enforced by their own independent mechanisms, entirely outside rigor and
strategy.

### D7 — Strategy conflicts are ambiguous; there is no strategy rank

Two `strategy:*` labels on the same issue are **ambiguous** and require
resolution — an interactive session asks; unattended automation falls back
to `default_strategy` with a warning. **Not:** a fixed cross-strategy rank
like the `[method].rank` this replaces (ADR 0006 D4, now retired). Rigor
has an inherent more-or-less continuum, which is exactly what makes
"strongest label wins" both meaningful and safe — a rigor conflict can only
ever buy more depth and budget. Topology choices do not sit on a single
axis: there is no principled sense in which `council` "outranks"
`orchestrate`, and forcing one (as the old human-oversight-ordered method
rank did) can silently select a costlier or more elaborate topology than
either label alone unambiguously asked for. Requiring resolution — instead
of guessing — keeps the choice attributable.

### D8 — A cap of 0 disables a heuristic stage; it never touches a deterministic gate

`challenge`, `review`, and `shepherd` bound AI-driven confidence and cost
controls only. Disabling one (cap 0) or capping it at a single pass (cap 1)
changes nothing about the deterministic gates — tests, CI, security
scanners, branch protection, human merge and release approval — and never
suppresses the obligation to adjudicate and record any finding that does
surface before the cap is reached. **Not:** treating a 0 or 1 cap as
"skip review" in any sense broader than the specific heuristic stage it
names. This is restated explicitly here because D3's zero/one-round
policies make the low end of the range a first-class, frequently-selected
configuration rather than a rare edge case.

A shepherd cap of 0 specifically is worth spelling out, because shepherd is
the one stage that bounds *other people's* findings rather than the agent's
own generated work (AGENTS.md, Dev Loop). Disabling it removes exactly two
things: the agent's own shepherd fix-rounds, and the readiness gate's
current-head Codex-cycle *requirement* — the same way that requirement
already drops out wherever Codex review is not enabled at all (AGENTS.md,
Readiness gate). It removes neither the readiness gate itself nor any of
its other conditions: CI still has to conclude successfully, every human
review thread still needs its required reply, `reviewDecision` still may
not be `CHANGES_REQUESTED`. **Not:** a shepherd cap of 0 waiving those
conditions so a PR can be promoted over unresolved feedback — that would
make the deepest cost-cutting rigor level the one AI review passes cannot
reach ready-for-review under, exactly backwards from what a ceiling is
supposed to do. If a human still leaves findings on a shepherd-disabled
PR, the agent has no budget left to answer them: the PR simply stays
draft, and those findings are left for the human who raised them, exactly
as any other unresolved readiness-gate condition would leave it.

### D9 — `min_rounds` is bounded by challenge and review, not pinned to 1 or 2

`0 <= min_rounds <= min(challenge, review)` for every review policy —
`shepherd` is never part of that bound. **Not:** the prior fixed range of
"1 or 2, never more," which was an artifact of every level sharing the same
small cap values. With caps now ranging 0–6 and varying per stage per
policy (D4), the general bound is the minimum of the policy's
self-generated stage caps — an all-zero `challenge`/`review` pair forces
`min_rounds` to 0 by the same rule, rather than needing a special case.
**Not, either:** including `shepherd` in that minimum, which is where an
earlier version of this bound started and which D4 already establishes as
the wrong shape for a different reason — `shepherd` bounds *other people's*
findings (CI, human review, Codex), not rounds the agent runs on its own
initiative, so it cannot MANUFACTURE a round to satisfy a floor the way a
self-generated challenge/review pass can. A policy whose `shepherd` happens
to be smaller than `min(challenge, review)` must not have that smaller
number silently tighten `min_rounds`, since there is no sense in which the
agent could "run more shepherd rounds" to comply.

### D10 — Budget envelopes are a new, portable resource-ceiling vocabulary

`[budget.*]` adds `max_agent_runs`, `max_parallel_agents`, `wall_clock_min`,
and `allow_tier_escalation` as a rigor-level component, with optional
`max_tokens` / `max_usd` in the schema but absent from every shipped
envelope. **Not:** claiming enforcement of a limit this repository cannot
actually measure — a consumer without token or spend visibility reports
the corresponding ceiling as unenforced rather than shipping a number that
looks authoritative but binds nothing. `.foreman.toml` remains the
authority on hard operational ceilings; Foreman intersects a resolved
envelope with its own limits rather than either source being trusted
alone.

### D11 — Strategy/rigor incompatibility is reported, never silently substituted

A strategy whose `min_agents` exceeds the resolved rigor's
`max_agent_runs` or `max_parallel_agents` (e.g. `council` or `orchestrate`,
both `min_agents = 2`, under `trivial`'s budget of 1 and 1) is a reported
incompatibility.
**Not:** silently downgrading the topology to fit the budget, or silently
raising the budget to fit the topology. Either direction would substitute
a decision the operator did not unambiguously make; reporting keeps a
genuine mismatch visible instead of resolved by guesswork.

### D12 — A minimal reference resolver ships now; the conformance harness is deferred

`scripts/devflow-resolve.py` ships as a root-only reference implementation
of the resolution order above, covering the rigor/strategy/tier-override
cases this ADR defines. **Not:** the versioned `schema_version`,
language-neutral fixture corpus, and cross-consumer conformance harness —
that is evanharmon1/harmon-init#1048, deliberately sequenced after this
change so the vocabulary and shipped values could be settled and reviewed
on their own first.

## Consequences

- A human (or an agent reading a natural-language instruction) states
  execution policy in two concepts instead of reconstructing it from three
  independently-defaulted axes; `docs/guides/devflow.md` carries the worked
  natural-language examples this ADR does not restate.
- `label-registry.json` gains a `strategy` family alongside `rigor`;
  `method` retires through the existing retired-family pattern. `tier`
  stays, re-scoped to per-role resolution (D5) rather than a single
  repo-wide default.
- `agent-registry.json` gains harness `roles` (subset of
  `orchestrate`/`implement`/`review`) so resolution can tell which
  configured harnesses are eligible for which role — no separate harness
  registry is introduced.
- Every consumer of the old vocabulary — AGENTS.md, `specs/issue-strategy.md`,
  the label and agent registries, `scripts/test-devflow-config.sh` and its
  mutation corpus, and `docs/project-management.md` — moves together in
  the same change; none of them becomes a second source of the numeric
  values or policy meaning that `.devflow.toml` and this ADR now own.
- Nothing in a generated repo gains a runtime dependency: `rigor:*` and
  `strategy:*` remain inert routing preferences that arm nothing, exactly
  as `tier:*`/`method:*` did under ADR 0006; `foreman:*` remains the only
  arming surface.
