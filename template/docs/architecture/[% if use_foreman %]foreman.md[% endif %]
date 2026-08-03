# Foreman

Foreman is a **deterministic supervisor** for milestone-driven agent work. It
reads a milestone's (or a single issue's) dependency graph from GitHub,
dispatches the currently-unblocked issues to isolated headless agents in git
worktrees, verifies each result with the repo's own CI gate, opens PRs, and
keeps those PRs healthy (CI repair, review adjudication, rebases) until a
human merges them.

Everything that can be a crisp pass/fail check is plain code; LLMs write code
and adjudicate review findings, but they never judge "done" and never gate
progression. Zero tokens are spent on coordination.

## Non-negotiables

- **No AI ever merges to main. Ever.** No auto-merge, no enabling flag. The
  human merge is the only mechanism that advances the dependency graph;
  foreman's job ends at "this PR is verified, adjudicated, and has GitHub
  `mergeStateStatus=CLEAN` — here is the suggested merge order." Server-side enforcement (branch
  ruleset, code-owner review, bot token without bypass) is the boundary;
  prompts are only a mitigation.
- **Stateless in the repo.** Human inputs are stored (issue bodies, labels /
  issue fields, comments); machine state is re-derived every tick from GitHub
  - git and never stored. A stored status can lie after a crash; re-derived
  state cannot. Worktrees and `.foreman/` logs are disposable operational
  artifacts, never state-of-record.
- **Foreman never edits human-authored content.** Issue titles/bodies,
  milestone descriptions, and human/other-bot comments are read-only.
  Corrections travel as comments (human-approved), never as edits.

## The wave model

Nodes are dispatch units (a parent issue; its sub-issues ride along as the
internal task list — one unit, one PR). Edges are `blocked-by` dependencies
(native GitHub dependencies primary; a `Depends-on: #n` body trailer is the
fallback — both present and disagreeing fails loud).

A **wave** is the set of open units whose dependencies are all satisfied.
Because a satisfied dependency means *merged into the default branch by a
human*, every agent branches off the default branch with complete,
human-approved context — no stacked PRs, no cross-branch coordination. The
human merge advances the graph; the next run (or watch tick) discovers the
newly-unblocked wave. During a merge freeze foreman idles by design: PRs stay
healthy, nothing new dispatches, and the log says it is waiting on merges.

## Doneness (deterministic, hardened)

A dependency is satisfied only when:

- **Foreman-managed** (a closing PR carries the `foreman:unit=#N` marker):
  the issue is closed **and** that PR is merged into the discovered default
  branch, authored by the configured bot login, from a `foreman/...` attempt
  branch. A marker PR that never merged fails loud.
- **External** (no marker PR): the issue is closed as *completed*. Closed as
  *not planned* blocks, with guidance — remove the edge, or apply the
  explicit human override (`foreman=satisfied` field / `foreman:satisfied`
  label). Every plan/status output prints *how* each dependency was
  satisfied.

## Inputs (humans write, foreman reads)

Arming is **explicit by default**: only issues carrying the `foreman` input
dispatch. The value names the backend (`claude`, `mock`) or `approved` (repo
default backend); `hold` always wins; `satisfied` / `external` adjust
dependency semantics. Per-repo config can relax to default-armed
(`require_approval = false`), where invoking dispatch/watch is the arming
act and `hold` excludes units.

- **Org repos**: the org-level issue custom fields `foreman`,
  `foreman-budget-usd`, `foreman-timeout-min` (issue fields are org-only).
- **Personal-account repos**: `foreman:*` labels (boolean inputs only;
  numeric overrides need fields).
- `inputs = "auto"` probes availability once per run and prints the chosen
  mode in every summary. In fields mode, a `foreman:*` label on the same
  issue fails loud — two drifting sources of truth is a bug, not a feature.

A unit must also satisfy the **spec contract**: an `## Acceptance Criteria`
section with items tagged `[CI]` (must map to named automated tests) or
`[HUMAN]` (surfaced, never attempted; the PR then `Refs` instead of `Closes`
the parent). The conventional-commit type comes from the native issue type
(mapped via `type_map`) or a `type:` label on personal repos — disagreement
fails loud.

## Commands

All entry points are Taskfile tasks; each takes `-- --milestone <n|title>` or
`-- --issue <n>`:

