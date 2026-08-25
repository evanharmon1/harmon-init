# Devflow: rigor and strategy execution policy

`.devflow.toml` is the portable execution-policy vocabulary behind the Dev
Loop (`AGENTS.md`). Two axes classify a change:

```text
rigor    = how much confidence, effort, depth, and budget the work gets
strategy = how the work is organized and performed
```

A `rigor:*` or `strategy:*` label is a durable record of intent on an issue.
Applying one **invokes no model and starts no workflow** — it is advisory
until a consumer (an agent entering the Dev Loop, Foreman) separately
resolves it. `.devflow.toml` holds the numbers, the field values, and the
rationale beside each setting; this guide holds the model, the worked
resolution examples, the natural-language interface, and the boundaries
between this file and the other registries. Neither restates the other's
numbers — if the two ever disagree, `.devflow.toml` is correct and this guide
is stale and needs a follow-up edit.

Everything below is read from the shipped `.devflow.toml` as of this guide's
last edit. A repository that has customized its own copy (see
"Customizing this for your own repository" below) may show different values;
its own file is always the authority for what it actually does.

## Rigor: a review policy, three role tiers, and a budget

Each `[rigor.<level>]` table is a pointer to three lower-level tables, not a
pile of numbers in its own right:

| Level | Review policy | Orchestrator tier | Implementer tier | Reviewer tier | Budget |
| --- | --- | --- | --- | --- | --- |
| `trivial` | `none` | economy | economy | economy | `trivial` |
| `minimal` | `driveby` | standard | economy | standard | `light` |
| `light` | `light` | frontier | economy | frontier | `light` |
| `standard` | `standard` | frontier | standard | frontier | `standard` |
| `thorough` | `thorough` | apex | standard | apex | `thorough` |
| `deep` | `deep` | apex | frontier | apex | `deep` |

Three role tiers, not one shared tier, because the three jobs have different
minimum-capability needs: the **orchestrator** plans and coordinates, the
**implementer** writes the change, the **reviewer** checks it. A cheap
implementer paired with a strong reviewer is a deliberate, common shape —
`light` ships exactly that (economy implementer, frontier reviewer) — not an
inconsistency to "fix".

Two invariants hold for every level above: `orchestrator_tier >=
implementer_tier` and `reviewer_tier >= implementer_tier`, on the tier
ladder below — a floor relationship between roles, not a ceiling on any one
role's own tier. An explicit, attributable operator override may set a
role's tier to anything on the ladder, whether that ends up above or below
what the resolved level's built-in profile specifies for that role; either
direction is recorded and disclosed as an **off-profile** decision, never
silently applied; see "Role tiers" and "Disclosure" below.

## Review policies: the challenge/review/shepherd ceilings

Six review policies exist — `none`, `driveby`, `light`, `standard`,
`thorough`, and `deep` — each setting `challenge`, `review`, `shepherd`, and
`min_rounds` to its own values. The actual numbers live only in
`.devflow.toml`'s `[review.*]` tables; per
[docs/conventions.md](../conventions.md), that file is the single source of
truth for them and this guide does not keep its own copy to go stale.

`challenge`, `review`, and `shepherd` are **per-stage maximum** heuristic AI
passes (Dev Loop stages, `AGENTS.md`). `min_rounds` is the **minimum** passes
an enabled stage must actually run before it may take the early clean-round
exit (two consecutive adjudicated-clean rounds always exits regardless of
`min_rounds`; a single round with no findings at all needs `min_rounds`
satisfied first — see `AGENTS.md`, "Loop cap and exit", for the exit
conditions themselves, which this file does not restate). Validation holds
`0 <= min_rounds <= min(challenge, review, shepherd)` for every policy —
`none` is not a special case, it is what that inequality gives you when a
policy legitimately sets every cap to its floor.

These are **ceilings, never quotas**:

- **A cap of 0 disables that stage outright.** Zero rounds run, so there is
  nothing of that stage's own to adjudicate or defer. Nothing else moves: the
  deterministic gates this repository already has (tests, CI, security
  scanners, branch protection, required human review) are unaffected, and the
  obligation to adjudicate and record any finding that *does* surface from
  another source is unchanged. Zero AI review rounds is a valid choice for
  `trivial` — it is not a bypass of anything else.
