# Spec: GitHub issue strategy — taxonomy manifest, strategy axes, authoring standard, triage

- **Status:** Approved
- **Owner:** Evan Harmon
- **Date:** 2026-08-13
- **Related:** milestone [Issue strategy overhaul](https://github.com/evanharmon1/harmon-init/milestone/2)
  (#849–#858) · [ADR 0005](../docs/decisions/0005-unified-agent-vocabulary.md) · #754 · #809 · #620 ·
  [ponderousdev/foreman#139](https://github.com/ponderousdev/foreman/issues/139) ·
  [ponderousdev/foreman#169](https://github.com/ponderousdev/foreman/issues/169) ·
  harmon-devkit [#449](https://github.com/evanharmon1/harmon-devkit/issues/449),
  [#450](https://github.com/evanharmon1/harmon-devkit/issues/450),
  [#451](https://github.com/evanharmon1/harmon-devkit/issues/451),
  [#382](https://github.com/evanharmon1/harmon-devkit/issues/382)

## Problem / Why

The label taxonomy is well-designed and near-unused. At audit (2026-08-13): 230 open issues,
104 (45%) with no labels, 4 carrying `needs-triage`, 14 carrying any `domain:*`/`layer:*`, and
zero open issues carrying the `suggest:*`/`claim:*`/`foreman:*`/`rigor:*` machinery. Titles follow
four dialects; the issue forms prefix titles and apply no labels; native issue Types do not exist
on personal accounts. Classification depends on humans remembering at filing time, and every
filing surface skips it.

Three gaps cause this, and they are the ones this spec closes:

1. **No machine-readable taxonomy.** The vocabulary is split across a script heredoc, the
   agent-registry renderer, and a prose table whose Writer/Trust/Lifecycle columns automation
   cannot read.
2. **No writers.** Nothing applies classification automatically — not the forms, not the agents,
   not a scheduled groomer.
3. **No authoring standard.** track-work governs closing/linking, not titles, body shape, or
   at-create metadata — and there is no per-issue vocabulary for AI execution strategy (how to
   work an issue, what model class to route it to).

## Goal

Issues become cheap to classify and route, for humans and agents alike:

- One manifest (`label-registry.json`) is the source of truth for every label family — including
  who may write each family — rendered into provisioning, docs, and skill behavior.
- Three classification axes: `area:*` (codebase subsystem), `domain:*` (product capability),
  `layer:*` (stack slice); at most one of each per issue.
- Two primary execution-policy axes, config-backed in `.devflow.toml`: `rigor:*` (how much
  confidence, effort, depth, and budget — a review policy, three role tiers, and a budget
  envelope) and `strategy:*` (how the work is organized and performed — topology, planning,
  delegation, and human gates). `tier:*` becomes an advanced, role-scoped refinement of rigor's
  own per-role tiers rather than a peer axis with its own default; both `rigor:*` and
  `strategy:*` are consumable by foreman under its trust model. (#1047, superseding this spec's
  original `method:*`; see [ADR 0007](../docs/decisions/0007-rigor-and-strategy-axes.md).)
- One authoring standard (title rule, body skeleton, metadata checklist) enforced by a checker
  and mirrored by the issue forms.
- A manifest-governed triage skill that classifies the backlog and reports what it cannot decide.

## Non-goals

- **No auto-merge label, ever.** Merging stays a human decision (AGENTS.md hard rule; foreman
  permanent non-goal). A triage-writable label authorizing an unreviewed merge is the
  label-as-permission anti-pattern the taxonomy doc forbids. The attributable native mechanism —
  a human enabling GitHub auto-merge on a PR with required checks — already exists.
- **No new arming surface.** `foreman:*` remains the only arming namespace; upstream parses any
  unrecognized `foreman:*` value as a backend selector, so no metadata may ever live there.
- **No `type:*` work-type family.** That prefix is foreman's conventional-commit override. Work
  type is native issue Type on org repos and the informal labels
  (`bug`/`feature`/`documentation`/`question`/`task`/`research`) on personal repos —
  `feature` replacing GitHub's default `enhancement`, which is retired from the vocabulary
  (maintainer decision, 2026-08-14, PR #871).
- **No board/field mirrors for the new families** until a view needs one; labels only.
- **No unattended triage in v1.** Scheduling is a separate, explicit later decision.

## Requirements

- [ ] `label-registry.json` + schema + validator + `task test:label-registry`, template twins;
      per family: prefix/names, color, purpose, axis, `writers`
      (`human | trusted-human | agent | tool:<name>` — `trusted-human` marks values an
      actor-verifying consumer additionally authenticates, e.g. foreman arming inputs; the
      label itself still carries no permission, the class names which consumer-side check
      applies),
      lifecycle, exclusivity, values, `source: inline | agent-registry | tool-owned` — with
      **per-value overrides** of `writers`, `lifecycle`, and `color`, because mixed
      namespaces exist (`foreman:*`: arming selectors and `approved` are trusted-human
      inputs, `hold` is human, `dispatched`/`ready-for-review` are tool-owned outputs — and
      the four protocol labels ship four different colors today, which family-level color
      alone cannot reproduce).
      `setup-github-labels.sh` renders from it; the docs taxonomy table is generated between
      markers; descriptions ≤ 100 chars in both this schema and agent-registry's (#680).
      Every existing consumer of the inline rows migrates in the same change — in particular
      `scripts/status.sh` (and its template twin) reads its expected-label inventory from the
      manifest renderer, covered by the drift test, so `task status` cannot report an
      incompletely seeded repo as complete. (#851)
- [ ] `area:*` family — harmon-init values (template, devcontainer, ci, tasks, skills, foreman,
      codex, worktree, release, security, pm, docs); generic template starter (ci, docs, deps,
      build). Rule: area = solution space, domain = problem space, layer = stack slice. (#854)
- [ ] `tier:*` ladder `local → economy → standard → frontier → apex` plus `adaptive`; `apex` =
      mythos-class (fable, sol), `frontier` = opus-class. `.devflow.toml` gains
      `[tier.<value>]` tables mapping families to `agent-registry.json` model slugs
      (validated), `escalate_to` chains, and `endpoint = "local"` on the self-hosted tier.
      `tier:local` escalates to economy; privacy-pinning is a future separate concern label,
      not a tier semantic. (#855; re-scoped #1047 — there is no `default_tier`: each
      `[rigor.*]` level names `orchestrator_tier`/`implementer_tier`/`reviewer_tier`
      directly, and those three values are the default for every role absent an override.
      An unqualified `tier:<value>` label or override refines the **implementer** tier only;
      `tier:orchestrator:<value>` / `tier:implementer:<value>` / `tier:reviewer:<value>`
      refine one named role. See [ADR 0007](../docs/decisions/0007-rigor-and-strategy-axes.md)
      D2/D5.)
- [ ] Tier tables are **inert routing preferences, never dependencies**: nothing in a
      generated repo invokes any model because the config exists, and an acting consumer may
      select only among vendors/harnesses the operator has already configured and
      authenticated — the shipped defaults therefore create no account, trial, or paid-SaaS
      dependency (Hard Rule preserved), and escalation can never switch a repo to a vendor it
      does not already use. The `local` tier's machinery binding is explicit: its entries
      resolve to the registry's `-local` endpoint-variant harnesses (ADR 0005 D9), and
      validation fails a local entry whose family has no registered `-local` harness.
      `escalate_to` chains validate as referential, acyclic, and monotonic toward `apex`;
      *when* escalation fires (failure, refusal, operator policy — never cost alone) is
      defined in ADR 0006. Candidate selection is deterministic, also in ADR 0006: the
      resolved tier names the stratum; a `suggest:<family>[:<model>]` narrows within it only
      when that family is configured and eligible (otherwise it is ignored with a note) —
      and unattended consumption of a suggestion is subject to the same provenance
      invariant as the strategy axes below;
      absent a suggestion, the consumer's own configured backend or harness picks; a tier
      with no eligible configured candidate escalates along the chain, and an exhausted
      chain **stops with a report** — never a silent vendor switch or downgrade. (#855)
- [ ] Built-in fallbacks are defined: absent `.devflow.toml` entirely, resolution uses the
      built-in review policy equivalent to `standard` (3 / 3 / 4, `min_rounds` 1), strategy
      `plan`, and tiers **inert** — the labels still classify, and nothing resolves a role to a
      concrete model. `adaptive` is never a terminal answer for a role tier: it is rejected
      outright as a `[rigor.*]` role-tier value or an override target — a role always resolves
      to a concrete ladder rung or not at all (inert), never to `adaptive` itself. (#855;
      restated #1047 without `default_tier`/`[method]`, which no longer exist — see
      [ADR 0007](../docs/decisions/0007-rigor-and-strategy-axes.md) D5/D12.)
- [ ] `strategy:*` values `oneshot | plan | plan-approved | orchestrate | council | human-led`
      (replacing `method:*`, retired via the existing retired-family pattern);
      `default_strategy` in `.devflow.toml`. Each value carries machine-readable `topology`,
      `planning`, `delegation`, optional `coordination`/`selection`/`synthesis`/`min_agents`,
      and `human_gates` fields (defined without relying on the value's name — see
      [ADR 0007](../docs/decisions/0007-rigor-and-strategy-axes.md) and
      `docs/guides/devflow.md`). Unlike the `method:*` rank it replaces, **strategy conflicts
      are ambiguous, not ranked**: two `strategy:*` labels on one issue require resolution
      (an interactive session asks; unattended automation falls back to `default_strategy`
      with a warning) rather than resolving to a fixed cross-topology order — topologies are
      not orderable against each other the way rigor levels are. `human_gates` is drawn from a
      fixed ten-value set (`after-discovery`, `after-plan`, `before-delegation`,
      `before-selection`, `before-synthesis`, `before-scope-expansion`,
      `before-budget-escalation`, `before-publication`, `before-ready-for-review`,
      `each-phase`); constitutional approvals (merge, release, destructive actions,
      credential-store writes, security-relevant settings) are never configurable through it,
      and a strategy naming one is a validation error. A strategy whose `min_agents` exceeds
      the resolved rigor's budget (`max_agent_runs` or `max_parallel_agents`) is a reported
      incompatibility, never a silent substitution. (#1047, superseding this spec's original
      `method:*` requirement from #855.)
- [ ] Resolution and trust (ADR 0006, re-scoped by ADR 0007): explicit instruction > label >
      config default > built-in — where an **explicit instruction** is one arriving on the
      operator's attributable channel (the interactive session's human input, or the
      automation's own configuration) and never repository content: issue bodies, comments,
      and PR text are untrusted input and can never outrank labels or config. Merge-base copy
      applies when the change edits `.devflow.toml` — every parameter, not only defaults.
      **Rigor conflicts resolve strongest-wins by `rigor_order`** (a label only ever buys more
      depth and budget); **role-tier conflicts resolve strongest-wins on the tier ladder**, and
      a concrete tier always beats `adaptive`; **strategy conflicts are ambiguous** — there is
      no rank, because topologies are not orderable against each other the way rigor levels
      are, so an interactive session must ask and unattended automation falls back to
      `default_strategy` with a warning. Off-default resolutions — above or below, for rigor,
      strategy, or any individual role tier — are disclosed in the PR body (#809 doctrine
      extended). Consumer trust is stated as **invariants**; the concrete timeline-validation
      algorithm is deliberately not specified here — it is ADR 0006 / foreman#139 design work
      under #855, and the adversarial scenarios raised in this spec's review are carried there
      as required test cases:
      1. **Unattended automation** acts on a strategy or suggestion label only after
         verifying its provenance end-to-end from its own trusted-actor configuration,
         re-read immediately before acting — and no sequence of untrusted mutations,
         applies **or removals**, on any label of the axis, may move the resolved outcome
         away from what trusted actors' surviving actions alone would produce. Anything
         short of that resolves to the config default with a warning.
      2. An **interactive session** treats these labels as advisory (the #809 rigor
         posture), and requires operator confirmation for **any off-default resolution** —
         above or below, since one direction skips oversight and the other spends money —
         arising from a label that was not applied by an actor the operator has
         **authorized** (the operator themselves, or a login their configuration trusts);
         attribution to *some* identifiable actor is not authorization.
      3. Advisory families fail open to the config default; arming stays fail-closed.
      Rigor's values are called **levels** in all prose from here on; "tier" belongs to the
      model axis. (#855)
- [ ] ADR 0005 D6 amendment: suggestions become human- **or agent-**authored; `suggest:*` stays
      family[:model] (vendor preference), `tier:*` is the human-decided policy layer;
      `suggest:tier:<value>` is reserved, not built. `claim:*` stays on the family axis; the
      claim record gains `harness:`/`model:`/`session:` fields (harmon-devkit#450). (#855)
- [ ] Authoring standard (canonical in harmon-devkit#449): titles are imperative
      problem/outcome statements, ≤ ~70 chars, no prefixes; body skeleton `## Problem` →
      optional `## Current violation (observed YYYY-MM-DD)` → `## Acceptance criteria` with
      `[CI]`/`[HUMAN]` tags (foreman's dispatch contract, case-insensitive) → `## Verify` when
      perishable facts are cited → optional `## Out of scope` / `## Provenance`; metadata
      checklist enforced by `check-issue-metadata.sh`; vocabulary read from the manifest with
      `gh label list` fallback.
- [ ] Issue forms drop `title:` prefixes and match the skeleton's field names. Work-type
      labels are applied by forms **only where native issue Type is unavailable** (personal
      accounts); org twins set native `type:` and no work-type label, so each owner type has
      exactly one writable source for the classification. Every form applies `needs-triage`.
      Forms reference only labels the manifest provisions; provisioning order is the existing
      CHECKLIST guarantee (`task setup:github-labels`), and an unprovisioned repo degrades to
      unlabeled creation, which triage then catches. Forms whose type implies implementable
      work (Feature, Task) ship an Acceptance-criteria field that is **empty — no prefilled
      `- [ ]` placeholder**: foreman's parser accepts any nonempty section (untagged bullets
      become `[CI]` with a warning), so a placeholder would make placeholder issues
      dispatchable; an unfilled optional field renders as the heading plus `_No response_`
      — no checkbox items — so foreman's no-items check refuses it, and a form-filed issue
      with no acceptance-criteria **items** is genuinely non-dispatchable **by design**
      — quick capture stays legal, and the authoring standard supplies criteria at triage
      before any dispatch. (#852)
- [ ] Triage skill v1 (canonical in harmon-devkit#455 — skills live in harmon-devkit;
      vendored and supervised here via #864): write-allowlist = the manifest's `writers`
      field; v1 writes only
      area/layer/domain, an unambiguous missing work-type **on personal-account repos** (org
      classification is native Type, which v1 cannot write — a missing org Type is reported,
      never labeled), and `needs-triage` — added freely, removed **only when classification
      is complete** (work type present in the owner-appropriate form, and each of
      area/layer/domain either applied or genuinely inapplicable); a partially classified
      issue keeps the label and appears in the report; never
      `foreman:*`/`rigor:*`/`tier:*`/`strategy:*`/`claim:*`/`suggest:*`, milestones, closes,
      assignees, or body/title edits; everything else lands in one rolling report issue.
- [ ] Foreman alignment: pin bump to 2.5.0 (#849), AdmiralFraggle in `trusted_actors` (#850),
      claim contract at dispatch proposed upstream (foreman#169, engaging foreman#82), tier
      vocabulary contributed to foreman#139. Foreman consumption of `tier:*`/`strategy:*` follows
      #139's rails; nothing here arms anything.
- [ ] Docs reconciliation (#857): manifest named as source; scope-batch milestones legitimized
      for rolling-release repos; #683/#702/#703 absorbed.

## Acceptance criteria (Given / When / Then)

### Scenario: the manifest is the single source

- **Given** `label-registry.json` exists with the full taxonomy
- **When** `task setup:github-labels` and the docs generation run
- **Then** the provisioned label set and the docs table both derive from the manifest, and a
  hand-edit to either is caught by a drift test in `task verify`

### Scenario: tier conflict can only buy more

- **Given** an issue carrying both `tier:economy` and `tier:standard`
- **When** an agent (or foreman, later) resolves the (unqualified, implementer-scoped) tier
- **Then** the resolution is `standard`, and any role tier that ends up below the resolved
  rigor's own profile for that role is disclosed in the PR body

### Scenario: rigor conflict resolves to the strongest level

- **Given** an issue carrying both `rigor:light` and `rigor:deep`
- **When** an agent (or foreman, later) resolves the rigor
- **Then** the resolution is `deep` — the level that sorts strongest in `.devflow.toml`'s
  `rigor_order` — carrying `deep`'s whole profile (review policy, all three role tiers,
  budget) rather than a mix of fields from both labels

### Scenario: untrusted strategy labels are inert to automation

- **Given** `tier:apex` applied by a login not in the automation's trusted-actor configuration
- **When** unattended automation resolves the tier from the label timeline immediately before
  acting
- **Then** the label is ignored with a warning and the config default applies — and no
  sequence of untrusted applies **or removals** anywhere on the axis can move the outcome
  away from what trusted actors' surviving actions alone would produce (the provenance
  invariant; the concrete algorithm lives with ADR 0006 / foreman#139)

### Scenario: two strategy labels are ambiguous, not ranked

- **Given** an issue carrying both `strategy:orchestrate` and `strategy:council`
- **When** an interactive session resolves the strategy
- **Then** resolution stops with an ambiguous-strategy error asking which one applies, rather
  than picking one by a fixed rank — and when the same conflict is resolved by unattended
  automation instead, it falls back to `default_strategy` with a warning rather than guessing

### Scenario: a strategy that exceeds the rigor's budget is reported, not substituted

- **Given** an issue carrying `strategy:council` (`min_agents = 2`) and `rigor:trivial`
  (`budget.trivial`: `max_agent_runs = 1`, `max_parallel_agents = 1`)
- **When** any consumer resolves the pairing
- **Then** resolution reports the incompatibility and stops — it never silently substitutes a
  different topology and never silently widens the budget to fit

### Scenario: a zero-cap stage is skipped without weakening a deterministic gate

- **Given** `rigor:trivial` (review policy `none`: challenge/review/shepherd all 0)
- **When** an agent works the issue to a PR
- **Then** no AI challenge, review, or shepherd round runs, while every deterministic gate
  (tests, CI, security scanners, branch protection, the human merge/release decision) still
  runs exactly as it would under any other rigor, and any finding that a required check does
  surface is still adjudicated and recorded like any other

### Scenario: a same-family reviewer fallback is disclosed, not silent

- **Given** `rigor:standard` (`reviewer_tier = "frontier"`) and an implementer whose configured
  harness is in the only family with a `frontier`-tier reviewer available
- **When** resolution selects the primary reviewer
- **Then** it falls back to that same-family reviewer at the required tier rather than failing
  outright, and marks the choice as a disclosed same-family fallback rather than presenting it
  as the preferred different-family outcome

### Scenario: triage stays inside its allowlist

- **Given** the triage skill running over the live backlog
- **When** it classifies an issue it is confident about
- **Then** it writes only labels whose manifest `writers` include `agent`, and everything else —
  including every tier/strategy/suggest proposal — appears only in the rolling report

### Scenario: a form-filed bug arrives classified

- **Given** a personal-account repo whose labels are provisioned (`task setup:github-labels`)
- **When** a user files through the Bug form
- **Then** its title carries no `[Bug]:` prefix and it already carries `bug` + `needs-triage`
  — while on an organization repo the same form sets native issue Type `Bug` plus
  `needs-triage`, and no work-type label

### Scenario: a blank form cannot dispatch

- **Given** a Feature or Task form submitted with its Acceptance-criteria field left empty
- **When** foreman evaluates the unit spec contract
- **Then** the body carries no criteria list items (GitHub renders `_No response_` under the
  heading) and foreman refuses the unit on its no-items check

### Scenario: a standard-authored issue is foreman-dispatchable

- **Given** an issue written to the authoring skeleton with tagged acceptance criteria
- **When** foreman evaluates the unit spec contract
- **Then** the `## Acceptance criteria` section parses with its `[CI]`/`[HUMAN]` items and the
  unit is not refused for spec shape

## Open questions

- Triage Phase B: whether/where to schedule (Actions cron vs devcontainer cron) — decided after
  v1 precision is observed on the live backlog.
- Whether a `premium` stratum between `standard` and `frontier` ever becomes necessary, or
  `suggest:<family>:<model>` covers within-family precision indefinitely.
- `suggest:tier:<value>` stays reserved until a board view needs labeled tier proposals.

## Notes

- Rollout is the milestone's dependency graph: #849/#850/#851/#852 and the devkit children are
  the ready set; #854/#855/#864 unblock on #851; #857 closes the loop; #858 lands the vendored
  skills after the devkit release.
- The `tier:*`/`method:*`/`area:*`/`task`/`research` labels were hand-seeded on 2026-08-13 across
  harmon-init, harmon-devkit, and ponderousdev/foreman (colors: area `0E8A16`, tier `7057FF`,
  method `BF3989`, task `6E7781`, research `0E7C86`); #851 formalizes them — the manifest must
  adopt these exact names/colors so provisioning reconciles instead of fighting. `method:*` was
  retired in favor of `strategy:*` under #1047 (ADR 0007); its color `BF3989` carries over to
  `strategy` so provisioning reconciles the same way.
- Design rails inherited from upstream foreman (v2.5.0 source, verified): unrecognized
  `foreman:*` labels arm as backend selectors; `type:<commit-type>` is parsed (two = error);
  dispatchability requires an `## Acceptance Criteria` section (case-insensitive) with ≥ 1
  bullet; adapters hold read-only tokens, so any issue-side write is foreman-core's.
- Labels carry no permissions (project-management.md): the new families trigger nothing by
  existence. The verification obligation is consumer-specific — unattended automation
  verifies provenance under the Requirements invariants (no sequence of untrusted
  mutations may influence the outcome), while interactive sessions treat the labels as
  advisory with off-default operator confirmation plus disclosure — the #809 posture,
  extended.
