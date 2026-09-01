# 6. Method and tier strategy axes

Date: 2026-08-16

## Status

Accepted

D4 (the method rank and its `[method]` table) is **superseded** by
[ADR 0007](0007-rigor-and-strategy-axes.md), which retires `method:*` in
favor of `strategy:*`; D5 (resolution order and conflict handling) is
**amended** by ADR 0007 to cover `rigor:*`/`strategy:*` as the primary
label inputs rather than `tier:*`/`method:*`. D1–D3 and D6–D8 (the tier
ladder, escalation, consumer-trust invariants, and no-auto-merge) stand
unchanged; ADR 0007 re-scopes tier resolution to per-role tiers but the
`[tier.*]` model itself is untouched.

Amends [ADR 0005](0005-unified-agent-vocabulary.md) D6 (see Decision § D6
amendment). Authoritative requirements live in
[`specs/issue-strategy.md`](../../specs/issue-strategy.md); on any conflict the
spec wins. Planned under evanharmon1/harmon-init#855 (milestone "Issue strategy
overhaul").

## Context

Two strategy axes are decided in the spec but, until now, unrecorded and
unenforced: **tier** (which model stratum works an issue) and **method** (which
execution topology). The `tier:*` and `method:*` labels were seeded and are
provisioned from the manifest, but nothing behind them said how a consumer
resolves a label to a concrete model or workflow, how the two axes handle
conflicts, or — the load-bearing part — how an _unattended_ consumer may trust a
label at all. This ADR records those semantics; the config that parameterizes
them lands in `.devflow.toml` under the same harmon-init#855.

A naming collision is resolved here too: `.devflow.toml`'s Dev Loop round-cap
values (`light`/`standard`/`deep`) were called "tiers", colliding with the model
axis. From here they are **rigor levels**; "tier" belongs to the model axis
alone.

## Decision

### D1 — Two advisory axes, resolved by config, armed by nothing here

`tier:*` and `method:*` are **advisory classification**. A generated repo
invokes no model and runs no workflow because a label or a config table exists;
the tables are **inert routing preferences, never dependencies**. An acting
consumer may select only among vendors and harnesses the operator has already
configured and authenticated — the shipped defaults create no account, trial, or
paid-SaaS dependency (the Hard Rule is preserved), and escalation can never
switch a repo to a vendor it does not already use.

### D2 — The tier ladder

`local → economy → standard → frontier → apex`, plus `adaptive`. `frontier` is
opus-class; `apex` is mythos-class (`fable`, `sol`). `.devflow.toml` gains
`default_tier` and `[tier.<value>]` tables mapping families to
`agent-registry.json` model slugs, `escalate_to` chains, and `endpoint =
"local"` on the self-hosted tier. `tier:local` escalates to `economy`.
Privacy-pinning is a **future, separate concern label**, not a tier semantic.

The `local` tier's machinery binding is explicit: its entries resolve to the
registry's `-local` endpoint-variant harnesses (ADR 0005 D9), and validation
fails a `local` entry whose family has no registered `-local` harness. Today
`claude-code-qwen-local` (family `qwen`) is the only such harness, so `local` is
opt-in per family until more are registered.

### D3 — When escalation fires, and how a candidate is chosen

`escalate_to` chains validate as **referential, acyclic, and monotonic toward
`apex`**. _When_ escalation fires is a policy, not a cost heuristic: **failure,
refusal, or operator policy — never cost alone**.

Candidate selection is **deterministic**. The resolved tier names the stratum; a
`suggest:<family>[:<model>]` narrows within it **only when that family is
configured and eligible** (otherwise it is ignored with a note) — and unattended
consumption of a suggestion is subject to the same provenance invariant as the
strategy axes (D6). Absent a suggestion, the consumer's own configured backend
or harness picks. A tier with no eligible configured candidate escalates along
the chain, and an **exhausted chain stops with a report** — never a silent
vendor switch or downgrade.

**Deferred (follow-up):** `escalate_to` here validates the chain's _shape_, not
that each step maps to a not-weaker model. Encoding per-model capability in the
registry and validating tier maps monotonically ("a label only ever buys more")
is deferred to a follow-up issue rather than blocking harmon-init#855; until then the
guarantee is the chain shape plus the human-authored map.

### D4 — The method rank