- **A cap of 1 is an ordinary small cap**, not a special case. The stage takes
  a single pass; if that pass adjudicates clean, the stage exits on it — the
  same "capped final round" exit a cap of 5 uses on its fifth round, just
  reached sooner.
- **A cap is a ceiling.** Reaching it ends the configured AI-review effort for
  that stage; it never lowers a deterministic gate, and it never waives the
  obligation to adjudicate and record whatever did surface before the cap.

**`shepherd` varies with the policy now**, instead of holding one number for
every rigor level regardless of depth. The reason is what it bounds:
`challenge` and `review` bound work the agent generates for itself — each
round's fixes are the next round's input, which is exactly what makes a low,
self-referential cap safe. `shepherd` bounds *other people's* findings — CI
failures, human review comments, Codex cloud review — and a shallower rigor
level legitimately expects to answer fewer of them before promoting.
Lowering `shepherd` does not reduce effort already spent; at the cap, the
answer is "stop and escalate", not "silently drop the finding". Where a
policy disables `shepherd` outright — `trivial` rigor's `none` policy, today
— escalating happens on the very first thing that would need an answer,
because there is no fix round left to spend — and with no fix round, there
is also no round left to trigger a fresh `@codex review` from, so the
readiness gate's current-head Codex cycle requirement drops out too, exactly
the way it already does wherever Codex review is off entirely. Nothing else
about the readiness gate moves: CI still has to be green, and a review
finding that lands anyway is answered by leaving the PR draft with a
blocker report for a human, never by an agent fix round the cap does not
allow — see `AGENTS.md`'s shepherd stage and readiness gate for the full
mechanics.

AI challenge, review, and shepherd passes are **heuristic confidence and
cost controls** — they are not, and cannot be, substitutes for deterministic
tests, CI, security scanners, branch protection, or this repository's human
merge and release rules. A `none` or `driveby` policy is a legitimate choice
precisely because those deterministic gates keep doing their job with or
without an AI pass on top of them.

## Budgets: portable resource ceilings

Five budget envelopes exist — `trivial`, `light`, `standard`, `thorough`,
and `deep` — each setting `max_agent_runs`, `max_parallel_agents`,
`wall_clock_min`, and `allow_tier_escalation`. As with the review policies
above, the actual figures live only in `.devflow.toml`'s `[budget.*]`
tables; this guide names the envelopes and explains what each field means,
not what any of them is currently set to.

Only five envelopes back six rigor levels: `minimal` reuses `light`'s budget
— its extra caution over `trivial` lives entirely in the review policy
(`driveby` instead of `none`) and the role tiers (standard orchestrator and
reviewer instead of economy), not in a separate budget.

`max_agent_runs` and `max_parallel_agents` bound **implementation and
orchestration** agent invocations — the main session, plus any workers it
delegates to or council proposers it starts. They do **not** count AI review
passes: `challenge`, `review`, and `shepherd` are bounded separately, by the
review policy above, and draw against nothing here. That separation is why
a rigor level's budget is never in tension with its own review policy — the
two sets of numbers count different things, one agents doing the work, the
other heuristic passes checking it — and it is also why a strategy's `min_agents` compares
cleanly against this budget (see "Strategy × rigor compatibility" below):
both sides count the same kind of agent. `wall_clock_min` bounds elapsed
time; `allow_tier_escalation` says whether a role may climb its tier's
`escalate_to` chain (see "Role tiers" below) under this budget at all —
`trivial` and `light` forbid it, because escalation is itself a cost
decision and those two budgets are choosing not to make one automatically.

The schema also permits optional `max_tokens` / `max_usd` keys, and **every
shipped envelope above omits both**. This is deliberate: a consumer that
cannot actually measure tokens or spend must report the corresponding limit
as **unenforced** rather than claiming an enforcement it cannot perform.
Silently pretending a budget is respected when nothing is watching it is
worse than admitting it is not — add either key only where the measurement
genuinely exists.

