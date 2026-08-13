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
- Two advisory strategy axes with config-backed semantics: `method:*` (execution topology) and
  `tier:*` (model routing), resolved like rigor and consumable by foreman under its trust model.
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
  (`bug`/`enhancement`/`documentation`/`question`/`task`/`research`) on personal repos.
- **No board/field mirrors for the new families** until a view needs one; labels only.
- **No unattended triage in v1.** Scheduling is a separate, explicit later decision.

## Requirements

- [ ] `label-registry.json` + schema + validator + `task test:label-registry`, template twins;
      per family: prefix/names, color, purpose, axis, `writers` (`human | agent | tool:<name>`),
      lifecycle, exclusivity, values, `source: inline | agent-registry | tool-owned`.
      `setup-github-labels.sh` renders from it; the docs taxonomy table is generated between
      markers; descriptions ≤ 100 chars in both this schema and agent-registry's (#680). (#851)
- [ ] `area:*` family — harmon-init values (template, devcontainer, ci, tasks, skills, foreman,
      codex, worktree, release, security, pm, docs); generic template starter (ci, docs, deps,
      build). Rule: area = solution space, domain = problem space, layer = stack slice. (#854)
- [ ] `tier:*` ladder `local → economy → standard → frontier → apex` plus `adaptive`; `apex` =
      mythos-class (fable, sol), `frontier` = opus-class. `.devflow.toml` gains `default_tier`
      and `[tier.<value>]` tables mapping families to `agent-registry.json` model slugs
      (validated), `escalate_to` chains, and `endpoint = "local"` on the self-hosted tier
      (endpoint is a harness property per ADR 0005 D9). `tier:local` escalates to economy;
      privacy-pinning is a future separate concern label, not a tier semantic. (#855)
- [ ] `method:*` values `oneshot | plan | plan-approved | orchestrate | council | human-led`;
      `default_method` in `.devflow.toml`. (#855)
- [ ] Resolution and trust (ADR 0006): explicit instruction > trusted label > config default >
      built-in; merge-base copy when the change edits `.devflow.toml`; conflicts resolve
      strongest-wins (a label only ever buys more capability or oversight); a concrete tier
      beats `adaptive`; below-default resolutions are disclosed in the PR body (#809 doctrine
      extended). Acting consumers read the label timeline and honor values only from
      `trusted_actors` logins — advisory families fail open to the default, arming stays
      fail-closed. Rigor's values are called **levels** in all prose from here on; "tier"
      belongs to the model axis. (#855)
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
- [ ] Issue forms drop `title:` prefixes, apply `labels:` (work-type + `needs-triage`), and
      match the skeleton's field names; org twins keep native `type:`. (#852)
- [ ] Triage skill v1 (#856): write-allowlist = the manifest's `writers` field; v1 writes only
      area/layer/domain, unambiguous missing work-type, and `needs-triage` add/remove; never
      `foreman:*`/`rigor:*`/`tier:*`/`method:*`/`claim:*`/`suggest:*`, milestones, closes,
      assignees, or body/title edits; everything else lands in one rolling report issue.
- [ ] Foreman alignment: pin bump to 2.5.0 (#849), AdmiralFraggle in `trusted_actors` (#850),
      claim contract at dispatch proposed upstream (foreman#169, engaging foreman#82), tier
      vocabulary contributed to foreman#139. Foreman consumption of `tier:*`/`method:*` follows
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
- **When** an agent (or foreman, later) resolves the tier
- **Then** the resolution is `standard`, and any resolution below `default_tier` is disclosed in
  the PR body

### Scenario: untrusted strategy labels are inert

- **Given** `tier:apex` applied by a login not in `trusted_actors`
- **When** an acting consumer resolves the tier from the label timeline
- **Then** the label is ignored with a warning and the config default applies

### Scenario: triage stays inside its allowlist

- **Given** the triage skill running over the live backlog
- **When** it classifies an issue it is confident about
- **Then** it writes only labels whose manifest `writers` include `agent`, and everything else —
  including every tier/method/suggest proposal — appears only in the rolling report

### Scenario: a form-filed bug arrives classified

- **Given** a user files through the Bug form
- **When** the issue is created
- **Then** its title carries no `[Bug]:` prefix and it already carries `bug` + `needs-triage`

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
  the ready set; #854/#855/#856 unblock on #851; #857 closes the loop; #858 lands the vendored
  skills after the devkit release.
- The `tier:*`/`method:*`/`area:*`/`task`/`research` labels were hand-seeded on 2026-08-13 across
  harmon-init, harmon-devkit, and ponderousdev/foreman (colors: area `0E8A16`, tier `7057FF`,
  method `BF3989`, task `6E7781`, research `0E7C86`); #851 formalizes them — the manifest must
  adopt these exact names/colors so provisioning reconciles instead of fighting.
- Design rails inherited from upstream foreman (v2.5.0 source, verified): unrecognized
  `foreman:*` labels arm as backend selectors; `type:<commit-type>` is parsed (two = error);
  dispatchability requires an `## Acceptance Criteria` section (case-insensitive) with ≥ 1
  bullet; adapters hold read-only tokens, so any issue-side write is foreman-core's.
- Labels carry no permissions (project-management.md): every consumer that acts on one verifies
  who applied it; these new families are advisory and trigger nothing by existence.