`method:*` values are `oneshot | plan | plan-approved | orchestrate | council |
human-led`; `default_method` lives in `.devflow.toml`. Method conflicts resolve
by a **config-backed rank** (shipped order, most human oversight first):

```text
human-led > plan-approved > council > orchestrate > plan > oneshot
```

so topologies with no inherent ordering still resolve deterministically and
identically for every consumer.

### D5 — Resolution order and the explicit-instruction channel

Resolution order is **explicit instruction > label > config default >
built-in**, where an **explicit instruction** is one arriving on the operator's
**attributable channel** — the interactive session's human input, or the
automation's own configuration — and **never repository content**: issue bodies,
comments, and PR text are untrusted input and can never outrank labels or config.

Conflicts resolve **strongest-wins on tier** and by the method rank above (a
label only ever buys **more** capability or oversight); a **concrete tier beats
`adaptive`**. Below-default resolutions are **disclosed in the PR body** (the
harmon-init#809 rigor doctrine, extended). Merge-base copy applies when the change
review edits `.devflow.toml`, so a branch cannot lower the gate it is changing.

### D6 — Consumer-trust invariants (enforcement delegated)

Consumer trust is stated here as **invariants**; the concrete
timeline-validation algorithm is deliberately **not** specified in this repo — it
is design work under ponderousdev/foreman#139, and the adversarial scenarios
from the spec's review are carried there as required test cases. What is fixed
here is the contract every consumer must satisfy:

1. **Unattended automation** acts on a strategy or suggestion label only after
   verifying its provenance end-to-end from its own trusted-actor configuration,
   re-read immediately before acting — and **no sequence of untrusted mutations,
   applies or removals**, on any label of the axis, may move the resolved
   outcome away from what trusted actors' surviving actions alone would produce.
   Anything short of that resolves to the config default with a warning.
2. An **interactive session** treats these labels as advisory (the harmon-init#809 rigor
   posture) and requires operator confirmation for **any off-default
   resolution** — above or below, since one direction skips oversight and the
   other spends money — arising from a label not applied by an actor the
   operator has **authorized** (the operator themselves, or a login their
   configuration trusts). Attribution to _some_ identifiable actor is **not**
   authorization.
3. **Advisory families fail open** to the config default; **arming stays
   fail-closed**.

### D7 — Built-in fallbacks; `adaptive` is never terminal

Absent `.devflow.toml` (or its `[tier]`/`[method]` sections), both axes are
**advisory-informational only**: the labels still classify, and nothing resolves
them to a model or workflow. `adaptive` is never a terminal answer — the
consumer's preflight resolves it to a concrete ladder tier; a consumer with no
preflight capability treats it as `default_tier` where that key is configured.
**Validation rejects `adaptive` as a `default_tier`**, so that fallback is
always concrete; absent the config, `adaptive` resolves to nothing, like every
tier value under the axes-inert fallback.

### D8 — No auto-merge

No label, tier, or method arms auto-merge. Merging is always a human decision;
there is no `merge:*` family and no configuration that promotes a PR to merged.

### § D6 amendment to ADR 0005

ADR 0005 D6 recorded suggestions as human-authored advice. **Amended here:**
suggestions become human- **or agent-**authored. `suggest:*` stays
`family[:model]` (a vendor preference); `tier:*` is the human-decided **policy**
layer of the model axis. **`suggest:tier:<value>` is reserved, not built.**
`claim:*` stays on the family axis; the claim record gains `harness:` / `model:`
/ `session:` fields (harmon-devkit#450). ADR 0005 D6 carries a pointer to this
amendment.

## Consequences

- The two axes have a written contract a consumer — attended or unattended — can
  implement against, with the security-critical part (provenance, off-default
  confirmation, fail-open/closed) stated as invariants rather than left to each
  implementer's judgement.
- The `tier`/`method` distinction from rigor is now unambiguous: rigor has
  **levels**, the model axis has **tiers**. This repo's own docs and config
  follow suit; the vendored skills suite renames at its source
  (harmon-devkit#498).
- Nothing in a generated repo gains a runtime dependency: the tables are inert,
  and enforcement of the trust invariants rides foreman#139's rails.
- The capability-monotonicity check and the timeline algorithm are named,
  bounded, and deferred rather than half-built — the follow-up work is
  discoverable from here.
- `.devflow.toml` and its validator gain `[tier.*]`/`default_tier`/
  `default_method` under the same harmon-init#855; this ADR is the reference they
  implement.