Budgets here are a **target**, not the final word: Foreman intersects a
resolved envelope with its own hard ceilings in `.foreman.toml` rather than
trusting either source alone (see "Ownership boundaries" below) — that
intersection is Foreman-side work, out of scope for this file.

## Strategy: how the work is organized

| Strategy | Topology | Planning | Delegation | Coordination | Selection | Synthesis | Min agents | Human gates |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `oneshot` | single-agent | inline | none | — | — | — | — | none |
| `plan` (default) | single-agent | explicit | optional | — | — | — | — | none |
| `plan-approved` | single-agent | explicit | optional | — | — | — | — | after-plan |
| `orchestrate` | lead-and-workers | explicit | required | parallel-when-independent | — | — | 2 | none |
| `council` | independent-proposals | independent | required | — | judge | true | 2 | none |
| `human-led` | human-directed | collaborative | optional | — | — | — | — | after-discovery, after-plan, before-publication |

The fields, explained without leaning on their names:

- **`topology`** — the structural arrangement of agents. `single-agent` is
  one **accountable lead** agent; it may hand a bounded unit of work to a
  helper subagent, but only where `delegation` permits it (`optional`) —
  that helper is auxiliary, never a first-class unit of the topology
  itself. `lead-and-workers` makes the delegate first-class: the lead plans
  the task, decomposes it, and hands bounded pieces of that plan to the
  workers it delegates to. `independent-proposals` (`council`'s topology)
  also makes the delegate first-class, but delegates a different kind of
  unit: a coordinating agent hands each proposer the *whole problem*,
  planning nothing about how the proposer gets there (`planning =
  independent`, below) — no proposer is in charge of, or aware of, the
  others — and later judges what comes back. `human-directed`
  (`human-led`'s topology) is a human directing bounded AI contributions.
- **`planning`** — whether and how a plan is produced before work starts:
  folded into the first turn with no separate artifact (`inline`), a stated
  plan as its own step (`explicit`), each proposal planning on its own before
  anything is compared (`independent`, council only), or produced together
  with a human (`collaborative`, human-led only).
- **`delegation`** — whether a coordinating agent hands a bounded unit of
  work to other agents: never (`none`), may (`optional`), must (`required`).
  `required` appears on both `lead-and-workers` and `independent-proposals`
  — a decomposed sub-task in one, a whole independent proposal in the other
  — because neither topology's shape exists without that hand-off; it
  appears on neither `single-agent` (where any helper is optional) nor
  `human-directed` (where a human, not an agent, coordinates).
- **`coordination`** — scheduling and independence policy among delegated
  agents. Only `orchestrate` sets it today: `parallel-when-independent` means
  workers whose slices of work do not depend on each other run concurrently
  rather than in sequence.
- **`selection`** — how multiple independent outputs get compared and
  chosen. `council`'s `judge` value means a distinct evaluating pass compares
  every proposal against the actual requirements — a judged comparison, not a
  vote.
- **`synthesis`** — whether compatible strengths from more than one
  independent output may be combined into one deliverable, rather than
  picking exactly one proposal verbatim. `council` sets this `true`.
- **`min_agents`** — the floor that keeps a one-agent run from being
  represented as the topology it claims. Two strategies set one, both `2`:
  `council` (a single agent cannot produce independent proposals to judge
  between) and `orchestrate` (`delegation = required` means the lead must
  hand off bounded work to at least one worker, so a lead running alone
  cannot satisfy its own topology either).
- **`human_gates`** — explicit pause points this strategy inserts, drawn from
  the allowed set below. This is the **only** configurable human-gate
  vocabulary: `after-discovery`, `after-plan`, `before-delegation`,
  `before-selection`, `before-synthesis`, `before-scope-expansion`,
  `before-budget-escalation`, `before-publication`, `before-ready-for-review`,
  `each-phase`. **Constitutional approvals — merge, release, destructive
  actions, credential-store writes, security-relevant settings — are never in
  this list.** They are enforced independently of rigor and strategy
  entirely (`AGENTS.md` hard rules, branch protection, CODEOWNERS), and a
  strategy naming one as a `human_gates` entry is a validation error, not a
  stricter gate — configuring a gate that already exists unconditionally
  would only create a second, weaker place for it to live.

`plan` is `default_strategy`: a single accountable lead that plans
explicitly but proceeds without a human plan-approval gate, and may spin up
a bounded helper subagent if it chooses to — `delegation = optional` on a
`single-agent` topology means exactly that, not a second first-class agent.
`oneshot` is the fastest path (no separate plan step, and `delegation =
none` — not even a bounded helper) for small, well-understood changes;
`plan-approved` adds exactly one human checkpoint (after the plan, before
implementation) to the same single-agent-plus-optional-helper shape.
`orchestrate` and `council` are the two topologies where workers are
first-class structural units rather than optional helpers — a lead
assigning work top-down, or several agents proposing independently for a
judge to compare — and `delegation = required` appears on both of them and
nowhere else, consistent with the rule above. `human-led` is the only
topology where a human — not an agent — holds the central decisions, with
AI doing bounded pieces between the gates.

## Role tiers: the model-stratum ladder

The tier ladder is `local → economy → standard → frontier → apex`, plus
`adaptive` (a cheap preflight classifies the work, then chooses or escalates
— `adaptive` is never a legal value for a `[rigor.*]` role tier or an
override; it always resolves to a concrete rung before it reaches a role).
`frontier` is opus-class; `apex` is mythos-class. Families appear at a tier
only where they actually have a model of that stratum, so most families top
out at `standard` — the upper strata are genuinely narrow by design, not an
oversight.

There is no top-level `default_tier`. The default for all three roles is
whatever the resolved `[rigor.*]` level's `*_tier` fields say (the table
above); overrides refine that per role rather than replacing a separate
global default:

- An **unqualified** `tier:<value>` label or instruction overrides the
  **implementer** tier only — the common case, since a human saying just
  "tier" usually means "make the implementer cheaper or stronger."
- A **scoped** `tier:orchestrator:<value>` / `tier:implementer:<value>` /
  `tier:reviewer:<value>` targets exactly the role it names. All 15 scoped
  values (3 roles × the 5 concrete tiers — `adaptive` is never legal here)
  are **provisioned**, the same as every other rigor/strategy/tier label —
  `task setup:github-labels` creates them, not an agent on first use.
- Absent any override, every role comes from the resolved rigor level alone.

`escalate_to` chains climb toward `apex` and fire on failure, refusal, or
operator policy — never cost alone. An exhausted chain stops with a report
rather than silently switching vendor or downgrading, and `allow_tier_escalation`
in the resolved budget (above) gates whether escalation may fire under this
change's budget at all. These tables are **inert routing preferences, never
dependencies**: a repository invokes no model and runs no workflow because a
table exists, an acting consumer selects only among vendors and harnesses the
operator has already configured and authenticated, and the shipped defaults
add no account, trial, or paid-SaaS dependency.

## Resolution order and conflicts

Both axes resolve in the same order:

```text
explicit operator instruction (attributable channel only — this session's
human input, or an automation's own trusted configuration; NEVER issue or
PR text, which is untrusted repository content)
  > rigor:*/strategy:* labels on the issue
    > default_rigor / default_strategy
      > the built-in fallback — used only when .devflow.toml is entirely
        absent: the `standard` review policy, strategy `plan`, tiers inert
        (see .devflow.toml for the standard policy's actual numbers)
```

Advanced overrides (`tier:<role>:<value>`, or an unqualified `tier:<value>`,
which targets the implementer only) **refine** the selected rigor/strategy
profile; they never supply an independent default of their own. Absent an
override, every lower-level value — review caps, all three role tiers,
budget, every strategy field — comes from the resolved rigor and strategy
alone.

**Rigor conflicts resolve to the strongest label present**, ordered by
`.devflow.toml`'s `rigor_order` (weakest to strongest — the *only* place
"strongest" is defined for rigor). Two rigor labels on one issue therefore
resolve to a single, whole, internally-consistent profile — the stronger
level's review policy, all three of its role tiers, and its budget — never a
mix of numbers assembled from both labels. A conflict can only ever buy more
depth and budget.

