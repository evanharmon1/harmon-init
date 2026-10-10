# Project Management

How work is tracked for Harmon Init in **GitHub Projects**.

## One default project per owner

The standard strategy is a single default GitHub **Project (V2)** per owner — one
board for the organization, or (for personal-account repos) one for the user
account — titled after the owner's GitHub login: `<owner> Project` (here:
**evanharmon1 Project**; e.g. `acme Project` for an organization, `octocat Project` for a personal account).
Every repo the owner controls feeds that one board; an issue can belong to
multiple projects, but this default board is its home. Reach for a second,
focused project only when a body of work needs its own.

## Token scopes

Everything on this page that touches the board — `task setup:github-project`,
and the `Status` writes the [claim lifecycle](#claiming--making-an-agents-work-visible-while-it-happens)
makes — goes through the Projects V2 API, and `gh auth login` does **not** grant
access to it by default. Nothing else notices: the same token still reads
issues, opens PRs, and drives CI perfectly well, so the gap shows up only as
board writes that do nothing.

| Scope | Grants | Enough for |
|---|---|---|
| *(neither)* | — | nothing here — every board read and write fails |
| `read:project` | read Projects | reading a card's current `Status`; **no writes** |
| `project` | read **and write** Projects | everything on this page |

### Getting them: `task setup:gh-scopes`

```sh
task setup:gh-scopes
```

**Operator / dev profile only.** It refreshes *your* interactive `gh` login —
so it refuses when a `GH_TOKEN`/`GITHUB_TOKEN` env credential is set (an env
token overrides the stored one, so a refresh would repair something this shell
never uses — reissue that token at its source instead) and refuses without a
TTY, because the flow is an interactive browser device-code exchange and no
agent or CI job should re-mint a human credential. It prints the current
scopes, requests the missing ones, and then **verifies they actually landed** —
`gh auth refresh` can exit 0 having granted less than was asked for, and a
remedy that reports success without checking puts the session straight back
into the failure it was run to end.

A bot container is the one place this task is the wrong answer: there the
credential is `GH_TOKEN`, reissued at its source. See
[bot-account.md](guides/bot-account.md).

The raw equivalent, derived from the same list rather than copied out of it —
a hardcoded copy silently goes stale the moment the list changes (an org repo,
for instance, also needs `admin:org`):

```sh
gh auth refresh -s "$(bash -c '. scripts/gh-scopes.sh && gh_scopes_request_list')"
```

To just see what this repo asks for:

```sh
bash -c '. scripts/gh-scopes.sh && gh_scopes_request_list'
```

(Through `bash` on purpose: the helper resolves its own location via
`BASH_SOURCE`, and the devcontainer's default shell is zsh, where sourcing it
directly would resolve the repo root to the wrong directory and silently shrink
the list.)

Check what a token actually carries:

```sh
gh auth status | grep 'Token scopes'
```

### Where the required list lives

One file: [`scripts/gh-scopes.sh`](../scripts/gh-scopes.sh). `status.sh`'s
session-start check, `setup-gh-scopes.sh`, and the devcontainer's
`gh_auth_help` banner all read it, so the remedy a warning prints and the
scopes the task requests cannot drift apart. A repo that needs more adds to the
list **without editing the file** by exporting `GH_EXTRA_SCOPES` (e.g. from
`.envrc`):

```sh
export GH_EXTRA_SCOPES="delete_repo"
```

That is **additive**: everything this repo's profile already requires keeps
applying, including anything a later template update introduces.
`GH_REQUIRED_SCOPES` also exists and **replaces** the computed list outright —
an escape hatch, and one that freezes today's defaults, so a requirement added
upstream silently stops being checked. Prefer `GH_EXTRA_SCOPES`.

Whitespace separates requirements; `|` joins alternatives that each satisfy one
requirement. `gh auth refresh` is asked for *every* alternative, which is why
the raw command above lists both Projects scopes.

The Projects requirement is itself conditional: it applies only where
`scripts/setup-github-project.sh` exists — the same marker the board-write
check uses, and the same reason. `project_management` defaults to `none`, and a
repo generated that way has no board, so demanding Projects access there would
warn every session about a grant the repo never uses.

### Where it surfaces

`task status:creds` — which the session-start hook runs every session — warns
when the token is missing anything on that list, names the missing scopes, and
prints the remedy. It is silent when the list is satisfied, read-only,
non-fatal, and bounded (one 3s probe; `STATUS_NO_NETWORK=1` skips it). A probe
that cannot answer reports nothing rather than accusing a working credential.

`task status:gh` additionally reports **Project board writes**, which is a
narrower question: `read:project` satisfies the session-start check but is
read-only, so it fails that one. `task setup:github-project` refuses to run
without `project` rather than failing partway through its writes.

Two adjacent scopes, for completeness: an organization's **issue types** need
`admin:org` (reported by `task status:setup`), and the vendored claim skills
hint at `gh auth refresh -s read:project,project` — a subset of what
`setup:gh-scopes` requests, so a credential minted by the task satisfies it.

### Scopes are only half the story

The table above is about **classic OAuth scopes**, which is what `gh auth login`
issues and `gh auth refresh` edits. A **fine-grained PAT** or a GitHub App
installation token has none of them: its Projects access is a *permission*
granted where the token was issued. `gh auth status` reports no scope list for
one, so `task status:gh` can only report the check as **unknown**, and
`gh auth refresh` cannot help — a token supplied through the environment as
`GH_TOKEN` cannot be refreshed at all. Grant it **Projects: Read and write** at
the source (organization permissions, for an org-owned board) instead.

The bot credential this repo documents ([bot-account.md](guides/bot-account.md))
is exactly such a token. This is a **personal** account, so it is granted no
Projects permission at all — that row of the PAT table is organization-scoped,
and a user-owned board has no equivalent setting to hand a second account. So an
agent running as the bot **cannot move a card**, and there is no permission to
raise: the board is moved by you, while the claim stays visible through the
claim label and the assignee — see
[Claiming](#claiming--making-an-agents-work-visible-while-it-happens), which is
exactly why a claim writes all three signals instead of relying on the board
alone. To have claims move cards here, run the agent under your own `gh` login
(which the scope table above applies to) rather than the bot's.

The status check does not treat a read-only credential as broken; it reports what
the credential can do.

## Status pipeline

`Status` is a single-select field with exactly one meaning: **where in the flow
toward delivery is this.** The columns, grouped:

**Backlog** — triage; not yet committed

- Inbox — newly landed, unsorted
- Icebox — real, but not now
- Next — will pull in soon

**Unstarted** — committed to a cycle, not yet in motion

- Todo
- Shaping — problem/approach still being defined
- Ready — shaped, ready to pick up
- Agent Queue — queued for an AI agent to implement

**Started** — in motion, partial progress

- In Progress
- Verifying — CI/checks running
- In Review — under human review
- Ready to Merge — approved, awaiting merge

**Completed**

- Done — merged/shipped; the single terminal status
- Deployed
- Accepted — smoke/QA/manual check passed, communicated, released

Archiving isn't a status — it's a separate native axis. GitHub's built-in
**auto-archive** removes finished items from the board (into the retrievable
Archived-items view), so aged `Done` items leave the board automatically instead
of sitting in an "Archived" column.

**Agent Queue is the hand-off lane to AI coding agents.** An item lands there once
it's shaped and ready for an *agent* rather than a human to implement — its
derived Tier (`tier:*`) says which tier of agent should take it. The hand-off
itself is manual: trigger the agent — an `@claude` mention naming `implement` (see
[The Claude Actions workflows](#the-claude-actions-workflows)), or point Claude
Code at the item. The lane is only a hand-off column, not the queue — the
**Agent queue** is defined in [Views](#views) — and either way the item moves to
**In Progress** once work starts.

> **Foreman is that automation** for issue-driven delivery: arm the issue with
> a `foreman:*` label — label arming is the only supported mode: while
> `issues.field_added` / `issues.field_removed` events exist, Foreman reads the
> label timeline, where field events carry an actor only under a preview
> GraphQL API and the timeline algorithm is specified for labels
> (ponderousdev/foreman#139) — and `task foreman:dispatch` /
> `foreman:watch` pulls ready items and delivers them **draft-first**: it opens
> a **draft** PR labelled `foreman:dispatched`, runs its own verify gate,
> shepherds CI and reviews on the draft, and promotes it to
> `foreman:ready-for-review` only through its readiness gate. Merging is always
> a human decision. The Project stays the human dashboard — foreman neither
> reads nor writes it (issue state, labels, and PRs are its interface). See
> https://github.com/ponderousdev/foreman.

## Status is not issue state

GitHub has **two independent state machines**, and conflating them is the most
common way to make a board lie:

- **Issue state** — `open` / `closed`, native to the issue.
- **Status** — the custom pipeline field above, layered on top.

`Status` answers *"where in the delivery flow is this."* It is **not** where you
record *why something left the flow without shipping* — GitHub has a dedicated
axis for that, the **close reason**.

### Canceled and Duplicate are close reasons, not statuses

They aren't pipeline positions; they're terminal closure reasons, and GitHub
already has an axis for those that's separate from `Status` by design. When you
close an issue you pick **Completed**, **Not planned**, or **Duplicate**:

- **Cancel / won't-fix / stale** → close as **Not planned** — explicitly the
  bucket for exactly this.
- **Duplicate** → close as **Duplicate** (shipped December 2024). You select the
  duplicated issue, which produces a timeline event and a note at the top making
  the closure reason clear.

Neither needs a `Status` value, and **Done** stays the single terminal status
meaning "shipped." Why not add `Canceled`/`Duplicate` columns anyway, given
Linear has a Canceled group? Because in Linear the status *is* the state, so
"Canceled" closes the work atomically with that meaning. GitHub split them:
`Status` is a custom field layered on an issue that keeps its own independent
open/closed state.

### Automation gotcha

The built-in **"issue closed → Done"** rule doesn't look at *why* the issue
closed, so closing something as Not planned or Duplicate would paint it **Done**
on the board — wrong. Gate it:

- Drive Done off **"PR merged → Done"** for the success path.
- Leave the built-in **"item closed → Done"** rule **off**. Only a custom
  Action can read `state_reason`, and none ships here — so the built-in is the
  whole of what that rule would do, and it cannot tell a shipped issue from an
  abandoned one.

Items closed as not-planned/duplicate just stay closed and fall off the board;
their `Status` value goes vestigial, which is fine — nothing open-filtered shows
them.

## Blocked is not a status

A `Blocked` column buys you visibility you already get for free, and it fights
automation: statuses are artifact-driven (PR opened → Verifying) while "blocked"
is a manual human overlay — an item that's "Blocked" but has an open PR is a
contradiction the automation can't resolve. Blocked is **orthogonal** to pipeline
position; keep it off that axis. There are two kinds, and they want different
tools:

- **Blocked by another issue** (the common case) — use the native **"Mark as
  blocked by"** relationship (issue dependencies, GA 2025-08-21). It records
  *what's* blocking (the actual issue, not a bare flag), shows the **Blocked**
  icon on the board and Issues page automatically, is queryable with
  `is:blocked`, and is fully programmatic (`gh issue view` shows Blocked by /
  Blocking; `--json blockedBy,blocking`; REST endpoints add/list/remove).
  When the blocker closes, the relationship reflects it. Up to 50 issues per
  relationship type.
- **Blocked by a non-issue** — waiting on a Twilio 10DLC approval, an upstream
  library fix, a pricing decision, info from a customer. The native feature can't
  express this (an issue only becomes "blocked" by depending on another issue),
  so this is the **`blocked` label's** job: it means "stuck on a non-issue
  thing," with the actual reason in a comment.

One upgrade for that second case: model a *significant or shared* external
blocker as its own **tracking issue** ("Twilio 10DLC brand approval") and mark
the real work blocked-by it — that pulls the external dependency into the native
mechanism (board icon, `is:blocked`, auto-resolve). Worth it when several items
wait on the same thing; reserve the bare label for one-off, transient blockers.

## Automations

Projects are **org-level** objects, but automations trigger from **events**, and
issue/PR events are repo-local. That splits automation three ways:

1. **Triggered by repo activity (issue/PR events)** — the workflow *must* live in
   the repo where the activity happens; a workflow in one repo never sees
   another's PR events. In a polyrepo org the same automation runs in every repo
   whose issues/PRs feed the project.
2. **Triggered by a schedule or `workflow_dispatch`** — no per-repo trigger to
   distribute, so pick one hub/ops repo and run it there.
3. **Not an Action at all** — the project's **built-in workflows**.

Start with #3: **push everything you can onto the built-in workflows.** They're
configured on the project itself, fire on project-item events, and work
org-project-wide across every repo with zero Actions and zero per-repo setup —
Backlog on add, In Review on review-requested, Done on merge, Done on close,
auto-close, auto-archive. Drop to Actions only for the gaps built-ins don't
cover.

What is automated, and by which of the three:

| Event | Sets `Status` to | Mechanism |
|---|---|---|
| Item added to the project | **Inbox** | built-in workflow |
| PR opened / pushed to / reopened | **Verifying** | Actions (`project-automation.yml`) |
| Build run completes without failing | **In Review** | Actions (`project-automation.yml`) — any conclusion outside `failure`/`cancelled`/`timed_out`/`action_required` counts, so `skipped`, `neutral` and `startup_failure` advance the card too |
| Build run concludes `failure`, `cancelled`, `timed_out` or `action_required` | **Verifying** (stays) | Actions (`project-automation.yml`) |
| Review submitted as approved | **Ready to Merge** | Actions (`project-automation.yml`) — only when the PR's `reviewDecision` is `APPROVED`; head repo and reviewer association are pre-filters |
| PR merged | **Done** | Actions (`project-automation.yml`) + built-in |
| Issue closed, for any reason | *(nothing)* | not automated — see below |
| PR closed unmerged | *(nothing)* | deliberately not automated |
| 90 days in Done | **auto-archived** off the board | built-in auto-archive (not a `Status`) |

`In Progress` is deliberately **not** automated: it means a human or an agent
picked the work up, which happens before any artifact exists to trigger on. It
is written by the [claim lifecycle](#claiming--making-an-agents-work-visible-while-it-happens).

**Closing an issue moves nothing, on purpose.** Nothing shipped here listens for
`issues: closed`, and GitHub's built-in "item closed → Done" rule cannot read
the close reason — so leave that built-in **off**. Turned on, it paints every
issue closed as *Not planned* or *Duplicate* **Done**, which is exactly the
misfiling the [close-reason axis](#canceled-and-duplicate-are-close-reasons-not-statuses)
exists to prevent, and every one of them needs correcting by hand. Left off,
`Done` keeps meaning shipped: it arrives from the merge path above, and the
occasional issue that completes without a merged PR is moved by hand. An issue
closed as not-planned simply keeps whatever `Status` it had — vestigial, and
invisible to every open-filtered view.

The Actions half is `.github/workflows/project-automation.yml`, which is
generated **for organization repos only** — a personal-account board has no
org project for the CI App to write, so there the built-ins plus the claim
lifecycle are the whole story. It resolves the issue from the PR's
`claude/issue-N` branch name or a `Closes` / `Fixes` / `Resolves` reference in
the PR body.

**Only this repository's own branches move the board.** The branch name is the
routing key and its author chooses it, so a fork pushing `claude/issue-N` would
otherwise steer issue N's card. Trust comes from the head *repository*
instead: a `pull_request`, `workflow_run` or `pull_request_review` event whose
head repo is not this repository is not acted on. On the review path that test — plus a reviewer
`author_association` of `OWNER`, `MEMBER` or `COLLABORATOR` — is only a
pre-filter, keeping fork events and drive-by approvals from consuming a runner
and minting the App token. It is not the authorization: association is not a
permission, and `MEMBER` / `COLLABORATOR` include read-only and triage access.

**Ready to Merge is written only when the PR's `reviewDecision` is `APPROVED`.**
The event says somebody approved; `reviewDecision` is GitHub's own computation
of whether the PR *is* approved — required reviewers honoured, dismissals and
stale reviews accounted for — which is exactly what the status means. Any other
value logs and writes nothing. That includes an **empty** decision, which is
what GitHub returns when no required-review rule exists at all, even after a
genuine approval: this repository's ruleset requires code-owner review, so an
empty value means the rule is missing rather than the PR being approved. The
board write is advisory state and merging stays ruleset-protected either way;
this keeps the card honest, it is not the merge security.

The status write itself is `continue-on-error`, so a board that cannot be
written never fails a build. That tolerance starts *after* the App token is
minted, though — missing `CI_APP_CLIENT_ID` / `CI_APP_PRIVATE_KEY`, or an App
without **Projects: Read and write**, fails the token step, and
`project-automation-verify` fails with it.

### Classification reconciler

After filing, the derived Tier (`tier:<value>`) and `needs-triage` have two
automated writers and no others; what they derive from is under
[Classification](#classification) below. The skills (triage, track-work, breakdown) are meant to set both in the
same write that sets Risk or Complexity, but the pinned skills do not yet
(harmon-devkit#1250, #1251 and #1252, plus a skills-pin bump), so until then
the reconciler is what sets them. `classification-reconcile.yml` and
`classification-event.yml` repair everything else: a scheduled walk of open
issues (monthly on an organization repository, daily on a personal-account
one) and a per-issue job when a human opens an issue or changes a label or the
Type in the GitHub UI. An edit to an organization issue field starts no event
run, so after classifying with fields, run `classification-reconcile.yml` by
hand (`workflow_dispatch`), or the Agent queue view lags until the schedule.
The workflows write nothing but those two labels. They never write over
`tier:pinned` and never resolve a pin carrying two tier values; they report
that case for a human. The minutes model, the event filter and the opt-in
standalone organization workflow (the "Organization-wide walk": one file in a
private repository of the organization, not a call into a reusable workflow)
are in
[the CI/CD architecture](architecture/ci-cd.md#issue-classification-reconciler).

## Classification

Every issue carries a few **inherent attributes**: what it *is*, as opposed to
how the factory runs it. That is its **classification**. The **execution
policy** (`.devflow.toml`: rigor, strategy, role tiers, budgets) is the other
layer. It decides how an issue is run and may override any default the
classification implies ([the devflow guide](guides/devflow.md)). The
[glossary](glossary.md#issue-classification) defines each term. The design is
[ADR 2026-09-30](decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md),
as amended by
[ADR 2026-10-01 (Tier as a label)](decisions/2026-10-01-store-the-tier-as-a-label-on-every-owner-type.md),
[ADR 2026-10-01 (Priority AI)](decisions/2026-10-01-add-a-priority-ai-axis-suggested-by-agents.md)
and
[ADR 2026-10-05 (filing rule and organization walk)](decisions/2026-10-05-file-unclassified-issues-with-needs-triage-and-walk-organizations-standalone.md).
This section is the working summary; the writers that keep the derived parts
current are under [Classification reconciler](#classification-reconciler)
above.

### The axes

| Axis | Scale | Set by | Required for triaged | Organization | Personal account |
|---|---|---|---|---|---|
| **Impact** | minimal, low, medium, high, massive | AI or human | yes | issue field | `impact:*` label |
| **Risk** | trivial, low, medium, high, critical | AI or human | yes | issue field | `risk:*` label |
| **Complexity** | xs, s, m, l, xl | AI or human | yes | issue field | `complexity:*` label |
| **Tier** | local, economy, standard, frontier, apex | derived from Risk × Complexity; a human may pin it | no — a cache | `tier:*` label | `tier:*` label |
| **Priority** | urgent, high, medium, low | human only | no, but the Agent queue requires it | issue field (GitHub's built-in) | `priority:*` label |
| **Priority (AI)** | p0, p1, p2, p3, p4 | agent or human, as a suggestion | no | issue field | `priority-ai:*` label |
| **Effort** | 1, 2, 3, 5, 8, 13, 20 | human only, and only on a human task | no | issue field | `effort:*` label |
| **Type** | bug, feature, task, research (a personal account also has `documentation` and `question`) | AI or human | yes | native issue Type | work-type label |
| **Area**, **Layer**, **Domain** | the values of `area:*`, `layer:*` and `domain:*`, each family with a `none` value | AI or human | yes: one from each family, or that family's `none` | labels | labels |

Start date and Target date are organization issue fields a human sets; nothing
here requires them.

### Issue fields on an organization, labels on a personal account

A personal account has no issue fields, so the same axes are stored by owner
type:

- **Impact, Risk, Complexity, Priority, Priority (AI) and Effort** are issue
  fields on an organization and `impact:*`, `risk:*`, `complexity:*`,
  `priority:*`, `priority-ai:*` and `effort:*` labels on a personal account.
  The labels exist on **every** repository, because the label registry
  provisions the same set everywhere, but on an organization they are
  **inert** while the field is set: the field is the source of truth, and a
  same-axis label never overrides it. For Impact, Risk and Complexity the
  reconciler falls back to a same-axis label only when the field is unset.
  Priority, Priority (AI) and Effort labels on an organization are inert, and
  nothing reads them as a fallback.
- **Type** is the native issue Type on an organization and a work-type label
  on a personal account. The same holds: the provisioned work-type labels exist
  on every repository (`documentation` and `question` are GitHub's
  repository-creation defaults, which setup does not re-create), an
  organization never applies one, and the reconciler counts a single work-type
  label as the Type only when no native Type is set.
- **The Tier is a label on both owner types**, `tier:<value>`, and there is no
  `Tier` issue field. It is the one axis whose storage does not follow the
  owner type, so a reader, the reconciler and a writer all treat it the same
  way everywhere.
- **`area:*`, `layer:*` and `domain:*`** are labels on both. Each family has a
  `none` value that records "this axis does not apply".

Which surface suits a datum is the question [Label or field?](#label-or-field)
answers.

### The rubric, in short

The short form below is generated from the descriptions in
[`label-registry.json`](../label-registry.json), which is authoritative. The
long form of the rubric lives in harmon-devkit's `triage` skill. Do not invent
a reading that is not in one of them.

<!-- classification-rubric:begin -->
<!-- Generated from label-registry.json by `node scripts/label-registry-render.mjs rubric-table`. Do not edit by hand — `task test:label-registry` fails on drift. -->

| Axis | Value | Short form |
|---|---|---|
| **Impact** | `minimal` | marginal benefit; most users would not notice it |
| | `low` | small benefit to a few users or a narrow use case |
| | `medium` | clear benefit to a meaningful share of users or goals |
| | `high` | core benefit, or severe harm prevented even if rarely triggered |
| | `massive` | transformative; current goals depend on it |
| **Risk** | `trivial` | a mistake is harmless and trivially reversible |
| | `low` | a mistake is contained, caught quickly, and cheap to undo |
| | `medium` | a mistake breaks a feature or needs a careful rollback |
| | `high` | a mistake reaches many users or their data; recovery is costly |
| | `critical` | a mistake risks data loss, security exposure, or an irreversible outage |
| **Complexity** | `xs` | a tiny, well-understood change with obvious verification |
| | `s` | small and local; a clear approach across a few files |
| | `m` | moderate; several components and some design choices |
| | `l` | large; cross-cutting, with real design and wide verification |
| | `xl` | very large or uncertain; likely to grow or need splitting |
| **Tier** | `local` | work a small self-hosted model can do, possibly slowly |
| | `economy` | cheapest qualified hosted model first; escalation allowed |
| | `standard` | reliable general-purpose coding model first |
| | `frontier` | opus-class heavyweights; no warm-up on weaker models |
| | `apex` | mythos-class leading edge (fable, sol) |
| **Priority** | `urgent` | work on this now, ahead of everything else |
| | `high` | next up; schedule soon |
| | `medium` | normal queue order |
| | `low` | when nothing more pressing remains |
| **Priority (AI)** | `p0` | blocks a merge or deploy — critical |
| | `p1` | a real defect or must-do; next |
| | `p2` | worth doing, not blocking |
| | `p3` | cosmetic or informational |
| | `p4` | negligible |
<!-- classification-rubric:end -->

Three notes come with the scales:

- **Impact is core versus marginal benefit**, not common versus uncommon path:
  a rarely triggered bug with severe consequences can be high impact.
- **For a bug fix, the harm it prevents belongs in Impact** and the danger of
  the fix belongs in Risk.
- **Complexity is on every issue and is never a time estimate.** The human
  time estimate is Effort, and only for a human task.

### Triaged, and the derived `needs-triage`

An issue is **triaged** when every required classification is present: Type
(or the work-type label), one label from each of the `area:*`, `layer:*` and
`domain:*` families (or that family's explicit `none` value), Risk, Complexity
and Impact. That is the glossary's `triaged` entry and
[ADR 2026-09-30](decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D6, as amended for the filing rule by [ADR 2026-10-05](decisions/2026-10-05-file-unclassified-issues-with-needs-triage-and-walk-organizations-standalone.md) D2.

`needs-triage` is **derived** from that: present while any of those is
missing, absent once all are present. Whoever files an issue that is not fully
classified adds it at filing: the issue forms, people and agents alike. After
that it is derived, and nobody clears it by hand: the reconciler maintains it
(see [Classification reconciler](#classification-reconciler)), and so do the
skills (triage, track-work, breakdown) in the same call that writes Risk or
Complexity, once a skills-pin bump carries harmon-devkit#1250, #1251 and #1252.
What counts is the value the reconciler reads: an organization field
that is set wins, and a disagreeing same-axis label is reported, not
decisive. Any native issue Type counts as the Type. A retired or unknown label
or field value does not count as present, and neither does an axis carrying
two labels with no field to decide between them: a second `area:*`, `layer:*`
or `domain:*` label is a conflict that keeps the issue in `needs-triage`.
Priority is not part of the predicate: an issue is triaged without it, though
it is not startable by an agent until a human sets one.

### The Tier: derivation and pin

The Tier is the model stratum an issue is suggested to run at. It is a **pure
function of Risk × Complexity**, a risk-dominant matrix in `.devflow.toml`
(`[tier.matrix]`), implemented once in `devflow-policy.mjs`. The reader's
behaviour is in [the devflow guide](guides/devflow.md#issue-tier). The stored
`tier:<value>` label is a **materialized cache**:

- whoever writes Risk or Complexity writes the Tier in the same call, so an
  agent's write never waits on GitHub Actions (the skills that do this are
  harmon-devkit#1250, #1251 and #1252, not yet in the pinned skills: until a
  pin bump carries them, set Risk and Complexity by hand and leave the Tier to
  the reconciler);
- the reconciler repairs drift, on a schedule and when a human opens an issue
  or changes a label or the Type; an edit to an organization issue field starts
  no event run, so after classifying with fields run
  `classification-reconcile.yml` by hand (`workflow_dispatch`), or the Agent
  queue view lags until the schedule;
- a reader recomputes the Tier from the inputs whenever the label is absent.

**The pin.** A human who disagrees with the derived Tier sets the Tier label
from the GitHub UI and adds `tier:pinned`. Nothing automated writes over a
pinned Tier. An issue carries at most one tier value, so a human pinning a
different tier replaces the existing Tier label first. A pin is a label input
like any other, so the provenance rule applies: an interactive session
confirms a pin the operator has not authorized, and unattended automation
honors one only after verifying who applied it.

**Pin first on an existing repository.** An unqualified `tier:<value>` label
used to be a human's implementer override; it is now the cache automation
rewrites. On an unpinned issue with Risk and Complexity set, the reconciler
(and any writer of those axes) adds the derived Tier and removes every other
tier label. Before that first write, add `tier:pinned` to each open issue
whose hand-set tier label you want to keep.

In execution-policy resolution the order is: an operator instruction, then the
pinned Tier, then `rigor:*` and `tier:<role>:*`, then the derived Tier, then
`default_rigor`. The pinned and the derived Tier set the **implementer** tier
only; the other role tiers come from the resolved rigor profile. A
`tier:<role>:*` label is a role override, not the issue's Tier (see
[Labels](#labels)).

### The Agent queue

The Agent queue is the set of issues an agent may start. It requires a human
**Priority**: an issue with only a Priority (AI) is not startable, and an agent
asks first. Priority (AI) only orders issues within a Priority rung and admits
nothing ([ADR 2026-09-30](decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D7). The authoritative predicate (every other exclusion), the order, and how
the saved view approximates it on each owner type are the **Agent queue** entry
in [Views](#views).

An agent that files an issue classifies it fully, so that it arrives triaged
except for Priority. The rule is in [conventions.md](conventions.md#issues).

### Migration: what the classification retired

Everything below is retired, and none of it is a live vocabulary. Each entry
says where the operator steps are.

- **The `suggest:*` family**, including `suggest:<family>:<model>`, is
  superseded by the derived Tier. It is **retired**, and its namespace has
  been removed from `agent-registry.json`. Nothing provisions or renders it.
  To migrate, remove the label from every issue, pull request and
  discussion that carries it (an issue then resolves through its derived
  Tier), then use guarded `--prune`. There is
  no `--migrate` destination, and the script refuses one. See
  [Migrating retired and renamed labels](#migrating-retired-and-renamed-labels).
- **The `Size` project field** is superseded by Effort (human tasks) and
  Complexity (every issue). Its values have no destination, and deleting the
  field destroys every value on it, unrecoverably: record any you need first.
- **The personal-project `Priority` field** is replaced by the `priority:*`
  labels. On an organization `Priority` was always GitHub's built-in issue
  field, and it stays.
- **The `Agent` issue field** is gone, and no `Agent` value carries over. The
  derived Tier sets the tier an agent runs at, the configured backend or
  harness picks the family within it, and which agent is working an issue is
  the claim label.
- **`tier:adaptive`** has no rung on the Tier scale. Remove the label from every
  issue, pull request and discussion that carries it, and an issue then
  resolves through its derived Tier.
- **A hand-managed `needs-triage` or Tier.** Both are derived now (`needs-triage`
  is added at filing, then maintained). A human who wants a different Tier pins
  it, and an existing repository pins any
  hand-set Tier it wants to keep before the reconciler's first write (see
  [The Tier](#the-tier-derivation-and-pin)).

The steps for these field retirements (the Agent entry, and the Priority /
Size entry), and the order they must run in, are under **Migrating a board
that still has one** in [Fields](#fields).

## Fields

`Status` is a **Project field** — the board pipeline above; it stays on the
project because the built-in workflows (and `project-automation.yml`, on an org)
drive it. It is also the only project field a workflow or an agent ever writes.

The work-metadata field:

- **Product** — which product/area it belongs to (free text)

There is deliberately **no `Priority` or `Size` field** (#1451). Priority is an
issue field on an organization (GitHub's built-in) and a `priority:*` label on
a personal account, with `Priority (AI)` / `priority-ai:*` beside it as the
AI's suggestion; Size is retired in favour of Effort (human tasks) and
Complexity (every issue), per
[ADR 2026-09-30](decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md).

There is deliberately **no `Agent` field**. Whether an agent may take an issue
is decided by the **Agent queue** in [Views](#views); the derived Tier
(`tier:*`) sets the tier an agent runs at, and the configured backend or harness
picks the family within it; which agent *is* working it is the claim label (see
**Claiming** below). A field could carry
none of these answers without duplicating the label vocabulary, and on an organization
the Projects V2 API could not even write it — see
[Label or field?](#label-or-field) and
[ADR 2026-08-07](decisions/2026-08-07-unified-agent-vocabulary.md).

There is likewise deliberately **no `Domain` or `Layer` field** (#875). Both
used to exist as a field *and* a label — `domain:` / `layer:` below — with
nothing syncing an issue's field value to its label, which is exactly the
[Label or field?](#label-or-field) trade-off: a label is readable without
project scope, writable with plain repo scope, and available on personal
repos, none of which the field bought back. Since one surface has to be the
source of truth and the label already was for anyone living in `gh issue list`,
the field was the redundant one.

**Migrating a board that still has one** (set up before a field was retired):
the setup scripts are additive-only by design, so deleting a live field is an
explicit operator step, and reviewing its values comes first — deleting a field
destroys every value on it, unrecoverably.

- **Agent** (retired earlier): no value carries over — the derived Tier
  (`tier:*`) sets the tier an agent runs at, and the configured backend or
  harness picks the family within it.
  1. **Enumerate every board and view that references the field before deleting
     it** (#910): every Project that has it, and every saved view in each that
     filters on it (the **Agent queue** view as it was specified before the
     field was retired did) — not just the board being migrated.
  2. Re-point the saved **Agent queue** view at its current definition in
     [Views](#views). A view still filtered on the field loses its routing
     predicate the moment the field is deleted.
  3. Only then delete the field — Project settings → the field → *Delete field*
     on a personal project. On an organization the field is **org-wide**:
     deleting it under **Settings → Planning → Issue fields** removes the value
     from every issue in every repository and project the org owns, not just
     this board — repeat steps 1–2 across the whole organization before
     deleting, including step 2 for **every** Project whose saved views filter
     on the field, not just the board being migrated.
- **Domain / Layer** (retired by #875): `domain:*`/`layer:*` are provisioned
  by default, so most repos already carry them — but don't skip the
  provisioning step on that assumption; confirm it.
  1. Provision the replacement vocabulary first: run
     `task setup:github-labels` in every repository whose issues carry the
     field. An org-wide issue field is shared by every repo in the org, and
     labels are not — a repo that never ran the script has neither label
     family yet.
  2. List every issue or board item with `Domain`/`Layer` set — filter the
     Project's own board/table view by the field, not a capped CLI listing
     (`gh project item-list` defaults to a page size well under a typical
     board, and `gh issue list` won't show draft items at all) — including
     **draft items**, which can carry the project field but can never carry a
     label. Convert any draft whose value you want to keep into an issue
     first — a draft left as-is loses the value outright once the field is
     gone. List **archived items** too (the project's Archived items page),
     which keep their field values but are hidden from views. For each item,
     add the matching `domain:*`/`layer:*` label —
     **creating it first** if the field carries a custom option (e.g.
     `Domain: crm`) that has no label counterpart yet, since the starter set
     `setup:github-labels` provisioned is only a floor. Nothing kept the two
     in sync, so do not assume the label already exists just because the
     field option does.
  3. Re-point any saved view that **groups, filters, or sorts** by the
     `Domain`/`Layer` field. A label can still filter a view (`domain:auth`,
     say), but — unlike a field — a project view cannot **group or sort** by a
     label, so a view built for the per-domain/per-layer rollup or ordering
     loses that; keep the grouping on `Product` (still a field) and reach for
     a label filter instead.
  4. Only then delete the field(s) — Project settings → the field → *Delete
     field* on a personal project; **Settings → Planning → Issue fields** on an
     organization, org-wide as above.
- **Priority / Size** (retired by #1451): on a **personal account** both were
  project fields; on an **organization** only `Size` was — `Priority` there is
  GitHub's built-in issue field and stays. On a personal account Priority's
  replacement is the `priority:*` labels; `priority-ai:*` (on an organization,
  the `Priority (AI)` issue field) is a separate AI suggestion beside it, not a
  replacement. `Size` has none, and its values go with the field.
  1. Provision the replacement first (personal account): run
     `task setup:github-labels` in every repository whose issues carry a
     `Priority` value — a `priority:*` label must exist in a repo before a value
     can be copied onto its issues.
  2. **Enumerate every board and view that references each field before
     deleting it** (#910): every Project that has the field, and every saved
     view in each that filters, sorts, groups, or sums by it (the Triage, Agent
     queue, Planning, and Mine views as they were specified before #1451 all
     did) — not just the board being migrated. Then list the items that hold a
     value, filtering the Project's own view rather than a capped CLI listing,
     **draft items** included, which can carry the project field but can never
     carry a label, and **archived items** (the project's Archived items page),
     which keep their field values but are hidden from views.
  3. On a personal account, convert any draft whose `Priority` you want to keep
     into an issue first (a label cannot go on a draft; a draft you leave as-is
     loses its value with the field), then carry each `Priority` value you still
     want onto the matching `priority:*` label. A value with no `priority:*`
     label — an option you added beyond Urgent / High / Medium / Low — has no
     counterpart to carry it to: map it to the nearest rung, or record it before
     deleting the field. `Size` values have no destination: keep a record of any
     you need now, because deleting the field destroys them unrecoverably.
  4. Re-point or rebuild every view from step 2 as the **Views** section below
     specifies it. A view still filtered, sorted, or summed by a deleted field
     loses that predicate the moment the field is gone.
  5. Only then delete each field — Project settings → the field → *Delete
     field* — on a personal account both, on an organization `Size` only.

On a personal account there are no issue fields, so `task setup:github-project`
creates **Product** as a project field.

### The provisioned field values

What the setup scripts actually create. Every single-select is a **starter
set**: re-runs append missing options and never rename, reorder, or delete, so
options you add in the UI survive and a value added by a later harmon-init
release lands on the next run.

| Field | Type | Values | Provisioned by |
|---|---|---|---|
| **Status** | project single-select | Inbox, Icebox, Next, Todo, Shaping, Ready, Agent Queue, In Progress, Verifying, In Review, Ready to Merge, Done, Deployed, Accepted | `setup:github-project` |
| **Product** | text | free text | `setup:github-project` (personal) / `setup:github-issue-fields` (org) |

One org-only note. GitHub ships **Priority** and **Effort** (plus **Start
date** and **Target date**) as built-in *issue* fields, and the setup scripts
leave `Priority` and the dates as shipped — so on an organization `Priority` is
GitHub's own field with GitHub's own options, and on a personal account it is
the `priority:*` label family. It is never a project field.

## Labels

Labels are **repo-level** and orthogonal to `Status` (pipeline position) and
`Type` (kind of work) — they tag cross-cutting *facets*, with one exception:
personal-account repos have no native issue Type, so six labels (`bug`,
`feature`, `documentation`, `question`, `task`, `research`) carry that
classification instead; an organization carries it in `Type` alone and never
applies any of the six. Four of them — `bug`, `feature`, `task`,
`research` — are form-backed, applied automatically by the matching issue
form; `documentation` and `question` have no dedicated form and are applied
by hand. Keep the rest in a few families, color-coded by family; the
vocabulary lives in
[`label-registry.json`](../label-registry.json) (the machine-readable manifest
the taxonomy table below is generated from) and the starter set is created by
`task setup:github-labels`:

- **Concerns** — cross-cutting facets worth filtering on: security,
  accessibility, performance, tech debt, internationalization
- **Source** — where the work came from (a customer request, AI authorship) —
  durable provenance, never removed
- **Initiative** — the horizon of a parent issue: `epic` for a time-bound
  deliverable, or `umbrella` for an enduring area, topic, or team — or for a
  `(HUMAN):`/`(QA):` collector (see **Human-task and QA collectors** below).
  These labels describe the issue; sub-issues remain the source of the
  parent/child relationship
- **Human work** — `human` is applied when the issue's completion is primarily a
  human's (actions, decisions, QA, purchases, credentials, physical work),
  whether or not an agent can assist with parts of it. Agents may file, append
  to, or prepare for a `human` issue, but never claim, arm, or implement one
  while it carries the label. Filing never removes `human`. Triage may remove
  `human` only when the issue no longer qualifies for it, and all of these hold:
  the issue is not a `(HUMAN):` or `(QA):` collector, `[HUMAN]` criteria are not
  a majority of its acceptance criteria, and the classifier judges the remaining
  work agent-completable. Every removal is listed in the triage report for a
  person to see. "Prepare for" means comments, drafts or research on the human
  issue itself, never a claim. A part an agent can do is filed as its own issue
  and goes through the Agent queue. When that part cannot start before the human
  step, give it a native blocked-by link to a standalone `human` issue for that
  step, never to a collector, which can stay open by design (see **A precondition
  is a dependency, not a follow-up** below). The agent issue is then not
  startable until that standalone issue closes. `human` + `umbrella` marks a
  `(HUMAN):`/`(QA):` collector (see **Human-task and QA collectors** below) as
  the special case
- **Workflow** — transient triage states; `blocked` is the non-issue-blocker
  flag described above
- **Layer** — which stack slice the change lives in
- **Domain** — which product capability the work serves (the *problem* space).
  Domain values are per-repository vocabulary — grow them from your product's
  own capabilities; the label family is the only surface for this taxonomy
- **Work type** — what kind of work the issue is, on personal-account repos
  where native issue Type is unavailable; the issue forms apply it, and org
  repos use native Type with no work-type label
- **Area** — which codebase subsystem the work lives in (the *solution*
  space). At most one each of `area:`/`domain:`/`layer:` per issue. On these
  exclusive axes, a generic bucket defers to the most specific matching value;
  write that single-owner boundary into the value's registry description
  rather than leaving it implicit
- **Rigor** — the primary depth/effort/budget axis: which `[rigor.*]` profile
  in [`.devflow.toml`](../.devflow.toml) an agent works the issue under — a
  rounds policy, five role tiers, and a breadth envelope together
  ([docs/guides/devflow.md](guides/devflow.md); AGENTS.md, "Rigor and
  strategy are resolved, not stated here"). An agent reads it and never
  self-applies one. It is advisory rather than an authenticated gate: nothing
  verifies who applied it, and the **triage** role can label an issue with no
  push access — so AGENTS.md requires any off-default rigor, and any role
  tier that ends up off its rigor's own built-in profile, to be disclosed in
  the PR body. Two present resolve to the single strongest level (by
  `.devflow.toml`'s `rigor_order`) — its whole profile, never a mix of
  numbers assembled from both.
- **Strategy** — the primary topology/workflow axis: how the work is
  organized and performed — single agent, delegated to workers, independent
  proposals judged by one, or human-directed
  ([docs/guides/devflow.md](guides/devflow.md)) — advisory, like `rigor:`.
  Two present are **ambiguous**, not resolved to either: unlike rigor's
  more-or-less continuum, topologies have no rank between them, so a
  conflict is a resolution error rather than a silent pick.
- **Tier** — the model-routing stratum an issue runs at. An unqualified
  `tier:<value>` label is the issue's stored Tier, a cache of the derived Tier,
  or the pinned Tier with `tier:pinned`; it is not a role override, and only an
  unqualified operator instruction targets the **implementer** role. A scoped
  `tier:orchestrator:<value>` / `tier:implementer:<value>` /
  `tier:reviewer:<value>` / `tier:challenger:<value>` /
  `tier:integrator:<value>` is a role override — advisory, human-written, and
  inert until a consumer resolves it under its own trust model — and targets
  exactly the role it names. Absent any override, all five roles come from the
  resolved rigor level. All 25
  scoped values (5 roles × 5 concrete tiers) are **provisioned** like every
  other tier value, not created on demand.

The prose above describes what each family *means*; the actual values — names,
colors, writers, lifecycle — live in `label-registry.json` and appear in the
generated taxonomy table below, so vocabulary is never restated here.

One more family names **model intelligence** rather than a facet of the work,
and its vocabulary is not hand-listed anywhere: it is rendered from
`agent-registry.json` (see [Agent families and harnesses](#agent-families-and-harnesses)),
so provisioning and documentation cannot fork from each other.

- **Claim** — `claim:<family>` — which agent family is working
  the issue *right now*, written by the agent itself (see **Claiming** below).
  Model-level (`claim:<family>:<model>`) refines it the same way

Which model stratum an issue *should* run at is not a label family of its own
any more: it is the derived [Tier](#the-tier-derivation-and-pin) (`tier:*`,
above). The retired family-suggestion labels are covered under
[Migration](#migration-what-the-classification-retired).

> **Transition — the retired `agent:*` family.** Repos seeded before the
> registry-driven vocabulary carry `agent:claude-code`-style labels instead of
> `claim:*`. Setup never deletes labels, and the vendored claim/release skills
> (harmon-devkit v0.23.0+) prefer `claim:*` and fall back to `agent:*` where
> only the legacy family exists — so existing claims keep working while live
> labels migrate
> ([#663](https://github.com/evanharmon1/harmon-init/issues/663)), and
> everything below about the claim label applies to whichever family a repo
> carries. Do not seed `agent:*` into new repos; a repo carrying neither
> family tracks a claim by assignee and claim comment alone.

The `layer:`, `domain:`, and `area:` families are the *only* surface for this
taxonomy (see Fields) — there is no more paired project/issue field to keep
in step with, so extend the label lists alone as the product grows. `domain:`
(problem space) and `area:` (solution space) are both per-repository
vocabulary whose starter values are a floor; `layer:` is product-independent
and normally needs no edits.

A `claim:` label and the Tier answer different questions. `claim:` is the
family working the issue now; the Tier is the stratum the issue should run at.
Never treat one as a copy of the other: a claim never rewrites the Tier, and
the Tier never implies a claim — see **Claiming** below.

GitHub labels live per-repository (there's no shared org label pool).
`setup-github-labels` seeds the set into one repo — run it in each, or set the
org's **default labels** (org Settings → Repository, UI-only) to seed *new* repos
(it won't change existing ones). The default path is additive: it creates or
updates only provisioned labels and never deletes a live label. To inspect live
labels outside the registry inventory (including adopted, tool-owned, and
recognized families), run `./scripts/setup-github-labels.sh --repo
<owner/repo> --report-unregistered` with the same `--foreman` and
`--release-please` profile flags used for setup when you want to mirror
provisioning. Maintenance protection still includes every non-retired
registered family, including gated tool labels, when those flags are omitted.
The read-only report pages all labels, all-state issues and pull requests, and
repository discussions, and prints separate association counts; an indeterminate read fails closed. For
an intentional retirement, use the guarded maintenance flow below.
`--prune` accepts one or more repeatable `--migrate OLD=NEW` flags. The write
path requires a quiescent maintenance window: pause claim/release, Foreman,
release-please, and other human/API label writers for the whole run.
`--report-unregistered` is read-only, but its counts are a snapshot; obtain a
fresh report immediately before pruning. The command validates live registry
destinations, requires a TTY confirmation before writes (or the separate
explicit `--yes` flag for automation), attempts to migrate associations for
matching issues, PRs, and discussions returned by its current paginated snapshot, re-reads
associations, and attempts to delete only reported labels that are unassociated
in its latest snapshot; names with observed associations are refused. Retired
labels are reportable, so use this flow instead of starting with a direct
`gh label delete`.

The guard is deliberately not an atomic API transaction. The command verifies
each migration around source removal, then takes one complete, bounded
post-migration association snapshot before the deletion batch. It fails closed
on read or verification errors, but GitHub has no transaction or compare-and-swap that binds the final
association read to the following edit/DELETE. A concurrent writer can still
change labels after that read and before the request, and the command cannot
undo a successful concurrent mutation. If the window was not quiescent or any
verification drifts, treat the operation as incomplete, reconcile live
associations, and rerun in a new quiet window; a successful exit alone is not a
claim of association preservation.

### Migrating retired and renamed labels

Retiring a label is a guarded migration, never a direct `gh label delete`. The
mechanics are the ones above; what differs per label is its destination.

**A retired label with no one-to-one replacement has no destination.**
`suggest:*` (including `suggest:<family>:<model>`, superseded by the derived
Tier) and `tier:adaptive` (no rung on the Tier scale) are refused as `--migrate`
sources, because a migration would stamp an unrelated label on every associated
record. Remove the label from every issue, pull request and discussion that
carries it (an issue then resolves through its derived Tier), then rerun
`--prune`, which offers the now-unassociated label for deletion.

**Fixed legacy mappings are authoritative.** Use the association-migration path
for these fixed sources: `agent:claude-code` → `claim:claude`,
`agent:codex` → `claim:gpt`, `agent:gemini-cli` → `claim:gemini`, `agent:kimi-k2` → `claim:kimi`,
`agent:qwen-code` → `claim:qwen`, and `claim:codex` → `claim:gpt`. Pass one
repeatable `--migrate OLD=NEW` per exact
live source; `--migrate` does not match prefixes. The `OLD=NEW` form contains
exactly one `=`; labels containing `=` must be relabeled per record instead of
passed to bulk migration. For a model-level fixed
source, move only the family segment and preserve the recorded suffix, for
example `claim:codex:sol` → `claim:gpt:sol`. Model-level labels refine rather than
replace their family-level label, so the guarded command retains or adds both
associations. When a recognized model-level destination is absent, the guarded
command creates it only after confirmation by copying the live family label's
color and description; if that family label is absent, setup must run first and
maintenance stops. Enumerate model-level names explicitly with
`gh label list --repo <owner/repo> --limit 1000 --json name --jq '.[].name' |
grep -E '^claim:(codex|copilot):'`; for each source, inspect all-state
`gh issue list --label <old> --state all --limit 1000` and
`gh pr list --label <old> --state all --limit 1000`. An exactly-full manual
result is capped; increase the limit and rerun before writes. The maintenance
path itself uses `gh api --paginate` and refuses an indeterminate read.

For a fixed mapping, do not use `gh label edit` or a hand-written
create-then-delete sequence. Use `--migrate`: it accepts a live registered
destination (or creates a recognized on-demand model destination, as described
above), validates the live registry destination, attempts the association move
for each matching issue, PR, and discussion found in the paginated snapshots,
and permits guarded `--prune` only when a fresh snapshot shows the source has
zero associations. For per-record broker handling, add and verify the
destination on each record before removing the old association; after all
records are handled, a fresh zero-association snapshot may permit guarded
`--prune` to attempt retiring the old label.

**Copilot labels need a per-record family decision, not a default-based rename.**
`copilot-cli` is a broker, not a model family: its picker defaults to `mai`,
but MAI is only that default and never evidence for a migration. Do not pass
`agent:github-copilot*` or `claim:copilot*` to bulk
`--migrate`; the command rejects broker-derived sources because one destination
cannot represent mixed runtime records. For `claim:copilot`, inspect each
issue/PR's claim/session record and handle that record individually as
`claim:<actual-family>`; use `claim:mai` only when the record confirms MAI.
Apply the same distinction to model-level
`claim:copilot:<model>` labels and preserve a model
suffix only after the actual family is known. Include Discussions in the
per-record inventory: the read-only report gives their association count, and
the Discussions UI or GraphQL API identifies the records to relabel. If a live
claim's record is
missing, settle it with its owner or leave the label untouched rather than
guess.

Before moving any in-flight `claim:*`/legacy `agent:*` marker, settle the claim
or amend its durable record in the same sitting: its release path names the
exact label it will remove, and moving only the issue/PR association strands
the replacement marker. Interactive runs confirm on the TTY; automation must
state destructive intent again with separate `--yes` (piped stdin is refused).

### Labels carry no permissions

**GitHub has no per-label permission.** Anyone with triage access to the repo
can apply or remove any label, and the label itself records nothing about who
did — a label is a string on an issue, not a capability. So a label can never
be the security boundary. The boundary is always in the **consumer**: whatever
reads a label to start work must independently establish who applied it, and
refuse when it cannot.

That rule has a hard form: **any label that triggers automation must have an
actor-verifying consumer.** Today that class is exactly the Foreman arming
labels. Every other family either triggers nothing, or is read by a consumer
that can only stop work:

| Family | Triggers execution? | How the consumer establishes trust |
|---|---|---|
| `foreman:<adapter>`, `foreman:approved` | **yes** — arms an issue for dispatch | Foreman reads the `labeled` **timeline event**, takes the actor from it, and requires that login in `trusted_actors` (`.foreman.toml`). Unattributable arming is a fail-closed refusal, never a dispatch — which is also why issue-field arming is refused outright: field events carry an actor only under a preview GraphQL API, and the timeline algorithm is specified for labels (ponderousdev/foreman#139) |
| the Claude Actions workflows | **no** — labels trigger nothing at all | Execution starts only on an explicit `@claude` mention naming `plan`, `implement`, or `review`, from a login on the workflow's sender allowlist. The allowlist is enforced in the job `if:` and re-asserted in a token-free step *before* any credential is minted |
| `claim:*` (and legacy `agent:*`) | **no** — read as a gate, not a trigger | Those workflows refuse to start on a target that already carries one. No actor check is needed for a signal that can only *withhold* execution: the worst outcome is a visible, reversible refusal |
| `autorelease: *` | **no** | release-please writes them on its own release PRs and reads only what it wrote; nothing dispatches from one |
| everything else | **no** | human-facing facets, read by people and saved views |

There are no `claude-plan` / `claude-implement` / `claude-review` **trigger**
labels, for exactly this reason: a `labeled` event carries an actor, but the
label sitting on the issue afterwards does not, so half the paths a
label-triggered workflow can start from have nobody to check. Label setup is
additive, so a repository standardized before those labels were retired may
still carry them live-but-inert — report them with `--report-unregistered`,
then map and retire them with guarded `--migrate`/`--prune` maintenance.

### Label or field?

An axis can live in three places, a label, an issue field or a project field,
and they are not interchangeable. The choice is made on mechanics, not taste.

**A label** is per-repository and works on every owner type. Use one when the
datum must be any of:

- **multi-valued** — an issue can legitimately carry two at once, for the
  families the registry marks non-exclusive (a second `area:*`, `layer:*` or
  `domain:*` label is a conflict that keeps the issue in `needs-triage`);
- **visible without project scope** — readable from `gh issue list` and the
  issue page, with no Projects API token;
- **writable with plain repo scope** — no `project` scope, no org permission;
- **timeline-attributable** — the `labeled` event records who applied it and
  when, and it is the one actor signal the checks here read;
- **available on personal repos** — issue fields do not exist there.

**An issue field** is organization-only. It holds single-valued classification
metadata that lives on the **issue** itself: the value is the same in every
project the issue belongs to, and it does not depend on project membership. On
an organization it is where Impact, Risk, Complexity, Priority, Priority (AI)
and Effort are stored (see
[Classification](#issue-fields-on-an-organization-labels-on-a-personal-account)).
A field change is recorded in the issue's timeline with its actor (the GraphQL
`IssueFieldAddedEvent` and `IssueFieldChangedEvent` timeline items, a preview
API). No workflow here runs on a field edit, so the scheduled walk, or a run you
start by hand, is the only reconciler path. Fields are not an arming surface:
nothing in this repository reads or verifies a field's actor before acting, and
arming stays with `foreman:*` labels.

**A project field** lives on the board item, in one project, and is for
**views only**: it is how a board is grouped, sorted and filtered. It needs the
Projects scope for API reads and writes, and its changes are not a
`labeled`-style timeline event that an actor check can read. `Status` is the
project field, and `Product` is one on a personal account (on an organization
it is an issue field). Nothing is classified in a project field.

In practice, a **label** is the default; an **issue field** is for an axis that
is single-valued, on an organization, and that every project should agree on; a
**project field** is for pure board metadata that nothing decides work from
(`Status` plays no part in the Agent queue).

The consequences are not stylistic. Foreman arming is labels because field events carry an actor only under a preview API, and the timeline algorithm is specified for labels (ponderousdev/foreman#139). Claims are labels because a claim
must be writable and visible to an agent holding nothing but repo scope, on
personal and org repos alike. The Tier is a label on both owner types even
where issue fields exist: a reader, the reconciler and a writer then share one
storage path, and the pin needs a marker (`tier:pinned`) that works where
issue fields cannot, since they have no boolean type and a personal account has
none at all. And there is deliberately no `Agent` field: advisory routing and
live ownership are two different facts, a single-select could carry neither
without duplicating the label vocabulary, and on an organization the Projects
V2 API could not write it at all. `Domain` and `Layer` were fields once too,
and were retired for the same reason: a label already covered every one of the
bullets above and nothing kept the two surfaces in sync (#875).

### The complete label taxonomy

Every label family this repository knows about, **generated from the
machine-readable manifest** — [`label-registry.json`](../label-registry.json)
holds the families, values, colors, writers, lifecycle, and per-value
overrides, and `task test:label-registry` fails when this table drifts from
it. **Provisioned** means `task setup:github-labels` creates it; **tool-owned**
means the tool that uses it creates it on demand, and provisioning
deliberately leaves it alone.

<!-- label-taxonomy:begin -->
<!-- Generated from label-registry.json by `node scripts/label-registry-render.mjs docs-table`. Do not edit by hand — `task test:label-registry` fails on drift. -->

| Label / family | Writer | Reader | Trust class | Lifecycle |
|---|---|---|---|---|
| `sec`, `a11y`, `perf`, `tech-debt`, `i18n`, `l10n` | humans, at triage | humans, saved views | provisioned; inert | applied when true, removed when not |
| `customer-request`, `ai-generated` | whoever files or authors the work, human or agent | humans, saved views | provisioned; inert | durable provenance — never removed |
| `epic`, `umbrella` | humans, at planning or grooming; agents when filing a (HUMAN)/(QA) collector or an approved breakdown | humans, saved views | provisioned; inert | applied to a parent while its role is current; removed or changed when its horizon changes |
| `human` | whoever files or triages the issue, human or agent; triage may remove it only when the issue no longer qualifies (non-collector, no [HUMAN] majority, agent-completable) | humans, saved views; agents, to skip dispatch | provisioned; inert | applied while completion is primarily a human's; removed once the issue's remaining completion is no longer primarily a human's |
| `needs-triage` | people, agents and the issue forms add it at filing; after that the triage skill and the GitHub Actions classification reconciler maintain it (derived: added while classification is incomplete, removed once it is complete) | humans, the Triage view | provisioned; inert | a new issue that is not fully classified starts with it (people, agents and the issue forms add it at filing); after that it is derived and never cleared by hand |
| `needs-requirements`, `blocked`, `waiting`, `needs-decision`, `needs-response`, `needs-communication` | humans, at triage | humans, the Triage view | provisioned; inert | transient — removed as soon as the state clears |
| `needs-review` | the integration stage, at ready-for-review; humans | humans, the review list; the agent queue, which excludes it | provisioned; inert | added at ready-for-review, when `claim:*` is removed; removed if review pulls the work back into fix rounds |
| `bug`, `feature`, `task`, `research` | the issue forms on personal-account repos; humans or agents at triage | humans, saved views | provisioned; inert | durable classification — org repos use native issue Type and no work-type label |
| `documentation` | GitHub ships it at repo creation; humans or agents apply it at triage | humans, saved views | not provisioned — a GitHub repo-creation default adopted into the work-type vocabulary | durable classification — org repos use native issue Type and no work-type label |
| `question` | GitHub ships it at repo creation; humans or agents apply it at triage | humans, saved views | not provisioned — a GitHub repo-creation default adopted into the work-type vocabulary | durable classification — org repos use native issue Type and no work-type label |
| `dependencies` | Renovate, when it manages dependency updates | humans, saved views | not provisioned — Renovate creates it on demand; never deleted by setup | tool-managed by Renovate |
| `enhancement` (**retired**) | nobody — replaced by `feature` | humans, saved views | retired — the GitHub repo-creation default this vocabulary replaces with `feature`; never provisioned | use guarded `--prune` with `--migrate enhancement=feature` |
| `layer:{ui,logic,data,integration,infra,none}` | humans or agents, at triage | humans, `gh issue list --label` | provisioned; inert | durable classification; the label family is the only surface — there is no paired project field; `layer:none` records that the axis does not apply |
| `domain:{template,standardization,dev-loop,agent-workflow,project-tracking,auth,delivery,environment,none}` | humans or agents, at triage | humans, `gh issue list --label` | provisioned; inert | durable classification; the label family is the only surface — there is no paired project field; `domain:none` records that the axis does not apply |
| `domain:platform` (**retired**) | nobody — retired at root | humans, `gh issue list --label` | retired — split across dev-loop/delivery/environment; never provisioned here | choose replacement domains per record, relabel each record, then use guarded `--prune` only after `domain:platform` reaches zero associations |
| `domain:billing` (**retired**) | nobody — retired at root | humans, `gh issue list --label` | retired — a generic starter value this repo never needed | choose the replacement, then use guarded `--prune` with `--migrate OLD=NEW` |
| `area:{copier,devcontainer,ci,tasks,tests,deps,skills,foreman,gauntlet,worktree,release,security,pm,docs,none}` | humans or agents, at triage | humans, `gh issue list --label` | provisioned; inert | durable classification; area = solution space, domain = problem space, layer = stack slice; `area:none` records that the axis does not apply |
| `area:template` (**retired**) | nobody — renamed | humans, `gh issue list --label` | retired — renamed to `area:copier` (the engine was what it labeled) | use guarded `--prune` with `--migrate area:template=area:copier` |
| `area:codex` (**retired**) | nobody — renamed | humans, `gh issue list --label` | retired — renamed to `area:gauntlet`; codex is the current backend, not the stage | use guarded `--prune` with `--migrate area:codex=area:gauntlet` |
| `impact:{minimal,low,medium,high,massive}` | humans or agents, at triage or filing — agent-authored issues arrive with it set | humans, saved views | provisioned; **advisory** — a required axis for triaged; arms nothing | durable classification; required for an issue to count as triaged |
| `risk:{trivial,low,medium,high,critical}` | humans or agents, at triage or filing — agent-authored issues arrive with it set | humans, saved views; the Tier derivation (Risk × Complexity) | provisioned; **read by agents** — an input to the derived Tier (Risk × Complexity); arms nothing | durable classification; required for triaged; whoever changes it re-derives the Tier in the same write |
| `complexity:{xs,s,m,l,xl}` | humans or agents, at triage or filing — agent-authored issues arrive with it set | humans, saved views; the Tier derivation (Risk × Complexity) | provisioned; **read by agents** — an input to the derived Tier (Risk × Complexity); arms nothing | durable classification; required for triaged; whoever changes it re-derives the Tier in the same write |
| `priority:{urgent,high,medium,low}` | humans only — an agent never sets or changes it | humans, saved views; the agent queue (an issue with no Priority is not queued) | provisioned; **advisory** — orders the agent queue; arms nothing | set by a human when ranking the work; changed as priorities move |
| `priority-ai:{p0,p1,p2,p3,p4}` | agents or humans — the AI's suggestion, never required; a review finding filed as an issue carries its adjudicated badge (P0→p0, P1→p1, P2→p2, P3→p3; nothing from a review maps to p4) | humans, saved views; the effective priority, which is the human `priority` when set and else this suggestion; in the agent queue it only orders issues within a `priority` rung and admits nothing | provisioned; **advisory** — the AI's suggestion, overridden by the human `priority` family; arms nothing | written by an agent or human when classifying or filing the issue; changed as the AI learns more; the human `priority` overrides it without clearing it |
| `effort:{1,2,3,5,8,13,20}` | humans only, on a human task — agent work carries Complexity instead | humans, saved views | provisioned; **advisory** — a human estimate; arms nothing | set by a human when estimating a human task; agent issues never carry it |
| `rigor:{cursory,light,standard,thorough,deep,forensic}` | humans, at triage — **never an agent on itself** | agents, when entering the Dev Loop | provisioned; **read by agents** — selects a rounds policy, five role tiers, and a breadth envelope; arms nothing | set when the default rigor is wrong for the change; survives the work |
| `tier:{local,economy,standard,frontier,apex}` | agents, in the write that sets Risk or Complexity, and the GitHub Actions reconciler; humans may set one, and pin it with `tier:pinned` | humans and agents — the issue's derived (or pinned) Tier, an input to the implementer tier; models are classified in `agent-registry.json` (ADR 2026-09-30) | provisioned; **read by agents** — a pin outranks the derived Tier and both rank below an operator instruction; resolved against `.devflow.toml`'s `tier_order`; arms nothing | a materialized cache — rewritten whenever Risk or Complexity changes and by the scheduled reconciler (daily on personal-account repositories, monthly on organization ones), recomputed by readers when absent; never rewritten while `tier:pinned` is present |
| `tier:pinned` | humans only, from the GitHub UI, together with setting the Tier | agents and automation — a pinned Tier is never rewritten | provisioned; **provenance-checked** — an interactive session confirms a pin the operator has not authorized, and unattended automation honors one only after verifying who applied it (ADR 2026-09-30 D5) | added with the Tier value; removed to hand the Tier back to derivation; a human pinning a different tier replaces the existing Tier label first, since two tier values at once is a conflict for the reader to resolve, never one a writer creates |
| `tier:adaptive` (**retired**) | nobody — retired 2026-10-01 | humans — retired, see the derived Tier (`tier:<value>`) | retired — no rung on the Tier scale (ADR 2026-09-30 D8); never provisioned | remove the label from each issue — it then resolves through its derived Tier — then use guarded `--prune` |
| `tier:orchestrator:local`, `tier:orchestrator:economy`, `tier:orchestrator:standard`, `tier:orchestrator:frontier`, `tier:orchestrator:apex`, `tier:implementer:local`, `tier:implementer:economy`, `tier:implementer:standard`, `tier:implementer:frontier`, `tier:implementer:apex`, `tier:reviewer:local`, `tier:reviewer:economy`, `tier:reviewer:standard`, `tier:reviewer:frontier`, `tier:reviewer:apex`, `tier:challenger:local`, `tier:challenger:economy`, `tier:challenger:standard`, `tier:challenger:frontier`, `tier:challenger:apex`, `tier:integrator:local`, `tier:integrator:economy`, `tier:integrator:standard`, `tier:integrator:frontier`, `tier:integrator:apex` | humans, at triage or planning — never an agent on itself | humans and agents — targets exactly the role it names; models are classified in `agent-registry.json` (ADR 2026-08-16/2026-08-24), unlike the unqualified `tier:<value>`, which is the issue's stored Tier rather than a role override | provisioned; **advisory** — resolved against `.devflow.toml`'s `tier_order`; arms nothing | set when one role's tier should differ from the rigor's own profile; strongest-wins per role |
| `method:{oneshot,plan,plan-approved,orchestrate,council,human-led}` (**retired**) | nobody — renamed to strategy:* | humans — retired, see `strategy:*` | retired — execution topology renamed to the `strategy` family; never provisioned | migrate each with guarded `--prune` and repeatable `--migrate method:<v>=strategy:<v>` |
| `strategy:{oneshot,plan,plan-approved,orchestrate,council,human-led}` | humans, at triage or planning — never an agent on itself | agents, when entering the Dev Loop — Foreman does not consume it yet (out of scope here) | provisioned; **read by agents** — selects an execution topology, arms nothing | set when the default strategy is wrong for the change; survives the work |
| `suggest:<family>` (**retired**) | nobody — superseded by the derived Tier | humans — retired, see `tier:*` | retired — superseded by the derived Tier; never provisioned and no longer rendered from the agent registry | remove the label from each issue — it then resolves through its derived Tier — then use guarded `--prune` (no `--migrate`: nothing replaces a family suggestion one-to-one) |
| `suggest:<family>:<model>` (**retired**) | nobody — superseded by the derived Tier | humans — retired, see `tier:*` | retired — never provisioned; no tool creates it any more | remove the label from each issue, then use guarded `--prune` |
| `claim:<family>` | the agent itself — a vendored claim skill, or a Claude Actions run | humans; the Claude Actions claim gate; `claim-release.yml` where the repo ships it | provisioned from the registry; a **gate**, never a trigger | added at claim, removed at release — by the workflow's `always()` step, or by `claim-release.yml` on close where the repo ships it |
| `claim:<family>:<model>` | the agent itself | humans; the Claude Actions claim gate; `claim-release.yml` where the repo ships it | **tool-owned, created on demand** | refines the family label; added at claim, removed at release |
| `agent:<harness>` (**retired**) | nobody — never seeded into a new repo | claim skills (and `claim-release.yml` where present), which still recognize it | legacy; inert | after choosing the actual claim family, use guarded `--prune` with repeatable `--migrate OLD=NEW` |
| `foreman:<adapter>` | a trusted human, to arm an issue | Foreman | provisioned from the registry where the repo uses foreman (`--foreman`), for production-dispatchable adapters only; **actor-verified arming** | applied to arm; stays on the issue |
| `foreman:approved` | a trusted human | Foreman | provisioned (`--foreman`); **actor-verified arming** with the repo default backend | applied to arm; stays on the issue |
| `foreman:hold` | a human | Foreman | provisioned (`--foreman`); non-arming and always wins | applied to exclude, removed to re-include |
| `foreman:satisfied` | a human | Foreman's dependency graph | provisioned (`--foreman`); non-arming dependency override | applied per dependency decision |
| `foreman:external` | a human | Foreman's dependency graph | provisioned (`--foreman`); non-arming dependency override | applied per dependency decision |
| `foreman:dispatched` | Foreman, on the draft PR it opens | Foreman, humans | **tool-owned, auto-created** | added when the draft PR opens |
| `foreman:ready-for-review` | Foreman, on passing its readiness gate | Foreman, humans | **tool-owned, auto-created** | added at promotion; the hand-off to human review |
| `type:<commit-type>` | a human, optionally | Foreman, to pick the unit's conventional-commit type | **not provisioned** — an optional override of the native issue `Type` | applied when the native type is absent or wrong |
| `autorelease: pending`, `autorelease: tagged` | release-please | release-please | **tool-owned, auto-created**; note the space after the colon — not part of the `family:value` convention | pending on the open release PR, tagged once the release is cut |
| `duplicate`, `good first issue`, `help wanted`, `invalid`, `wontfix` | GitHub, at repo creation | humans | not provisioned, never deleted by setup | adopted; leave in place — inventory reporting and guarded pruning exclude it |
<!-- label-taxonomy:end -->

One nuance the table compresses: `claim:claude` in a repo with **no label
provisioning at all** is tool-owned in practice — the Claude Actions run
auto-creates it with the registry's own color and description, so a later
provisioning run reconciles it rather than fighting it.

Foreman's PR-side labels are namespaced on purpose: every label Foreman reads
or writes lives under `foreman:`, so the arming inputs and the lifecycle
outputs are one legible namespace. `foreman:ready-for-review` is the accurate
name for what promotion means — the automated work is complete and a human is
now being asked to review it. Approval stays GitHub's native review decision,
and merging stays human-only.

### Agent families and harnesses

The `claim:` vocabulary and the Foreman adapter selectors come
from one machine-readable source, `agent-registry.json`, validated against
`agent-registry.schema.json`. The two axes are deliberately distinct: a
**family** is the model intelligence doing the reasoning, a **harness** is the
executable that runs it. `claim:` names families;
`foreman:<adapter>` names harness machinery. The registry no longer declares the
retired `suggest` namespace; nothing provisions or renders it (see
[Migration](#migration-what-the-classification-retired)). The reasoning, and
the rules for naming a family or a harness slug, are in
[ADR 2026-08-07](decisions/2026-08-07-unified-agent-vocabulary.md).

The tables below are **generated** from that file — `task test:registry-docs`
regenerates them and fails on any difference, so they cannot drift from what
provisioning actually creates. Model-level labels are created on demand rather
than seeded, and a `foreman:` selector is provisioned only for an adapter that
exists and is production-dispatchable in the pinned Foreman release: a selector
with no adapter behind it is a false capability that can strand armed work.

#### Model lines, versions, and efforts

Each entry under a family's `models` is a model **line**, not a release. The
line `slug` names the product (`opus`, `flash`, `coder-plus`) and stays the
same across releases, so it never embeds a version — `validate-agent-registry`
rejects a slug segment such as `5`, `v4` or `k3`. The releases live in the
line's `versions` list, newest first. Each version has its own `slug` (`5.5`,
`3.8`), a `display_name`, and a `retired` flag. A line has exactly one current
(non-retired) version, and it is listed first. Exactly one, not "at most one":
a line with no current version would still lend its tier to the policy
readers. Older releases stay as retired entries, for the record. "Newest
first" is checked: slugs are split into components on `.` and `-` and compared
left to right, numerically when both components are numbers (`3.10` is newer
than `3.9`), and otherwise as strings. A slug that runs out of components first
is the older one (`3` before `3.1`). Model-level claim labels derive from the line slug, so
`claim:gemini:flash` keeps its meaning as Flash moves from 3.8 to its next
release.

The line's `tier` is the tier of its current version. The policy readers
reason about tiers per line (which tiers a family can reach), so a version may
carry its own `tier` only once it is retired, as history. This rule has a
deliberate consequence for two families. Gemini's 3.7 and 3.6 Flash were its
standard rung, and DeepSeek's V4 Flash was its economy rung. Both are now
retired versions of a `flash` line whose current release sits on a different
tier, so **Gemini no longer reaches `standard` and DeepSeek no longer reaches
`economy`**. Per-version current tiers would need reader support. That is
tracked in
[harmon-devkit#1268](https://github.com/evanharmon1/harmon-devkit/issues/1268).

Each harness declares the reasoning `efforts` it accepts. The list is drawn
from the registry-wide `effort_ladder` and kept in ladder order. Effort belongs
to the harness, not the model. The list holds the levels the harness is verified
to accept — for a provider-rewired wrapper, for the models its launcher resolves.
A level documented only
for a model the harness does not resolve is not recorded. An empty list means
no separate, verified effort
setting is recorded. Numeric token budgets and on/off switches are not mapped
onto the ladder, and aliases that collapse onto another level add no rung.

The following documentation was checked on **2026-10-10**. The existing
`claude-code`, `claude-code-action` and `codex-cli` lists remain as previously
verified; the checks below establish the other entries' status. GLM remains
unverified for Anthropic effort pass-through; hosted Qwen and MiniMax remain
unverified for the models their wrappers resolve:

- **`claude-code-deepseek`**: DeepSeek's [thinking-mode reference](https://api-docs.deepseek.com/guides/thinking_mode/)
  documents Anthropic `output_config.effort` with distinct `low`, `high` and
  `max` levels, covering the launcher's configured `deepseek-v4-pro` /
  `deepseek-v4-flash` models. Other accepted names map onto those levels.
- **`claude-code-kimi`**: Kimi's [Claude Code integration](https://platform.kimi.ai/docs/guide/claude-code-kimi)
  documents `CLAUDE_CODE_EFFORT_LEVEL`; its [reasoning-effort reference](https://platform.kimi.ai/docs/guide/use-reasoning-effort)
  lists K3's `low`, `high` and `max`, covering the K line this wrapper resolves.
  These lists describe K3, not older K2 models.
- **`claude-code-minimax`**: MiniMax's [Anthropic compatibility reference](https://platform.minimax.io/docs/api-reference/text-anthropic-api)
  documents `output_config.effort`: `low`, `medium`, `high`, `xhigh`, `max`.
  This control is documented only for `MiniMax-M3.1-Flash-Preview`.
  This repository provisions no `claude-minimax` launcher yet, and the registry's
  minimax family carries M3. The list stays `[]` until a launcher exists and
  the provider documents effort for the model it resolves.
- **`claude-code-qwen`**: Alibaba's [Anthropic Messages reference](https://www.alibabacloud.com/help/en/model-studio/anthropic-api-messages)
  documents `output_config.effort` for Qwen3.8 Max/Flash: `low`, `medium`,
  `xhigh`. `high` and `max` map to `xhigh`. This wrapper resolves Qwen3.7 Max
  / Coder Plus, so its list stays `[]` (unverified for the configured models)
  until the wrapper moves to supported models or Alibaba documents effort
  support for its configured models.
- **`claude-code-glm` — still unverified**: Z.ai's [deep-thinking reference](https://docs.z.ai/guides/capabilities/thinking)
  documents `reasoning_effort`, and its [Claude Code integration](https://docs.z.ai/devpack/tool/claude)
  documents the Anthropic endpoint. Neither establishes the endpoint's
  handling of Claude Code's `output_config.effort`; keep `[]` until that
  pass-through is documented or verified.
- **`claude-code-qwen-local`**: no reasoning-effort setting was established
  for the configured `qwen3-coder:30b`. Qwen's [30B Coder model card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct)
  documents non-thinking mode only. [Ollama](https://docs.ollama.com/api/anthropic-compatibility)
  supports model-defined `output_config.effort` names, but that does not add
  reasoning to this model; [LM Studio's Messages documentation](https://lmstudio.ai/docs/developer/anthropic-compat)
  establishes no effort levels for it. Keep `[]` for this configuration.
- **`antigravity`**: Google's [models page](https://www.antigravity.google/docs/models/)
  places the thinking choice in model selection (for example, a Flash Medium
  or Pro High selection). Its [CLI reference](https://www.antigravity.google/docs/cli/reference/)
  exposes `/model` but no separate effort setting, so keep `[]`.
- **`copilot-cli`**: GitHub's [CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
  documents `--effort` / `--reasoning-effort`: `low`, `medium`, `high`,
  `xhigh`, `max`, subject to the selected model.
- **`qwen-code`**: the official [model-provider configuration reference](https://github.com/QwenLM/qwen-code/blob/main/docs/users/configuration/model-providers.md)
  documents `generationConfig.reasoning.effort` and configurable capability
  tiers: `low`, `medium`, `high`, `xhigh`, `max`. Endpoint/model profiles can
  restrict or normalize these values; token budgets alone add no levels.
- **`opencode`**: the [model configuration reference](https://opencode.ai/docs/models/)
  documents `reasoningEffort` and named variants covering `minimal`, `low`,
  `medium`, `high`, `xhigh`, `max` across providers. The [v2 reference](https://opencode.ai/v2/docs/models)
  uses model `settings.reasoningEffort`; available variants and accepted
  settings depend on the provider/model.
- **`pi` and `oh-my-pi`**: their official CLI references
  ([Pi](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/cli.md),
  [Oh My Pi](https://github.com/can1357/oh-my-pi/blob/main/docs/cli-reference.md))
  document `--thinking`: `minimal`, `low`, `medium`, `high`, `xhigh`, `max`.
  `off` (and Oh My Pi's `auto`) are not effort-ladder levels; model capability
  limits still apply.
- **`goose`**: the official [provider configuration reference](https://github.com/block/goose/blob/main/documentation/docs/getting-started/providers.md)
  documents `GOOSE_THINKING_EFFORT` / `goose configure` for Muse Spark.
  The recorded list is `GOOSE_THINKING_EFFORT`'s own values: `low`, `medium`,
  `high`, `max`. Per-provider variables such as `GEMINI3_THINKING_LEVEL`
  (which accepts `low` and `high`) are separate controls, not part of this list;
  `off` and numeric budgets add no ladder levels.
- **`cline`**: the official [CLI reference](https://github.com/cline/cline/blob/main/docs/cli/cli-reference.mdx)
  documents `--thinking`: `low`, `medium`, `high`, `xhigh` (`none` is excluded).
  These are the CLI's levels, not every value accepted by Cline's shared SDK.

Introducing lines renamed the slugs that embedded a version. Model-level claim
labels are created on demand, so the renames change only the names of future
labels. Where an old label exists in a repository, rename it to the new name;
GitHub keeps the issues attached through a rename. Where several old labels
merge into one new name, rename the first. For each of the others, relabel its
issues with the new name and then delete the old label: a rename to a name that
already exists fails.

| Old label | New label |
| --- | --- |
| `claim:mai:code-1-1-flash` | `claim:mai:code-flash` |
| `claim:mai:thinking-1` | `claim:mai:thinking` |
| `claim:deepseek:v4-1-flash`, `claim:deepseek:v4-flash` | `claim:deepseek:flash` (merged) |
| `claim:deepseek:v4-pro` | `claim:deepseek:pro` |
| `claim:glm:5-3`, `claim:glm:5-2` | `claim:glm:glm` (merged) |
| `claim:glm:5-3-flash`, `claim:glm:4-7-flash` | `claim:glm:flash` (merged) |
| `claim:kimi:k3` | `claim:kimi:k` |
| `claim:minimax:m3` | `claim:minimax:m` |
| `claim:gemini:3-1-pro` | `claim:gemini:pro` |
| `claim:gemini:3-8-flash`, `claim:gemini:3-7-flash`, `claim:gemini:3-6-flash` | `claim:gemini:flash` (merged) |
| `claim:gemini:3-5-flash-lite` | `claim:gemini:flash-lite` |
| `claim:mistral:medium-3-5` | `claim:mistral:medium` |
| `claim:mistral:small-4` | `claim:mistral:small` |
| `claim:mistral:devstral-small-2` | `claim:mistral:devstral-small` |

The Claude, GPT and Qwen line slugs did not change.

<!-- registry-tables:begin -->
<!-- Generated from agent-registry.json by `node scripts/agent-registry-labels.mjs docs-tables`. Do not edit by hand — `task test:registry-docs` fails on drift. -->

#### Model families

| Family | Name | Model lines (current version) |
| --- | --- | --- |
| `claude` | Claude | `fable` 5.1, `opus` 5.5, `sonnet` 5.5, `haiku` 5.5 |
| `gpt` | GPT | `astra` 6.1, `sol` 6.1, `terra` 6.1, `luna` 6.1 |
| `mai` | MAI | `code-flash` 1.1, `thinking` 1 |
| `qwen` | Qwen | `max` 3.8, `coder-plus` 3, `coder` 3, `flash` 3.8, `coder-next` 3, `coder-30b` 3 |
| `deepseek` | DeepSeek | `flash` 4.1 (retired 4), `pro` 4 |
| `glm` | GLM | `glm` 5.3 (retired 5.2), `flash` 5.3 (retired 4.7) |
| `kimi` | Kimi | `k` 3 |
| `minimax` | MiniMax | `m` 3 |
| `gemini` | Gemini | `pro` 3.1, `flash` 3.8 (retired 3.7, 3.6), `flash-lite` 3.5 |
| `mistral` | Mistral | `medium` 3.5, `small` 4, `devstral-small` 2 |

`Model selected by` values:

- `runner-config` — the runner or repository/CLI configuration selects the model; labels do not.
- `workflow-config` — the GitHub Actions workflow input selects the model.
- `provider-wrapper` — the provider-rewired wrapper fixes the family; its runtime configuration selects the model.
- `harness-runtime` — the harness selects the model at runtime; for broker harnesses it selects the provider family too.

#### Harnesses

Effort ladder: `minimal` < `low` < `medium` < `high` < `xhigh` < `max`.

| Harness | Product | Family | Foreman adapter | Model selected by | Efforts |
| --- | --- | --- | --- | --- | --- |
| `claude-code` | Claude Code CLI | `claude` | `foreman:claude` — production, dispatchable | `runner-config` | `low`, `medium`, `high`, `xhigh`, `max` |
| `claude-code-action` | claude-code-action | `claude` | — | `workflow-config` | `low`, `medium`, `high`, `xhigh`, `max` |
| `claude-code-deepseek` | Claude Code provider wrapper | `deepseek` | `claude-code-deepseek` — production, not dispatchable, no label | `provider-wrapper` | `low`, `high`, `max` |
| `claude-code-glm` | Claude Code provider wrapper | `glm` | `claude-code-glm` — production, not dispatchable, no label | `provider-wrapper` | — |
| `claude-code-kimi` | Claude Code provider wrapper | `kimi` | `claude-code-kimi` — production, not dispatchable, no label | `provider-wrapper` | `low`, `high`, `max` |
| `claude-code-minimax` | Claude Code provider wrapper | `minimax` | — | `provider-wrapper` | — |
| `claude-code-qwen` | Claude Code provider wrapper | `qwen` | — | `provider-wrapper` | — |
| `claude-code-qwen-local` | Claude Code provider wrapper | `qwen` | — | `provider-wrapper` | — |
| `codex-cli` | OpenAI Codex CLI | `gpt` | `codex-cli` — production, not dispatchable, no label | `runner-config` | `minimal`, `low`, `medium`, `high`, `xhigh` |
| `copilot-cli` | GitHub Copilot CLI | any (multi-provider; default `mai`) | — | `harness-runtime` | `low`, `medium`, `high`, `xhigh`, `max` |
| `qwen-code` | Qwen Code CLI | `qwen` | — | `runner-config` | `low`, `medium`, `high`, `xhigh`, `max` |
| `antigravity` | Google Antigravity | `gemini` | — | `harness-runtime` | — |
| `opencode` | OpenCode | any (multi-provider) | — | `harness-runtime` | `minimal`, `low`, `medium`, `high`, `xhigh`, `max` |
| `pi` | Pi | any (multi-provider) | — | `harness-runtime` | `minimal`, `low`, `medium`, `high`, `xhigh`, `max` |
| `oh-my-pi` | Oh My Pi | any (multi-provider) | — | `harness-runtime` | `minimal`, `low`, `medium`, `high`, `xhigh`, `max` |
| `goose` | Block Goose | any (multi-provider) | — | `harness-runtime` | `low`, `medium`, `high`, `max` |
| `cline` | Cline | any (multi-provider) | — | `harness-runtime` | `low`, `medium`, `high`, `xhigh` |
<!-- registry-tables:end -->

## Claiming — making an agent's work visible while it happens

An issue being worked on *right now* is the one fact the tracker holds worst.
The assignee is buried on the issue page and a claim comment is one entry in a
thread — neither shows on the board, which is where work is actually watched.
So two agents, or an agent and a human, start the same issue because nothing
visible said it was taken.

An agent starting work therefore writes every one of these it *can*, because
each is blind where the others see:

| Signal | Answers | Shows up in |
|---|---|---|
| `Status` = `In Progress` | where it is in delivery | the board |
| claim label (`claim:*`; `agent:*` pre-migration) | which agent is working it **right now** | the issue page, `gh issue list --label` |
| assignee | that *someone* has it | notifications, `gh issue list --assignee` |

**The Tier is not on that list, and a claim must not write it.** The two
look like the same fact and are not:

| | Means | Set by | When |
|---|---|---|---|
| **`tier:*`** label | which stratum of agent the issue *should* run at | whoever writes its Risk and Complexity, or a human who pins it | at classification, before the work starts |
| **`claim:*`** label | which agent family *is* implementing it | the agent itself | at claim, released at hand-off |

They answer different questions. Rewriting the Tier at claim time would
destroy the classification, and would silently reassign work classed for one
stratum to whichever agent happened to pick it up.

So a claim writes the **claim label only**. If the claim and the Tier
disagree, that is information, not drift: it means a different agent picked up
work classed for another stratum. Worth noticing, not worth auto-correcting.

Both being labels, the model works identically on both owner types — there is
no org issue field in the claim path for the Projects V2 API to be unable to
write.

**A board write can fail without anyone learning.** Every `Status` write in the
lifecycle needs the [`project` scope](#token-scopes). Without it each one exits
2 — "could not verify" — and the steps handle that correctly *individually*:
it is an auth condition they cannot fix, so they note it and carry on. In
aggregate that is the worst outcome available. The agent reports the issue
claimed, the board says nothing was ever started, and neither is wrong from
where it stands; the hand-back then cannot restore a prior status it was never
able to read. Nothing in the loop escalates, so the board silently stops
tracking agent work in **both** directions until a human happens to notice it
has gone stale. Check the scope at session start (`task status:gh`), not after
the claim.

**How much a claim prevents depends on who is reading it.** The label is one
string, but it has two very different consumers:

- **Interactive sessions — a signal, not a lock.** None of these writes is
  atomic, and two sessions running as the same GitHub user are invisible to
  each other: the assignee converges, the label is idempotent, and the field is
  last-writer-wins. A claim makes concurrent work discoverable by a human; it
  does not prevent it.
- **The Claude Actions workflows — a fail-closed gate.** A run refuses to
  start on a target that already carries any `claim:*` or `agent:*` label, and
  says which one. That is enforcement, not advice, and it is why a stale claim
  blocks mentions on that issue until somebody removes the label.

The gap between the two is deliberate rather than unfinished: a workflow run
has one entry point to gate, while an interactive session can start anywhere,
so promising a lock there would be a promise the mechanism cannot keep.

**A claim must be released.** `In Progress` left on finished or abandoned work
is worse than no signal, because the next reader believes it. The lifecycle
follows the pipeline honestly — `In Progress` at claim, `Verifying` while CI
runs, `In Review` awaiting a human, `Ready to Merge` only once actually
approved, and never `Done`, which belongs to whoever merges.

**A session cannot be relied on to release it.** The release is owed after the
merge, and no session is guaranteed to witness that: `/shepherd` stops before
the merge on policy, so the session that claimed the issue is usually over by
the time a human merges. `.github/workflows/claim-release.yml` is the release —
on `issues closed` (by any means) and on `pull_request closed` **unmerged**, it
undoes what the claim record says the claim added and posts the `Claim
released —` supersede comment. It needs no secret beyond `GITHUB_TOKEN`.

The contract it parses — and the accepted gaps, including the merged-PR and
fork-PR cases it deliberately does not cover — is
[`claim-lifecycle.md`](../.claude/skills/track-work/references/claim-lifecycle.md)
in the vendored `track-work` skill.

> **Whether this is automatic depends on the skills vendored here.** Writing
> and releasing these markers is implemented by harmon-devkit's `claim` /
> `shepherd` / `wrap` skills; older releases only assign the issue, and the
> three were named `preflight` / `shepherd` / `close` before harmon-devkit
> v0.21.0. The pin moves on its own schedule via `sync-harmon-devkit.yml`, so
> check rather than assume:
>
> ```sh
> grep -rlE 'claim:claude|agent:claude-code' .claude/skills/claim/ .claude/skills/wrap/
> ```
>
> Both vocabularies are matched on purpose: the skills moved from the retired
> `agent:*` family to `claim:*` in harmon-devkit v0.23.0, and a pin older than
> that automates claiming just as well under the old name — so probing for one
> name alone reports half the supported pins as un-automated.
>
> A match means claiming is automated end to end. No match means the claim
> labels above are applied by hand, and no *skill* will move the card. On an
> organization `project-automation.yml` still syncs `Status` from PR and CI
> events, so that is not the same as nothing moving it — check what the
> workflow already does before setting the field manually.

### The Claude Actions workflows

`claude-plan.yml`, `claude-implement.yml`, and `claude-review.yml` run Claude
Code on an issue or PR from inside GitHub Actions. Three properties define how
they start, and all three exist because of the label boundary above.

**Mention-only.** The single way a run starts is a comment or review body that
carries an `@claude` mention followed by `plan`, `implement`, or `review`.
There is no label trigger, no `issues: opened`, and no `issues: assigned`
trigger. Every one of those was retired: they carry no actor the workflow can
check on every path, and the labels that used to drive them are gone.

**Sender-gated.** The mention only counts from a login on the workflow's
authorized-sender allowlist. The allowlist answer is not the whole list: the
review workflow additionally authorizes `renovate[bot]` and `dependabot[bot]`
as senders, so their update PRs can request their own reviews — treat those
fixed bot principals as part of the trust surface when auditing. The allowlist
is checked twice — in the job `if:`, and again in a token-free step that
re-asserts it *before* any App token is minted — so a gap in the expression can
never mint a credential.

**Claim-aware, fail-closed.** After the sender gate passes and before the token
is minted, the run acquires `claim:claude` on the target:

| Situation | What the run does |
|---|---|
| Target is unclaimed and the label lands | claims it and runs |
| Event has no issue or PR number | runs unclaimed — there is nothing to collide with |
| Target already carries any `claim:*` or `agent:*` label | **refuses**, naming the held label and the remedy |
| The label list cannot be read | **refuses** — it cannot prove the target is free |
| The label will not apply | **refuses** — it would work the target unmarked |

Only ownership labels count (`claim:*` and the legacy `agent:*`): the Tier
(`tier:*`) and the other classification labels are advice about who *should* do
the work, never ownership of it, so they are deliberately not matched. The `claim:claude` label is created if the repository
does not have it, with the registry's own color and description, so a later
`task setup:github-labels` reconciles that label instead of fighting it.

Release is loud, and bounded. An `always()` step releases the claim — but only
when *this* run acquired it, so a claim that was already there is never stolen.
It covers the failure, step-timeout and cancellation paths, which is why the
model step carries a cap well inside the job's: a job-level timeout kills the
runner outright and the cleanup never runs at all. A release that cannot be
confirmed retries once and then turns the job **red** with the marker still on
the issue, because a release reported as successful over a surviving label
would be permanent — the next run reads the claim, records that it did not
acquire it, and never cleans it either.

It is not a guarantee. Runner loss, a force-cancel, or the job cap firing can
strand `claim:claude` with no cleanup at all, and a stranded claim blocks
further mentions on that target until somebody removes the label by hand. That
residual is accepted rather than reconciled by a workflow of its own.

Because acquiring is a read-then-add, the three workflows share one job-level
`concurrency` group keyed on the target number, so two runs on the same issue
serialize instead of both reading "unclaimed". The group is job-level rather
than workflow-level on purpose: these workflows fire on every comment event and
filter in the job `if:`, so a workflow-level group would let ordinary comments
queue up and displace legitimate runs.

## Milestones

A milestone has **one job — "which finite, shippable batch is this part of?"** —
and nothing else. Four things
could all masquerade as milestones, so keep the lanes clean:

- **Type** — what kind of work (Bug / Feature / Task / Research)
- **Status** — where it sits in the pipeline
- **Labels** — orthogonal, cross-cutting concerns
- **Sub-issues** — hierarchy

None of those answers *"which shippable batch does this belong to, and how done
is that batch?"* — that's the milestone's unique contribution: a finite
delivery container with a **live completion bar** and, when useful, a due date.
Labels are for classification; milestones are for goal tracking. An open-ended
concern with no completion condition is still a label or saved view.

Use one of two explicit milestone naming modes:

- **Version milestone** — for a product release planned as a version, make the
  title equal the git tag (`v1.0.0`, `v1.1.0`). The milestone is the pre-ship
  "what must land before this version" artifact; release-please is the post-merge
  machine that calculates and cuts the actual version from conventional commits
  (see [conventions.md](conventions.md)). The shipped
  `close-milestone-on-release.yml` Action closes the milestone matching a
  published tag, and the release PR can carry it too.
- **Scope-batch milestone** — for a rolling-release or tooling repo where
  versions are outputs rather than planning inputs, name the finite outcome
  (`Issue strategy overhaul`, `Runner hardening`). It may span several releases;
  close it when its scoped issues are complete. Release-please continues to
  version each shipped increment independently, and the tag-matching Action
  intentionally does not close a non-version milestone.

Do not mix the two modes in one title or invent a version for work whose version
is not known yet. **Carry one active delivery milestone per stream** — create it
when it has real scope, close it when that scope ships, and open the next only as
needed rather than keeping speculative batches in competition.

**Due dates are signals, not gates.** A milestone's due date is optional, does
not block a merge or close, and triggers nothing. Add one when a collaborator
needs a timing signal and update it honestly when the plan slips; the milestone's
scope and completion bar remain useful without a fabricated date.

## Milestones over iterations

For pre-launch product development, lead with **milestones, not iterations**
(sprints). The mechanisms differ in what they fix vs. flex:

- **Iterations fix time, flex scope** — the window ends Friday, you ship whatever's
  done.
- **Milestones fix scope, flex time** — you ship when the thing is done; the date
  is a signal.

Early product work needs to **fix scope**: a half-built product at an arbitrary
time-box boundary isn't shippable value — "ship it when it's good enough to charge
for" is a scope commitment, not a time one. Here the milestone's commitment shape
is right and the iteration's is actively wrong.

**Incremental delivery doesn't come from either mechanism** — it comes from **small
slices + frequent deploys + a release cadence**, which you already have (PR-sized
sub-issues, per-PR previews to prod, release-please cutting incremental releases
from accumulated commits). You can sprint and ship zero user value, or run
milestones and ship continuously; the delivery job routes through the *release*
mechanism (milestone-adjacent), not sprints.

**So run small, frequent milestones** — a shippable chunk every ~2–4 weeks, not one
giant "Launch." A tightly-scoped milestone with a target date is a chunk of value
with an expectation attached, doing three jobs at once: coordination (toward
shippable scope), commitment (to that scope; date as signal), and incremental
delivery (frequent small releases). It's literally the release-please flow —
**small frequent milestones == frequent delivery batches** — so it's one rhythm,
not two, even when a rolling-release repo cuts several versions inside one
scope-batch milestone.

**Get the forcing-function from tools you already have,** not a sprint clock: a
**WIP limit** on `In Progress`, sub-issues **sized to one PR**, and continuous
deploy — anti-drag pressure applied at the work slice, not a calendar boundary a
tiny team can't make hard anyway.

**Why this phase picks milestones:** early development is **discovery-driven** —
you're figuring out scope as you go, capacity is erratic, and the priority is
shipping the *right* thing, not a predictable amount. Iterations shine in the
opposite regime (a known backlog, steady team, predictable capacity metered at a
constant clip) — steady-state maturity, not pre-launch. (Honest counter:
time-boxing can curb rabbit-holing during discovery — but the Lean answer is
build-measure-learn, get it in front of a user fast, for which the clock is your
**deploy cadence**, not a two-week sprint; and a WIP limit plus one-PR slices curb
it at the work level more directly. You already have those.)

**Iterations also don't fit the agent queue.** Agents run when triggered, not "this
week"; scoping the queue to `iteration:@current` adds nothing over its own
predicate in [Views](#views). Iteration is a human-cadence concept your agents
don't have.
(The native Iteration field stays available if you reach steady-state and want it.)

## Hierarchy (sub-issues with Epic and umbrella labels)

There's **no Epic type, by design.** GitHub **sub-issues** are the authoritative
*hierarchy* axis, and **milestones** are the *delivery-batch* axis. The durable
`epic` and `umbrella` labels describe a parent issue's horizon; they do not
create membership, rollups, or inheritance. A
**sub-issue inherits its parent's Project and Milestone by default** (shipped
2025-09). Assign them once on the parent and the child tree picks them up — no
per-child bookkeeping.

Use **`epic`** for a parent with a finite, time-bound deliverable. It may belong
to a milestone, whose completion bar and optional due date remain the source of
delivery tracking. Use **`umbrella`** for a perennial parent that covers an
enduring area, topic, or team and has no single delivery endpoint. An issue is
one or the other, never both; both normally gain sub-issues over time.
`umbrella` also marks the human-task and QA collectors described at the end of
this section, which gather work rather than decompose it.

So a parent issue "Scheduling v1" in milestone `v1.1.0` pulls its whole subtree
into that release payload for free. Break big work down with **sub-issues** (up to
8 levels — flip on **Show hierarchy** in a view to expand/collapse the tree)
rather than a markdown checklist: the `epic` label names the finite parent role,
while the native relationship carries the structure.

**Sub-issues are your only membership axis; everything else stays flat.** Type,
Status, milestone, labels, and fields must never try to encode "part of" — that's
the sub-issue's job, and only that. `epic` and `umbrella` are metadata on the
parent, not substitutes for the relationship. Once that's clear, the rest is just
sizing and deciding what metadata rides on the parent vs. the leaves.

**The common finite-delivery shape:** a **milestone** (the cross-feature
shippable batch — possibly-unrelated work) contains `epic`-labelled parent
**Feature** issues (each a cohesive capability), each of which contains **Task**
sub-issues (mergeable slices). An `umbrella` can instead hold a perennial
subtree without inventing a date or deliverable.

The boundary that trips people up: **a milestone is a flat batch of unrelated
features targeting one delivery outcome; a parent issue is one cohesive thing
decomposed.** So
don't build a giant "Launch" parent with 40 sub-issues spanning unrelated features
— that's exactly what the milestone is for. Milestone for the cross-feature
batch; the parent-issue tree for a single feature.

**Where metadata lives — parent vs. leaf.** The **parent** holds the durable
context: the spec (your Given/When/Then acceptance criteria), the "why," the
explicit *not*-doing reasoning, the `epic` or `umbrella` label, and — since
sub-issues auto-inherit it — the **milestone and project** assignment. Set the
milestone and project once on the parent and the tree inherits; move the parent
to `v1.1.0` and the whole tree moves with it. Keep the initiative label on the
parent; never set the milestone per child.

The **leaves** hold execution: the `Task` type.
It's route-not-duplicate applied to hierarchy: a child references the parent's spec
rather than restating it, and reads up for context.

**Sub-issue vs. task-list checkbox.** Markdown `- [ ]` task lists still have a
place. The rule: if an item needs its own **status, assignee, or independent
scheduling**, promote it to a **sub-issue**; if it's just "steps to finish this one
issue," leave it a **checkbox** in the body. Don't promote every checkbox (that's
sprawl), and don't spin up a sub-issue where a checkbox suffices.

**Research child as a blocking gate.** When a Feature has an unknown, spawn a
**Research** sub-issue and let it *block* the implementation children. It closes
when it produces a decision record (the Research closure rule), which unblocks the
rest — encoding "figure this out first, then build" in the tree itself, and tying
Research, sub-issues, and the ADR discipline together.

**Hierarchy is not dependency.** A sub-issue means *"part of,"* not *"must happen
before."* If A must finish before B but B isn't part of A, that's a **dependency**
— the native blocked-by relationship, or the `blocked` label + a note (see
**Blocked is not a status** above) — not a parent-child link. Conflating them
corrupts the tree; keep composition (sub-issues) and sequencing (dependencies) in
separate mechanisms.

**Human-task and QA collectors.** Long-running work — a milestone or an `epic`
— usually needs things only a human can do: set a secret, flip a GitHub or
vendor setting, approve an account, try the feature by hand. Written as
required `[HUMAN]` criteria on the issue that surfaced them, each one parks
that issue: a `Closes #N` fails the closing-keywords check while a box is
unticked, and an orchestrated run stalls on a human who deliberately circles
back later. Collect them instead on two kinds of dedicated issue, which differ
in scope:

| | `(HUMAN): <outcome>` | `(QA): <outcome>` |
|---|---|---|
| Collects | human **actions** — credentials, settings, accounts, approvals, purchases, decisions | human **verification** — hands-on, exploratory, or acceptance testing of what shipped |
| Scope | one per milestone or `epic`, plus one repo-wide for unscoped work | **one per repository** — the standing QA role or team |
| Placement | in its milestone, and a sub-issue of its `epic` | in no milestone and under no parent; milestones and epics link to it |
| Lifecycle | closes when every item is ticked | stays open; its checklist is the running QA queue |
| Labels | `human` + `umbrella`, plus the usual classification and provenance labels | same |
| Type | `Task` — native Issue Type on org repos, the `task` label on personal repos | same |
| Example | `(HUMAN): Complete manual setup for v1.2 remote environments` | `(QA): Verify shipped work by hand` |

- **Find it before filing it.** Each collector's `## Provenance` carries one
  stable scope line: `Collector scope: milestone <number>`,
  `Collector scope: <owner/repo>#<epic>`, or `Collector scope: repository`
  for a `(HUMAN):` collector, and always `Collector scope: repository` for
  the `(QA):` issue. Search all states (`label:human label:umbrella`) and
  match on the title prefix plus that scope line: append to the open one,
  reopen a closed one, and never file a second. Whoever meets the first
  human task files it **lazily**, human or agent. Two writers can still both
  miss and both file, so whoever finds two open collectors for one scope
  merges the newer's items into the older, repoints each moved item's
  source line at the older, and closes the newer as a duplicate.
- **`(HUMAN):` follows the work.** Its scope is the source issue's
  milestone; failing that, its `epic`; failing both, the repository. Give it
  that milestone, and under an `epic` also make it the epic's sub-issue so
  the epic's rollup stays honest about the human work still owed. An epic's
  `(HUMAN):` collector lives in the epic's repository, and sources in other
  repositories cite it as `owner/repo#N`. An item stays on the collector it
  was filed to even if its source later changes scope, and the collector
  closes when every box is ticked.
- **`(QA):` is a role, not a batch.** Each repository has exactly one,
  standing for its QA role or team. It is never given a milestone, never
  made a sub-issue, and stays open when its items are all ticked. Milestones
  and epics reference it — a link in their body, or `Refs` — rather than
  containing it, and an item can name the milestone or epic it verifies:
  `- [ ] [HUMAN] Verify remote environments end to end (from #1412, v1.2)`.
  A cross-repo epic's QA items go to each source repository's own `(QA):`
  issue.
- **Each task is one `- [ ] [HUMAN] …` acceptance criterion on its
  collector**, naming its source:
  `- [ ] [HUMAN] Add FLY_API_TOKEN to the repo secrets (from #1412)`, with
  the source written `owner/repo#N` when it lives in another repository.
  Agents append items; a human ticks them.
- **The source issue mentions, never blocks.** Record the task on the source
  issue as a plain line under `## Out of scope` —
  `Human follow-up (tracked in #1420): add FLY_API_TOKEN` — not as an
  acceptance criterion, so the issue closes as soon as its agent-verifiable
  work merges. That line is the durable record and the collector item is its
  index: an issue-body edit is last-write-wins, so two concurrent appends can
  drop one item, and the source line is how a later pass finds it again.
- **A precondition is a dependency, not a follow-up.** When the agent cannot
  do the work until the human step happens (the secret must exist before the
  deploy test can run), the step is not a collector item: file it as its own
  `human` issue and give the source issue a blocked-by edge on it (see
  **Hierarchy is not dependency**). Closing the human issue unblocks the work
  through the same graph the dispatchers read.
- **Never dispatched.** A `human` issue is never claimed, armed with
  `foreman:*`, or implemented by an agent while it carries the label. Triage
  may remove `human` only when the issue no longer qualifies (non-collector,
  no `[HUMAN]` majority, agent-completable; every removal is reported — see
  **Human work** above). Do not rely on tooling to stop it — Foreman, for one,
  does not read the label — so never arm one. `human` alone marks a standalone
  issue whose completion is primarily a human's, such as a precondition;
  `human` + `umbrella` marks a collector.

## Cross-repo work

The one board already spans every repo (the single default project per owner). For
work that *itself* crosses repos, reach for the tree, not a new field:

**A cross-repo feature → a parent sub-issue tree. No field needed.** A feature that
touches app + infra + marketing is one cohesive thing, so it's a legitimate parent:
the parent **Feature** issue lives in the app repo, its **Task** children live in
whichever repos they belong to (sub-issues cross repos freely), and the parent's
rollup counts completion across all of them. The tree *is* the cross-repo grouping
— you track it by opening the parent, not by tagging a field.

**A cross-repo *release* is mostly a smell.** Repos with genuinely independent
deploy cadences shouldn't share a release: the app cuts versions via release-please
on its own rhythm, an Astro marketing site deploys continuously on copy changes,
infra changes when infra changes. Forcing "app v1.1.0 + a pricing-page edit + a
terraform tweak" into one dated cross-repo release invents coordination the
independent cadences don't need. What legitimately spans repos is **features, not
releases** — so the flat cross-repo batch a milestone structurally can't hold (and
that a field would exist to solve) mostly shouldn't exist.

**The one genuine exception: a coordinated launch.** An initial public launch
really does need app-live + marketing-up + infra-provisioned at once — a real
cross-repo dated batch. Even then, model it as a single **Public Launch** parent
tracking issue with cross-repo sub-issues, not a new field: it's a one-time event,
not a recurring dimension worth a permanent field on every issue forever.

## Views

Views (the board's tabs) **can't be created via API** — Projects V2 exposes no
view mutations, only reads — so create these once in the UI (**Project → New
view**). Keep the saved set small; **slice the one board** (below) for the rest.

- **Board** — board, `is:open`, grouped by `Status`. The day-to-day working board.
- **Triage** — table, filtered to `is:issue is:open` and the **`needs-triage`**
  label, grouped by **Type** (Bug / Feature / Task / Research) so you see the
  shape of the inbox.
  `needs-triage` is derived — present while any required axis is unset — so one
  label filter selects every untriaged issue; there is no "missing a field"
  clause to OR beside it, which Projects cannot express (#444). `Type` is an
  organization issue field; a personal account has no `Type` to group by (its
  work-type is a label, which a view can filter on but not group by), so leave
  the view ungrouped there. This is your grooming session — it exists so
  untriaged work can't hide; empty it regularly and it stays useful.
- **Agent queue** — the issues an agent may start. The **predicate** is
  authoritative: **open**, **triaged** (no `needs-triage`), no ownership label (**`claim:*`** or a legacy **`agent:*`** alias), not
  **`human`**, not **`needs-review`**, not blocked, and **`Priority` set** — an
  issue with only a `Priority (AI)` is not startable, an agent asks first
  ([ADR 2026-09-30](decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
  D7). `Status` plays no part in it. **Not blocked** means neither an open
  blocked-by relationship nor the `blocked` label. **Order** is by `Priority`,
  highest rung first (`urgent`, `high`, `medium`, `low`), then by
  `Priority (AI)` (`p0` to `p4`) within a rung. **The human `Priority` overrides
  `Priority (AI)`**: an issue's effective priority is `Priority` when set, else
  `Priority (AI)`, and the override never clears the AI value
  ([ADR 2026-10-01](decisions/2026-10-01-add-a-priority-ai-axis-suggested-by-agents.md)
  D2). In the queue `Priority` is always set, so `Priority (AI)` only breaks ties
  within a `Priority` rung; it admits nothing, and the view shows it. A saved
  view only approximates the predicate. It filters on `is:issue` and `is:open`
  (auto-add puts pull requests on the board too). Projects label filters match
  **concrete** values, not prefixes, so it excludes `blocked`, each registered
  `claim:<family>` label, each `claim:<family>:<model>` refinement label in use
  (a model-level label on its own is still a live claim, one an older claim left
  behind, since current claims always apply the family label too), and each
  legacy alias the registry lists (`legacy_claim_labels` in
  `agent-registry.json`, such as `agent:claude-code`) by name (extend the filter
  when the registry gains a family). It cannot express the native blocked-by
  relationship, so with respect to native blocks
  the view is a superset of the predicate: whoever takes an item first confirms
  it has no open blocked-by (the issue's `blockedBy` data, see
  [Blocked is not a status](#blocked-is-not-a-status)); making the claim step
  refuse such an issue is tracked as harmon-devkit#1232. Where the priorities
  live decides how the view is built and how the order is applied:
  - **Organization** — both are issue fields, so the one view requires
    `Priority` set and sorts by `Priority`, then `Priority (AI)`.
  - **Personal account** — both are labels (`priority:*`, `priority-ai:*`), and a
    view cannot sort by a label, so the human order is applied by narrowing the
    queue view itself to one rung at a time. The view filters on the four
    concrete `priority:*` labels in one `label:` qualifier (the comma ORs them);
    narrowing replaces that qualifier with one concrete label, walking
    `priority:urgent`, `priority:high`, `priority:medium`, `priority:low`. Within
    a rung, order by the `priority-ai:*` label read from the Labels column. Every
    other exclusion is the view's own filter, so it is kept by construction.
- **Human queue** — table, `is:issue is:open`, the **`human`** label, and
  excludes `blocked`. On an organization it shows the `Priority` and
  `Priority (AI)` columns and sorts by `Priority`, then `Priority (AI)`. On a
  personal account both priority families are labels, so apply the order the way
  the Agent queue does: narrow the view to one `priority:*` label at a time, then
  to issues with no `priority:*` label (a filter that excludes the four
  `priority:*` labels by name), and within each step order by the
  `priority-ai:*` label read from the Labels column (see the Agent queue's
  narrowing walk above). It cannot express the native blocked-by relationship,
  so with respect to native blocks the view is a superset of startable human
  work and whoever takes an item first confirms it has no open blocked-by (the
  issue's `blockedBy` data, see [Blocked is not a
  status](#blocked-is-not-a-status)).
- **Needs review** — table, `is:issue is:open` and the **`needs-review`**
  label. On an organization it shows the `Priority` and `Priority (AI)` columns
  and sorts by `Priority`, then `Priority (AI)`. On a personal account both
  priority families are labels and share the single Labels column, where both
  priority labels appear, so it shows that column and is read by effective
  priority (a view cannot sort by a label). It lists what awaits the
  maintainer: the integration stage adds `needs-review` at ready-for-review and
  removes it if review pulls the work back into fix rounds. Until that writer
  ships (harmon-devkit#1255, with a skills-pin bump), add `needs-review` by hand
  at hand-off (and remove it by hand if review sends the work back into fix
  rounds), or a handed-off issue (its claim released) shows in the Agent queue
  again.
- **Planning** — table, grouped by **`Product`** (or `Type`, on an organization), sorted by
  `Priority` (organization only, as above). The "what's the plan" view, and a
  **dates-free roadmap substitute**: grouping by product shows the pile behind
  each one without maintaining a timeline. There is no `Size` sum — the field is
  retired (it was a project **number** field, the one kind GitHub sums in a
  group header) and nothing replaces it here.
- **Mine** — table, `is:open assignee:@me`, sorted by `Priority` (organization
  only, as above).

### Two toggles, not more views

- **Show hierarchy** (sub-issues — public preview) — expands/collapses sub-issues
  up to 8 levels while still grouping, slicing, sorting, and filtering. Flip it on
  in the Board or Planning view for the parent-with-children rollup you'd
  otherwise reach for an Epic type to get — the payoff of choosing **sub-issues
  over Epics**: structure without the "Feature or Epic?" tax. Still preview, so
  expect rough edges.
- **Slice the board** — rather than a separate saved view per product, slice
  the one board by **`Product`** (still a field, so a view can group by it).
  One board, many lenses — how multiple products stay legible in one
  aggregating project instead of fragmenting into project-per-product. Domain
  and Layer are labels only (#875): a view can still **filter** on
  `domain:*`/`layer:*` (add the label to the view's filter), it just cannot
  **group** by them the way a field allows — same as the agent split, which is
  a label question too (`tier:*`/`claim:*` — filter, don't slice).

## Notes

- **Labels vs Type** — `Type` is a first-class, org-level issue field
  (Bug / Feature / Task / Research), separate from labels (see **Labels** above);
  don't reproduce it as a label.
- **Owner**, **Iteration/cycle** — additional fields/axes as the work needs them
  (**Milestones** have their own section above).
- An issue can belong to **multiple projects** — the org project plus a focused
  one is fine.