```bash
task foreman:plan      # dry run: graph, waves, ready set, validation
task foreman:preflight # read-only agent spec analysis; drafts correction comments
task foreman:dispatch  # dispatch ready units → verify → open PRs (idempotent)
task foreman:shepherd  # repair CI, adjudicate reviews, rebase, merge order
task foreman:watch     # loop plan→dispatch→shepherd (-- --interval 5m)
task foreman:status    # read-only snapshot + human-action queue
task foreman:retry     # re-dispatch after a human closed a PR (-- --unit N)
task foreman:cleanup   # prune worktrees/branches for closed units
```

## Per-unit flow

1. **Skip if in flight** — an existing attempt branch or open PR means the
   unit is taken (derived, no state file). Held/un-armed units are skipped.
2. **Isolate** — `git worktree add` under `.worktrees/foreman/`, branch
   `foreman/<type>/<n>-<slug>` off the discovered `<remote>/<default>`.
3. **Prompt** — assembled deterministically: fixed preamble
   (`scripts/foreman/prompts/implementer-preamble.md`), the full issue +
   sub-issue bodies, **trusted** comments only (author association OWNER /
   MEMBER / COLLABORATOR, or foreman's own corrections — drive-by comments
   on public repos are an injection surface), and the `## Handoff` sections
   from merged dependency PRs.
4. **Dispatch** — the backend adapter runs headless in the worktree with a
   timeout enforced by foreman. The session ref is captured from the FIRST
   stream event (killed agents emit no final event; resume depends on this).
5. **Result contract** — the agent must write `result.json` (outside the
   worktree): status, summary, handoff, human tasks, proposed title, and the
   AC→test mapping. Exit 0 without a valid contract counts as a crash.
   Ambiguity escalates via `BLOCKED.md` + a blocked result — never invented
   through.
6. **Verify** — foreman itself runs the repo's `verify_command` (default:
   full `task ci`) in the worktree. The agent's self-report is never trusted.
7. **Freshness gate** — immediately before pushing: the issue is still open,
   still armed, dependencies still satisfied, the spec hash (bodies +
   trusted comments) unchanged since dispatch, and no PR appeared meanwhile.
   Drift means no push and a flagged unit.
8. **Draft PR** — the workbench (AGENTS.md, "Dev Loop"): machine-readable
   marker, `Closes #N` (or `Refs` when human tasks remain), test evidence,
   Handoff, and human-only-tasks sections. It stays draft until shepherd's
   readiness gate promotes it, so a non-draft foreman PR always means the
   automated work is finished. Configure review bots to review drafts
   (CodeRabbit: `reviews.auto_review.drafts: true`) or they will not see the
   PR while foreman can still act on their findings. On failure the worktree,
   session ref, and a generated resume-state are preserved; the issue stays
   open so dependents stay blocked.
9. **Status comment** — exactly one foreman-owned comment per unit, found by
   marker and edited in place. Display only; never read back for decisions.

## Shepherd

Deterministic triggers → bounded agent actions on open foreman PRs:

- **Red CI** → classify by the signature catalog
  (`scripts/foreman/signatures.toml`) first. `environment` failures get one
  empty-commit retry (the retrigger primitive — assume the bot token cannot
  re-run workflow jobs) and then the human queue; an agent must never "fix"
  infra by weakening code. `quota_wait` (the agent backend's own usage
  window) idles until reset. Mechanical failures resume the unit's agent
  with the failing excerpt.
- **Behind/conflicting after a sibling merge** → `git merge-tree` dry run
  enumerates conflicts; clean rebases are mechanical, conflicted ones go to
  the agent (rebase additively, regenerate generated artifacts via tooling,
  re-verify) — always rebase, never merge-main. `DRAFT` stands in front of both
  `BEHIND` and `DIRTY`, so the trigger does not trust `mergeStateStatus` alone:
  conflicts come from `mergeable=CONFLICTING` (computed independently of the
  draft flag) and staleness — which has no such field — from comparing the
  branch to its base (`behind_by`) whenever the PR is a draft.
- **Unresolved review threads** → the agent adjudicates each finding: apply
  (commit + reply + resolve) or decline with technical reasoning (bots are
  sometimes wrong; deterministic facts beat speculation). Blanket-accepting
  is prohibited. Foreman re-checks disposition completeness afterwards.