**Strategy conflicts are ambiguous.** Unlike rigor's more-or-less continuum,
two topologies are not orderable against each other — there is no
`strategy_order` and none is planned. Two `strategy:*` labels on the same
issue are a **resolution error**, not a pick: an interactive session asks
which one applies; unattended automation falls back to `default_strategy`
with a warning rather than guessing between them.

A `rigor:` or `strategy:` value that names nothing in `.devflow.toml` is
ignored rather than guessed at.

**Worked examples:**

- Issue carries `rigor:light` and `rigor:deep` → resolves to `deep` (its
  whole profile: review policy `deep`, tiers apex/frontier/apex, budget
  `deep`), because `deep` sorts after `light` in `rigor_order`.
- Issue carries `strategy:council` and `strategy:orchestrate` → ambiguous.
  An interactive agent asks which was intended; an unattended one resolves to
  `default_strategy` (`plan`) and records a warning that two strategy labels
  were present and unresolved.
- Issue carries only `tier:economy` (unqualified) under `rigor:standard` →
  the implementer tier becomes `economy` (down from `standard`'s built-in
  `standard`); orchestrator and reviewer stay at `frontier` from the rigor
  profile. This is an off-profile implementer tier and is disclosed (see
  below).

Labels are advisory, not authenticated: applying one takes no more than
ordinary repo-triage access, and GitHub's **triage** role can apply a label
with no push access to `.devflow.toml` at all. That is exactly why an
interactive session confirms any off-default resolution with the operator,
and why unattended automation must verify a label's provenance against its
own trusted-actor configuration before acting on it rather than trusting the
label alone — see "Disclosure" below.

