# Classify issues by impact, risk, and complexity, and derive the tier

Date: 2026-09-30

## Status

Accepted

D2's storage of the Tier axis is amended by [ADR 2026-10-01 (Tier as a label)](2026-10-01-store-the-tier-as-a-label-on-every-owner-type.md): the Tier is a label on every owner type.

D2's scales and D3's writers are amended by [ADR 2026-10-01 (Priority AI axis)](2026-10-01-add-a-priority-ai-axis-suggested-by-agents.md): a second axis, Priority (AI), `p0`–`p4`, written by agents and humans; the human Priority overrides it.

D4's "Reconcile drift" bullet is amended by [#1450](https://github.com/evanharmon1/harmon-init/issues/1450): the schedule runs per repository under `GITHUB_TOKEN` (monthly on organization repositories, daily on personal ones) because `GITHUB_TOKEN` is repository-scoped; the organization-level daily walk is an opt-in caller holding an App installation token ([#1463](https://github.com/evanharmon1/harmon-init/issues/1463)).

Supersedes whatever an earlier record says that conflicts with the
retirements in D8 — `suggest:*`, the `Size` project field, the
personal-project `Priority` field, the ponderousdev `Agent` issue field, and
`tier:adaptive` — among them
[ADR 2026-08-07](2026-08-07-unified-agent-vocabulary.md) D6's suggestion
half, ADR 2026-08-07 D10's listing of `Size` as planning metadata, and
[ADR 2026-08-16](2026-08-16-method-and-tier-axes.md)'s D3 candidate
narrowing, its D6 suggestion provenance, its amendment to ADR 2026-08-07 D6,
and its `adaptive` tier. The Tier derived below replaces `suggest:*`. The
`claim:<family>[:<model>]` half of ADR 2026-08-07 D6 stands unchanged.

Amends [ADR 2026-08-16](2026-08-16-method-and-tier-axes.md) D5 (the resolution
order) by inserting the pinned and derived Tier (D5 below), and
[ADR 2026-08-24](2026-08-24-rigor-and-strategy-axes.md) D5 (which role a tier input
targets) by adding the pinned Tier as another implementer-only input.
Everything else in those two records stands, apart from the rules
superseded above.