- **Readiness gate passes** → two transitions, gated identically but distinct in
  meaning:
  - **still a draft** → `gh pr ready` — the human handoff, reported as
    `promoted`.
  - **`mergeStateStatus=CLEAN`** → the `ready-to-merge` label plus a
    dependency-aware suggested merge order, reported as `ready`. A freshly
    promoted PR usually reports `BLOCKED` until a code owner approves, so only
    genuinely mergeable PRs enter that order.

  The merge state is tested as a **blocklist** (not `DIRTY`, `BEHIND`, or
  `UNKNOWN`), never an allowlist. `mergeStateStatus` is one value with a
  precedence order that the draft flag does not win: a draft reports `BEHIND`
  when its branch is stale and `BLOCKED` when the base ruleset requires a review
  nobody has given. Requiring `DRAFT` or `CLEAN` would refuse to promote in
  exactly the case promotion exists to resolve.

  The gate is the deterministic part of AGENTS.md's: every check the **base
  branch requires** has reported and none failed, every review thread
  dispositioned, `reviewDecision` not `CHANGES_REQUESTED`, `mergeable=MERGEABLE`
  (it reads `UNKNOWN` for a while after every push, and "not known to conflict"
  is not "mergeable"), and `headRefOid` re-read immediately before promoting and
  unchanged since the gate ran.

  The required set comes from `GET /repos/{slug}/rules/branches/{base}` — one
  endpoint covering rulesets and classic protection — because a non-empty
  rollup proves nothing on its own: GitHub registers checks incrementally, and
  `DRAFT` masks the `BLOCKED` that a missing required check would otherwise
  produce. A branch that enforces **no** required checks escalates rather than
  promoting: there is no CI result to certify, which usually means the branch
  ruleset was never imported (docs/CHECKLIST.md).

  Two more conditions come from the same "absence of evidence" principle.
  Unchecked items under a `## Deferred findings` heading in the PR body block
  promotion — they are open work the local loops carried to this stage on
  purpose. And an empty review-thread list means "nothing found" *or* "hasn't
  looked yet", so each bot named in `required_review_bots` must have reviewed
  this exact head. That list is empty by default and separate from
  `review_sender_trust`: foreman cannot detect which bots a repo has installed,
  and trust says whose findings are safe to quote, not who will post. Only
  reviews count, never inline comments — GitHub re-anchors an inline comment's
  `commit_id` to the newest commit when its line survives a push, so a stale
  review's comment reads as current (observed on harmon-init#520).

  Immediately before `gh pr ready` the gate takes **one fresh snapshot** —
  `state`, `isDraft`, `headRefOid`, `reviewDecision`, `statusCheckRollup` in a
  single read — plus a re-read of the review threads, and decides on those
  together. The rollup is re-classified against the required set rather than
  trusted from the opening read, because a re-run changes CI state without
  changing the head. Everything
  checked earlier came from a `pr_status` read taken before the required-check
  lookup, the mergeability read, and the wait for a configured reviewer, any of
  which gives a late review time to land. A bot submits its verdict and its
  inline findings in one action, so the very review the gate waited for can
  carry threads the earlier snapshot never saw; and a summary-only
  `CHANGES_REQUESTED` creates no thread at all, which is why the decision is
  re-read rather than trusted from the top. A new condition on the gate belongs
  in that snapshot — not as another sequential re-read. A push landing mid-gate defers to the next tick;
  anything else unproven escalates. The transition is confirmed by re-reading
  `isDraft` on the same head — an unconfirmed promotion escalates rather than
  reporting a handoff. Promotion is idempotent: an already-ready PR is never
  promoted twice. Foreman performs no merge action of any kind.
- **After promotion** foreman keeps adjudicating findings that land later, but
  never returns the PR to draft — promotion already notified CODEOWNERS and
  requested reviewers, and `gh pr ready --undo` cannot unsend that.
- **`require_codex_cloud_review = true`** → Foreman fails closed before both the
  promotion and the label, removes a stale readiness label from fresh PR status
  before any state-specific return, and escalates to the manual shepherd
  procedure, which owns the current-head Codex trigger, bounded retries, and
  terminal-result validation. Such a PR therefore stays draft under foreman —
  the human handoff is the manual procedure's to make. Watch mode writes this
  handoff and its detail to the heartbeat log instead of silently idling.

## Watch mode and unattended runs

`task foreman:watch` loops plan→dispatch→shepherd with a heartbeat line per
tick (`.foreman/watch.log`) — silence must look different from health. Every
tick is stateless and idempotent: kill it, reboot, resume exactly where
reality is. Stop conditions: milestone complete, `.foreman-stop` file,
aggregate budget, N consecutive failing ticks.