## The merge-base rule

When the change under review **edits `.devflow.toml` itself**, resolve
*every* parameter it needs — every rigor level, every review policy, every
budget envelope, every strategy definition, every tier map, and both
top-level defaults — from the **merge-base** copy rather than the branch
copy. Otherwise a branch could lower the very gate it is being reviewed
against: dropping a level, lowering a cap, repointing a tier map to a weaker
model, or lowering `default_rigor`/`default_strategy` would all pass
validation on the branch's own terms while silently weakening the review the
branch itself is under. An explicit human instruction still overrides this,
since that is an attributable decision rather than the branch deciding for
itself.

## Disclosure

Two distinct things get disclosed in the PR body, and they are not the same
fact:

- **Off-default resolution** — the resolved `rigor` or `strategy` differs
  from `default_rigor`/`default_strategy`, in *either* direction. Above
  default spends more than the repository's baseline; below default spends
  less oversight — both are worth a human seeing, for opposite reasons.
- **Off-profile role tier** — an explicit override sets a role's tier to
  anything other than what its resolved rigor level's built-in profile
  specifies for that role, in *either* direction. Raising a tier spends more
  than the resolved rigor implies; lowering one spends less oversight —
  parallel to off-default resolution above, both are worth a human seeing,
  for opposite reasons. Lowering can additionally violate
  `orchestrator_tier >= implementer_tier` or `reviewer_tier >=
  implementer_tier`, but the disclosure obligation does not depend on
  whether it does — a raise that stays within those invariants is just as
  much an off-profile deviation as a lowering that breaks them. This can
  happen even when the rigor itself is exactly at default — "standard rigor
  with an economy implementer" (see the natural-language examples below) is
  on-default rigor and off-profile tier at the same time.

Unattended automation carries a further obligation beyond disclosure: it acts
on a `rigor:*`/`strategy:*`/`tier:*` label only after verifying that label's
provenance end-to-end against its own trusted-actor configuration,
re-checked immediately before acting, and otherwise falls back to the config
default with a warning rather than trusting an unverified label. An agent
never applies one of these labels to itself.

## Reviewer selection: tier floor, harness, and family diversity

Three distinct concepts sit behind "who reviews this", and conflating them
produces a false ranking:

- **`reviewer_tier`** is the required **capability stratum** — a floor for
  the primary reviewer's model, on the same ladder as every other role tier.
  It is not a global quality ranking of review *products*.
- **A review harness** is the **executable mechanism** that actually
  performs the review — Codex CLI, Codex cloud review, CodeRabbit, Copilot,
  Claude Code Action, or any other configured integration. `agent-registry.json`
  is the inventory of which harnesses exist and which roles (`orchestrate` /
  `implement` / `review`) each one can serve.