The design record is the body of epic
[#1444](https://github.com/evanharmon1/harmon-init/issues/1444) and its
handoff comment, from the maintainer's design session of 2026-09-30; this
record transcribes its decisions. The vocabulary is in the
[glossary](../glossary.md) under "Issue classification".

## Context

Issues carried almost no inherent classification. `Priority` and `Effort`
existed as unused organization issue fields, `Size` was a hand-set project
field, model routing depended on a human applying a `suggest:*` or `tier:*`
label, and `needs-triage` was set and cleared by hand. With AI filing and
working most issues, the human cannot triage the volume, and the model tier
an issue gets was never derived from what the issue is.

Two constraints shaped the mechanics:

- **Field types.** Organization issue fields are TEXT, SINGLE_SELECT, DATE,
  NUMBER, or MULTI_SELECT; there is no boolean. Personal-account repositories
  have no issue fields at all, only labels.
- **Actions minutes.** The harmonops and ponderousdev organizations are on
  the Team plan, with 3,000 shared minutes a month, and nearly every
  ponderousdev repository is private. A job bills a full minute, and GitHub
  emits one `labeled` event per label, so a per-event writer for agent
  traffic spends minutes on every write. The four evanharmon1 repositories are public and run free.

## Decision

### D1 — Two layers: issue classification and execution policy

**Issue classification** is the set of inherent attributes of an issue: what
it *is*. **Execution policy** (`.devflow.toml`: rigor, strategy, role tiers,
budgets) decides how the factory *runs* an issue, and may override any
default the classification implies. Fields describe what an issue is;
`.devflow.toml` decides how it is run.

### D2 — The axes and their scales

Impact, Risk, Complexity, Tier, Priority, and Effort are issue fields on
organization repositories and exclusive labels on personal-account
repositories; Start date and Target date are organization fields only. Type,
`area:*`, `layer:*`, and `domain:*` keep their existing storage: the native
Issue Type, or the work-type label on personal-account repositories, and
labels.

| Axis | Scale | Who sets | Required for "triaged" |
|---|---|---|---|
| Impact | minimal, low, medium, high, massive | AI or human | yes |
| Risk | trivial, low, medium, high, critical | AI or human | yes |
| Complexity | xs, s, m, l, xl | AI or human | yes |
| Tier | local, economy, standard, frontier, apex | derived from Risk × Complexity | no (a cache) |
| Priority | urgent, high, medium, low | human only | no; unset means an agent asks before starting |
| Effort | 1, 2, 3, 5, 8, 13, 20 (modified Fibonacci) | human only, human tasks only | no |
| Start date, Target date | dates | human only, organization only | no |
| Type or work-type, `area:*`, `layer:*`, `domain:*` | existing, plus a `none` value on each of the three families | AI or human | yes |

Rubric notes, which are part of the decision:

- **Impact** is core benefit versus marginal benefit, not common path versus
  uncommon path: a rarely triggered bug with severe consequences can be high
  impact.
- For a bug fix, the **harm prevented** belongs in Impact and the **danger of
  the fix** belongs in Risk.
- **`local`** is work a small self-hosted model can do, and that may take a
  while.

The rubric is short-form in the registry and long-form in the triage skill.

### D3 — AI-set inputs, without safeguards

Impact, Risk, and Complexity may be set by an AI or a human, and
agent-authored issues must arrive fully classified except Priority. No
safeguard constrains an AI-set input (see Declined alternatives).

### D4 — Tier is derived by a risk-dominant matrix

Tier is a pure function of Risk × Complexity over a risk-dominant matrix
stored in `.devflow.toml`, implemented once in `devflow-policy.mjs` (vendored
in harmon-init and harmon-devkit, with conformance fixtures as the drift
test). The starting cells:

| complexity \ risk | trivial | low | medium | high | critical |
|---|---|---|---|---|---|
| xs | local | local | economy | standard | frontier |
| s | local | economy | standard | standard | frontier |
| m | economy | standard | standard | frontier | apex |
| l | standard | standard | frontier | frontier | apex |
| xl | frontier | frontier | frontier | apex | apex |

The stored Tier is a **materialized cache** that readers recompute when
absent:

- **Write at source.** Every writer of Risk or Complexity (triage,
  track-work, breakdown) writes Tier and `needs-triage` in the same call, so
  agent writes never wait on GitHub Actions.
- **Reconcile drift.** A daily organization-level reconciler — one reusable
  workflow, called from each organization's `.github` repository — fixes
  drift. A per-repository event workflow with job-level filters catches the
  rare human edit in the GitHub UI, at no cost when skipped.
- **Recompute when absent.** Readers recompute Tier from the inputs when the
  cache is absent.

### D5 — The Tier pin and the new resolution order

A human pins a tier from the GitHub UI by setting Tier and adding the
`tier:pinned` label, on both owner types. Nothing automated writes over a
pinned Tier. A pin is a label input like any other, so the label-provenance
rule applies to it: an interactive session confirms a pin the operator has
not authorized, and unattended automation honors a pin only after verifying
its provenance, otherwise resolving as if it were absent
([ADR 2026-08-16](2026-08-16-method-and-tier-axes.md) D6; `AGENTS.md` "Nothing
here arms anything").

Execution-policy resolution becomes:

1. operator instruction
2. pinned Tier
3. `rigor:*` and `tier:<role>:*`
4. derived Tier
5. `default_rigor`

The built-in fallback for an absent policy file stays as ADR 2026-08-16 D5 and
AGENTS.md describe it.

A pin sets the **implementer** tier only. The derived Tier likewise sets
only the implementer tier; the other role tiers come from the resolved rigor
profile. A pin can leave the resolved role tiers outside the ladder
invariants; that is disclosed in the PR body, not corrected. The
authored-profile role-tier floor that `devflow-policy.mjs` enforces on
`[rigor.*]` tables is unaffected and still rejects a profile that violates
it.

### D6 — "Triaged" is derived

An issue is **triaged** when every required axis in D2 is present: Type (or
the work-type label), one label from each of the `area:*`, `layer:*`, and
`domain:*` families (or that family's explicit `none` value), Risk,
Complexity, and Impact. `needs-triage` is derived from that and never set by
hand.

### D7 — The agent queue

The agent queue is every issue that is open, triaged, has Priority set,
carries no `claim:*` label, is not `human`, is not `needs-review`, and is not
blocked. `needs-review` (maintainer decision 2026-10-01) is added to the
issue by the integration stage at ready-for-review, in the step that removes
`claim:*`, and removed if review pulls the work back into fix rounds; it
keeps an issue whose PR awaits human review out of the queue and lists what
awaits the maintainer. The integration stage is a vendored harmon-devkit
skill, so the write lands through harmon-devkit#1255 and a skills-pin bump
here; the label itself is #1447's. The project board and its Status pipeline
stay as they are, for human views. Milestones are unchanged.

### D8 — Retirements, and what is unchanged

Retired:

- `suggest:*`, including `suggest:<family>:<model>` — superseded by Tier.
- The `Size` project field — superseded by Effort (human tasks) and
  Complexity (every issue).
- The personal-project `Priority` field.
- The ponderousdev `Agent` issue field.
- `tier:adaptive` (maintainer decision 2026-10-01): it has no rung on the
  Tier scale, so the label is retired with a migration. The migration, and
  every surface that still treats `adaptive` as a tier, belong to #1447 (the
  registry value) and #1449 (the policy readers, the spec, and the schemas),
  with the vendored reader's counterpart in harmon-devkit#1248.

Unchanged:

- `claim:<family>[:<model>]`, unchanged: the marker naming the model family
  that took the work (ADR 2026-08-07 D6) — a signal, not a mutex; the harness and
  runtime live in the claim record.
- `tier:<role>:*` labels, as execution-policy overrides.
- The model catalog, which stays in `agent-registry.json`; `.devflow.toml`
  selects from it and may override it per repository.

### D9 — Ownership and rollout

harmon-init ships the registry, the fields, the matrix, the policy reader,
the reconciler workflow, and the docs (root and template twins). harmon-devkit
ships the skills that write and read the axes. Rollout provisions every
platform repository, then a bulk AI backfill classifies every open issue,
with a skim of the resulting tier distribution per repository.

## Declined alternatives

- **Safeguards on AI-set inputs.** Monotonic rules, floors, and a single
  write path were considered and declined as not worth their cost. A human
  who disagrees with a derived Tier pins it (D5), and an operator instruction
  outranks everything.
- **Keeping `Size`.** It is a hand-set project field, and the human cannot
  set fields by hand at the volume AI files and works. It is superseded by
  Complexity (on every issue, AI-settable) and Effort (the human time
  estimate, human tasks only).
- **A separate override field.** A pin is the Tier field itself plus the
  `tier:pinned` label, not a second field holding an override tier. Issue
  fields have no boolean type, and personal-account repositories have no
  issue fields, so the marker that works on both owner types is a label; the
  Tier field then carries the one value readers use, whether derived or
  pinned.

## Consequences

- Every issue gains a model tier derived from what it is, instead of a
  human-applied suggestion, and "triaged" becomes checkable rather than a
  hand-maintained label.
- Resolution gains two layers, the pinned Tier and the derived Tier, and
  every resolved role-tier invariant a pin breaks is disclosed in the PR body.
- Agent writes are free of Actions minutes on the hot path; drift is
  corrected once a day per organization rather than per event.
- A write that updates Risk or Complexity but fails on Tier leaves a stale
  Tier until the next write or the daily reconciler corrects it; the design
  accepts that window rather than adding safeguards (D3).
- On personal-account repositories an unqualified `tier:<value>` label
  changes meaning, from a human implementer override (ADR 2026-08-24 D5) to the
  stored, derived Tier that automation may rewrite; a human who wants to fix
  the tier adds `tier:pinned`. Rollout must pin any human-applied
  `tier:<value>` label on an open issue before the backfill runs
  ([#1453](https://github.com/evanharmon1/harmon-init/issues/1453)).
- #1449 puts the matrix in `.devflow.toml`, so it also amends that file's
  header comment, which today scopes the file to `tier_order` and tier
  choices, and `.devflow.schema.json`.
- The work is split across the epic's children: the label registry
  ([#1447](https://github.com/evanharmon1/harmon-init/issues/1447)), the
  organization fields and Effort ladder
  ([#1448](https://github.com/evanharmon1/harmon-init/issues/1448)), tier
  resolution and the resolution order
  ([#1449](https://github.com/evanharmon1/harmon-init/issues/1449)), the
  reconciler workflows
  ([#1450](https://github.com/evanharmon1/harmon-init/issues/1450)), the
  project-field retirements
  ([#1451](https://github.com/evanharmon1/harmon-init/issues/1451)), the
  documentation ([#1452](https://github.com/evanharmon1/harmon-init/issues/1452)),
  the rollout ([#1453](https://github.com/evanharmon1/harmon-init/issues/1453)),
  the backfill ([#1454](https://github.com/evanharmon1/harmon-init/issues/1454)),
  and the harmon-devkit skills that write and read the axes.
