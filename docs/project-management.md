# Project Management

How work is tracked for Harmon Init in **GitHub Projects**.

## One default project per owner

The standard strategy is a single default GitHub **Project (V2)** per owner — one
board for the organization, or (for personal-account repos) one for the user
account — titled after the owner's GitHub login: `<owner> Project` (here:
**evanharmon1 Project**; e.g. `harmonops Project`, `evanharmon1 Project`).
Every repo the owner controls feeds that one board; an issue can belong to
multiple projects, but this default board is its home. Reach for a second,
focused project only when a body of work needs its own.

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
- On a raw close event, check `state_reason == completed` before setting Done.

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

TODO: finalize exactly what to automate. The intended event → status shape:

- New issue → **Inbox**
- Branch/PR started → **In Progress**
- PR opened → **In Review**
- Deployment complete → verification (if applicable)
- Issue closed (`state_reason == completed`) → **Done**
- 90 days in Done → **auto-archived** off the board (native built-in, not a Status)

## Fields

`Status` is a **Project field** — the board pipeline above; it stays on the
project because the built-in workflows (and `project-automation.yml`, on an org)
drive it.

The work-metadata fields:

- **Priority** — Urgent / High / Medium / Low
- **Effort** — size / estimate (XS…XXXL)
- **Product** — which product/area it belongs to (free text)
- **Agent** — which agent should implement it (Claude Code, Codex, Gemini CLI,
  Qwen Code, DeepSeek, Kimi K2, GLM, GitHub Copilot) and how (effort level, model)

On a personal account these are **project fields** (issue fields are org-only),
created alongside the board by `task setup:github-project`.

TODO: finalize each field's options/values.

## Labels

Labels are **repo-level** and orthogonal to `Status` (pipeline position) and
`Type` (kind of work) — they tag cross-cutting *facets*. Keep them in a few
families, color-coded by family; the starter set is created by
`task setup:github-labels`:

- **Concerns** — `sec`, `a11y`, `perf`, `tech-debt`, `i18n`, `l10n`
- **Source** — `customer-request`, `ai-generated`
- **Workflow** — `needs-triage`, `needs-requirements`, `blocked`, `waiting`,
  `needs-decision`, `needs-response`, `needs-communication` (transient triage
  states; `blocked` is the non-issue-blocker flag described above)
- **Layer** — `layer:frontend`, `layer:backend`, `layer:infra`, …
- **Domain** — start with `domain:auth`, `domain:billing`; grow from your ERD
  entities

GitHub labels live per-repository (there's no shared org label pool).
`setup-github-labels` seeds the set into one repo — run it in each, or set the
org's **default labels** (org Settings → Repository, UI-only) to seed *new* repos
(it won't change existing ones). It never deletes labels, so GitHub's defaults
remain until you prune them.

## Views

Views (the board's tabs) **can't be created via API** — Projects V2 exposes no
view mutations, only reads — so create these once in the UI (**Project → New
view**). Keep the saved set small; **slice the one board** (below) for the rest.

- **Board** — board, `is:open`, grouped by `Status`. The day-to-day working board.
- **Triage** — table, filtered to items **missing a `Priority`** or carrying
  **`needs-triage`**, grouped by **Type** (Bug / Feature / Task / Research) so you
  see the shape of the inbox. This is your grooming session — it exists so
  untriaged work can't hide; empty it regularly and it stays useful.
- **Agent queue** — board, filtered to issues whose **`Agent`** field is set,
  showing only the in-flight `Status` columns (**Ready, Agent Queue, In Progress,
  Verifying, In Review, Ready to Merge**), sorted by `Priority`.
- **Planning** — table, grouped by **`Product`** (or `Type`), sorted by
  `Priority`, with the **`Effort` field summed in each group header**. The "how
  big is the pile, and what's the plan" view, and a **dates-free roadmap
  substitute**: the per-group sum shows the weight behind each product without
  maintaining a timeline. (Group-header sums only work on a **number** field, so
  this wants `Effort` as points — a T-shirt single-select can't be summed.)
- **Mine** — table, `is:open assignee:@me`, sorted by `Priority`.

### Two toggles, not more views

- **Show hierarchy** (sub-issues — public preview) — expands/collapses sub-issues
  up to 8 levels while still grouping, slicing, sorting, and filtering. Flip it on
  in the Board or Planning view for the parent-with-children rollup you'd
  otherwise reach for an Epic type to get — the payoff of choosing **sub-issues
  over Epics**: structure without the "Feature or Epic?" tax. Still preview, so
  expect rough edges.
- **Slice the board** — rather than separate per-product / per-layer / per-agent
  saved views, slice the one board: by **`Product`** when you go multi-product, by
  **`layer:`** to focus a system layer, by **`Agent`** to see the split. One
  board, many lenses — and how multiple products stay legible in one aggregating
  project instead of fragmenting into project-per-product.

## Notes

- **Labels vs Type** — `Type` is a first-class, org-level issue field
  (Bug / Feature / Task / Research), separate from labels (see **Labels** above);
  don't reproduce it as a label.
- **Owner**, **Iteration/cycle**, **Milestone** — additional fields/axes as the
  work needs them.
- **Sub-issues** — break a large issue down natively instead of with a checklist.
- An issue can belong to **multiple projects** — the org project plus a focused
  one is fine.