- **Family diversity** is an **independence preference**, separate from
  both: prefer a reviewer whose model family differs from the implementer's,
  because a same-family reviewer shares more of the implementer's blind
  spots than a differently-trained one does.

The default policy: prefer a **different-family** reviewer at the required
tier; fall back to an eligible **same-family** reviewer at the required tier
**with disclosure** when no different-family candidate is configured. An
explicit policy may instead require a different family outright — that hard
requirement **fails resolution** rather than silently weakening itself back
to same-family. Moving a reviewer *above* the requested tier is permitted
only by the effective escalation/budget policy (above), never as a free
upgrade nobody asked for. A lower-tier reviewer is **supplemental only** — a
fast, cheap pass alongside the real one — and does not satisfy the
primary-reviewer requirement unless an attributable operator explicitly
accepts that substitution.

## Strategy × rigor compatibility

A strategy whose `min_agents` exceeds the resolved budget's
`max_agent_runs` or `max_parallel_agents` is an **incompatibility**:
resolution reports it and stops, and never silently substitutes a different
topology or silently widens the budget. Two strategies set a floor at all —
`council` and `orchestrate` — and both compare against the same kind of
number, since the budget's `max_agent_runs`/`max_parallel_agents` count
implementation/orchestration agents exactly like `min_agents` does (see
"Budgets" above). Every other shipped strategy (`oneshot`, `plan`,
`plan-approved`, `human-led`) sets no floor at all, so it resolves under any
rigor level, at any budget.

`trivial` is the one rigor level whose budget caps parallel agents below
what `council` and `orchestrate` both need to exist as their own topology;
every other shipped budget's ceiling is at or above that floor. `council`
under `trivial` and `orchestrate` under `trivial` are therefore the two
documented incompatibilities in the shipped configuration, and both fail for
the same reason. Every other strategy×rigor pairing resolves cleanly — see
`.devflow.toml`'s `[budget.*]` and `[strategy.*]` tables for the figures
behind that comparison, if you need the exact numbers rather than the shape
of the rule.

## Ownership boundaries

`.devflow.toml` sits beside three other files that each own a distinct piece
of the picture; none of them re-derive each other's numbers:

| File | Owns | Relationship to `.devflow.toml` |
| --- | --- | --- |
| `.devflow.toml` | Rigor/strategy/review/budget/tier semantics and the shipped values themselves | — |
| `label-registry.json` | Label-family metadata: writers, trust, color, lifecycle, exclusivity | The `rigor` and `strategy` families' **values and descriptions** are sourced from `.devflow.toml` (marked `"source": "devflow"`); the registry never invents its own numbers for them, and a drift check keeps the two in step |
| `agent-registry.json` | The model family/model/harness inventory, Foreman adapter mappings, and per-harness `roles` (`orchestrate` / `implement` / `review`) | Every `[tier.*]` model slug in `.devflow.toml` must resolve against this registry; a role tier is meaningless without a registered, authenticated harness actually capable of serving it |
| `.foreman.toml` | Foreman arming, trusted actors, runner/backend selection, authentication, billing mode, and hard operational ceilings | Authoritative on its own terms — `rigor:*`/`strategy:*` never arm dispatch, `foreman:*` remains the sole arming surface, and Foreman intersects a resolved devflow budget with its own ceilings rather than trusting either source alone |

## Customizing this for your own repository

`.devflow.toml` ships to every generated repository as a plain file — it is
not rendered from Copier answers, so every repository starts from the exact
same rigor/strategy/review/budget/tier model described above. From that
point on, it is yours: edit it the way you would edit your own `AGENTS.md`.
harmon-init remains the upstream authority for what the *shipped* defaults
mean and recommends, but a `copier update` treats a locally-edited
`.devflow.toml` the same way it treats any other file you have changed —
ordinary three-way merge, with conflict markers where your edit and an
upstream change touch the same lines. If you vendor
`scripts/test-devflow-config.sh` yourself to keep validating your edits, you
own re-running it; harmon-init only runs that script against its own root
and template copies at release time.