For multi-day runs prefer a host that won't idle-stop (Codespaces force-stops
at its idle timeout regardless of a background loop; a coder workspace or any
persistent container is the reliable substrate). Cron invoking
`foreman:dispatch` + `foreman:shepherd` on a schedule is equivalent to the
live loop — statelessness makes the runtime substrate interchangeable.

**Billing**: `billing = "subscription"` (default) inherits the container's
`CLAUDE_CODE_OAUTH_TOKEN`; USD budgets are inert (timeout/turns bind) and the
quota-wait signature turns usage-window exhaustion into planned pauses.
`billing = "api"` exports `FOREMAN_ANTHROPIC_API_KEY` **only inside the
adapter process** (the container-wide `ANTHROPIC_API_KEY` strip stays), and
USD budgets bind. Switching is a config flip plus one secret.

## Security model

- **Server-side boundaries** (hold regardless of model behavior): default
  branch ruleset requiring PRs, code-owner review, and green checks, with
  the bot excluded from bypass; a fine-grained bot token without `workflows`
  write (a push touching `.github/workflows/**` is rejected by GitHub); no
  org/admin scopes.
- **Identity assertion**: before its first write, foreman requires the gh
  identity to equal `expected_login` — a leaked-context or wrong-account run
  refuses to write.
- **Write contract**: every GitHub mutation lives in
  `scripts/foreman/github.py` and nowhere else. Foreman may create/push its
  own branches, open draft PRs, promote its own draft to ready for review once
  the readiness gate passes, edit its own PRs and their
  foreman-namespace labels, upsert one marker-identified status comment per
  unit, resolve threads it dispositioned, post human-approved preflight
  corrections, and ensure its label definitions. It must never merge, close
  or reopen issues, edit issue bodies/titles, touch human comments, or write
  fields/types/dependency edges — those operations do not exist in the
  module, and the test suite greps to keep them absent. Marking ready for
  review is a handoff, not a merge: it requests human review and never
  authorizes the merge itself.
- **Prompt-injection surface**: only trusted-association issue comments and
  review threads whose authors match a trusted association, Foreman's account,
  or `review_sender_trust` enter prompts. Other unresolved review threads go to
  the human queue. Trusted review-bot findings and CI logs are framed as claims to
  adjudicate, not instructions; agents run with conservative permission
  modes outside the sandboxed bot devcontainer (`FOREMAN_SANDBOXED=1`
  relaxes inside it).
- **Backend environment**: agent subprocesses receive an explicit runtime and
  authentication allowlist, not the complete parent environment. Dispatch,
  CI-repair, rebase, and preflight agents do not receive `GH_TOKEN`; only the
  adjudication agent receives the intentionally scoped bot token needed for its
  reply-and-resolve contract. Cloud, 1Password, SSH-agent, and unrelated host
  credentials never cross the adapter boundary. Note where that guarantee stops:
  `HOME` *is* on the allowlist, so an agent still reaches whatever `~/.config/gh`
  holds. In the bot devcontainer nothing normally does — that profile
  authenticates from `GH_TOKEN` alone — which is why foreman belongs there and
  not in the human `dev/` profile, where an operator's own `gh auth login` would
  make this withholding vacuous.

## Configuration (.foreman.toml)

```toml
backend = "claude"            # default adapter; per-issue input overrides
require_approval = true       # explicit arming (false = default-armed + holds)
inputs = "auto"               # auto | fields | labels
verify_command = ["task", "ci"]
max_parallel = 3
branch_prefix = "foreman"
expected_login = "your-bot"   # identity assertion; "" skips
billing = "subscription"      # subscription | api
sandboxed = false             # FOREMAN_SANDBOXED=1 env inside the bot container
review_sender_trust = ["Copilot"] # add "coderabbitai" when use_coderabbit=true
required_review_bots = []     # bots whose review of the head gating promotion

[budgets]
dispatch_usd = 20.0           # binds in api billing mode
shepherd_usd = 10.0

[timeouts]
dispatch_min = 90
shepherd_min = 30
```

## Extending

- **Backends**: `scripts/foreman/backends/<name>.sh` is the entire vendor
  surface (`run` / `resume <ref>` / `capabilities`). v1 ships `claude.sh` and
  `mock.sh` (hermetic seam proof). A new vendor is one small file, added when
  concretely needed.
- **Signatures**: when an unmatched CI failure gets an LLM diagnosis, add its
  regex to `signatures.toml` — the LLM diagnoses once, code recognizes
  forever.
- **Agent definitions**: `.claude/agents/foreman-*` wrap the same one-sourced
  runbooks in `scripts/foreman/prompts/` for interactive use.