Two things are worth keeping if you do customize: the invariants
(`orchestrator_tier >= implementer_tier`, `reviewer_tier >= implementer_tier`
for every level; `0 <= min_rounds <= min(challenge, review, shepherd)` for
every policy; `rigor_order` a permutation of your `[rigor.*]` keys), and the
merge-base rule above — both keep a branch from quietly loosening the gate it
is being reviewed under, which matters just as much for a customized policy
as for the shipped one.

## The natural-language interface

Rigor and strategy are designed to be said in plain language, not just
applied as labels. An operator's instruction always outranks a label (see
"Resolution order" above), so an agent parsing a natural-language request
needs to map it onto a concrete, resolved profile. Six worked examples:

**"Use light rigor and council strategy."**
Rigor `light` (review policy `light`; tiers frontier/economy/frontier;
budget `light`) + strategy `council` (independent proposals, judge
selection, synthesis). Compatible: `light`'s budget covers `council`'s
floor on parallel agents — see `.devflow.toml` for the exact figures behind
that.

**"Deep rigor, plan-approved."**
Rigor `deep` (review policy `deep`; tiers apex/frontier/apex; budget
`deep`, with tier escalation allowed) + strategy `plan-approved` (single
accountable lead, explicit plan, one human gate after the plan, before
implementation begins).

**"Use council, but cap both role tiers at economy."**
Strategy `council` explicit; rigor unstated → `default_rigor` (`standard`).
Council's two roles that actually do the work are the independent proposers
(implementer) and the judge (reviewer) — there is no lead role to delegate
through in a pure council — so "both role tiers" reads as
`tier:implementer:economy` + `tier:reviewer:economy`, leaving orchestrator at
standard's built-in tier. Resolved: rigor `standard` (review policy
`standard`; budget `standard`) with the implementer and reviewer tiers both
overridden to `economy` — *both* are off-profile against `standard`'s
built-in tiers and are disclosed in the PR body. Council still resolves:
`standard`'s budget comfortably covers its floor.

**"Orchestrate these in parallel with light rigor."**
Rigor `light` (as above) + strategy `orchestrate` (lead-and-workers,
explicit plan, delegation required). "In parallel" names `orchestrate`'s
own `coordination = parallel-when-independent` field directly — it does not
require a separate override, because that is what `orchestrate` already
does for independent slices of work. Compatible for the same reason
`council` was in the first example: `light`'s budget covers `orchestrate`'s
floor too. The same request under `trivial` rigor would be reported as an
incompatibility instead — `trivial`'s budget does not allow enough parallel
agents for a lead-and-workers topology to exist at all.

**"Take a deep one-shot at this, then stop."**
Rigor `deep` (as above) + strategy `oneshot` (single accountable lead,
inline planning, no delegation — not even a bounded helper subagent). "Then
stop" describes `oneshot`'s inherent shape — a single pass, not a loop —
rather than requesting a configurable `human_gates` entry; `oneshot`
already ships with none.

**"Use standard rigor with an economy implementer and a reviewer from a
different family."**
Rigor `standard` explicit; strategy unstated → `default_strategy` (`plan`).
`tier:implementer:economy` overrides the implementer only (off-profile
against standard's built-in implementer tier — disclosed); orchestrator and
reviewer stay at standard's built-in tier. "A reviewer from a different
family" states the plain preference, not a hard requirement (no
"must"/"require"), so it confirms the **default** family-diversity policy
above rather than elevating it — prefer a different-family reviewer at the
resolved `reviewer_tier`, same-family only with disclosure if none is
configured.

## Related documentation

- [AGENTS.md](../../AGENTS.md), "Dev Loop" — how these resolved values drive
  the challenge/review/shepherd stages, the stage ledger, and the readiness
  gate.
- [docs/guides/codex-review.md](codex-review.md) — the second-model review
  mechanics that consume the resolved `challenge`/`review`/`shepherd` caps.
- [docs/project-management.md](../project-management.md) — the label
  taxonomy `rigor:*`/`strategy:*`/`tier:*` are part of, and how labels
  compare to project fields.
