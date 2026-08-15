# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Gemini CLI, GitHub
Copilot, Codex, etc.) working in this repository. `CLAUDE.md`, `GEMINI.md`, and
`.github/copilot-instructions.md` are symlinks to this file — edit only `AGENTS.md`.

## Project Overview

Harmon Init is a **Copier project template** that scaffolds new repos with
pre-configured DevOps tooling, CI/CD, linting, security checks, git hooks, and task
runners — and can also be applied to existing repos to standardize them. This is NOT
an application; it is a template repository used via the
[Copier](https://copier.readthedocs.io/en/stable/) templating tool.

Repo: https://github.com/evanharmon1/harmon-init — see
[docs/README.md](docs/README.md) for the documentation map,
[docs/architecture/README.md](docs/architecture/README.md) for the architecture,
and [DESIGN.md](DESIGN.md) for design/UX intent.

## Hard Rules

Non-negotiable, regardless of any autonomy granted elsewhere in this file:

- **Never write to a password manager or credential store unprompted.** Do not
  create, modify, archive, or delete anything in 1Password (items, fields,
  vaults — via the `op` CLI or any other means), OS keychains, or any other
  secret store unless the user explicitly requested that specific write in the
  current conversation. Even when asked, restate exactly what will be written
  and get confirmation before executing — announcing intent and proceeding in
  the same turn is not consent. Read operations (`op read`, `op item list`,
  `op inject` over existing references) are fine.
- **Never make generated output depend on paid or trial-only SaaS by default.**
  Any third-party service that requires an account, app installation, trial, or
  payment must be an explicit Copier opt-in that defaults off, with its free-tier
  and private-repository limitations documented next to the question.
- **Never reference harmon-dotfiles or chezmoi in shipped output.** harmon-init,
  harmon-devkit, and harmon-infra are independent of the personal dotfiles repo
  and of chezmoi: nothing they ship — here, everything under `template/` plus
  the consumer-facing text in `copier.yml` — may name either or hardcode a path
  into somebody's dotfiles checkout (`~/.dotfiles/…` leaks the same setup
  without naming the repo), and none of them may require dotfiles to be
  installed, present, or accommodated. A consumer
  cannot read that repo, so rationale belongs in harmon-init rather than cited
  offsite, and content this repo owns is never described as kept "in sync" with
  it. The permitted coupling is one-way and optional: harmon-dotfiles may pull
  from these repos at a pinned tag; they never point back. Root-only mentions
  that ship to nobody (the sibling-repo lists, the "related repos" tables)
  create no dependency and are fine — which is why
  `test:template-independence`, the guard that enforces this, scans `template/`
  and not the whole repo.

## harmon-platform

One of four repos in **harmon-platform** (Evan's developer & DevOps platform + homelab):
[**harmon-init**](https://github.com/evanharmon1/harmon-init) (this repo — the template),
[harmon-devkit](https://github.com/evanharmon1/harmon-devkit) (boilerplates/scripts/AI assets),
[harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) (chezmoi dotfiles),
[harmon-infra](https://github.com/harmonops/harmon-infra) (homelab IaC). See the README for the full table.

Applying or auditing these standards against another repo is driven by the
**`standardize-repo`** Claude skill in harmon-devkit
(`ai/skills/repo/standardize-repo`): it wraps `copier` to scaffold a new repo,
adopt the template into an existing one, or audit a repo for drift — and carries
the authoritative repo-conventions catalog.

## Two-Layer Architecture

1. **Root level** — Config for developing/maintaining the template itself
   (`Taskfile.yml`, `lefthook.yml`, `.github/workflows/`, etc.). The root layer
   dogfoods the same conventions the template generates.
2. **`template/` directory** — The Copier template root (`_subdirectory: template`
   in `copier.yml`). Everything here becomes the generated project. Files ending in
   `.jinja` have variables substituted; jinja conditionals in file/directory names
   control inclusion.

Root lint tasks deliberately exclude `template/` (jinja files are not valid
YAML/Markdown). The **rendered** output is validated by `task test:template:*`.

**Dogfood parity — edit both layers in lockstep.** Most root files have a
`template/` counterpart they are the rendered form of (e.g.
`.devcontainer/Dockerfile` ↔ `template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile`,
`.github/workflows/devcontainer-build.yml` ↔ its `…devcontainer-build.yml….jinja`).
A change to one MUST be applied to the other in the same PR, or the template and
the dogfood drift — the repo stops practicing what it ships, and `task
test:template` will not catch it (it validates the *rendered* template against
itself, not against the root copy). The root form is the template rendered with
harmon-init's own answers (e.g. `[[ ci_runner_labels ]]` → `[ "ubuntu-latest" ]`),
and template-only logic (`[% if … %]`, `${VERSION}` arg substitution) collapses to
its concrete value. When you touch a templated file, grep for the sibling and edit
both.

**The answers the root layer is a render of are checked in** at
`.dogfood-answers.yml`. It is NOT a `.copier-answers.yml` — harmon-init is the
template, so it has no copier operation of its own and `copier update` can never
target it. When the root adopts (or drops) a template option, change that file in
the same PR, or the drift tooling below reports noise instead of drift.

Three checks cover the two layers, in increasing looseness:

| Check | Scope | Gate? |
|---|---|---|
| `task test:dogfood-parity` | **verbatim** twins (no `.jinja`) — byte-equality | yes (`verify` + CI) |
| `task test:dogfood-structure` | **jinja** twins — every rendered heading/task exists in the root copy | yes (`verify` + CI) |
| `task audit:dogfood` | **jinja** twins — full text diff | no, a report |

Verbatim twins are copied into generated repos byte-for-byte, so a fix applied to
only one side fails the parity gate instead of silently shipping stale content
downstream. Jinja twins can't be byte-compared — the root copy is a render and
legitimately diverges in prose — so the gate is narrowed to *structure*: if the
template grows a section or a task, the root should have gained one too. That
catches the direction drift actually travels (you edit `template/` to ship a fix
to consumers, and nothing fails when the root copy is forgotten); it does **not**
catch changes inside a task body or paragraph. For those, run `task
audit:dogfood` — before a release, or whenever a change spans both layers — and
read the diff. Intentional divergences are allowlisted, **with reasons**, in each
script.

The **shared skills** are vendored into `.claude/skills` (so the devcontainer and
cloud claude-* workflows can use them); the canonical copies live in harmon-devkit
under `ai/skills/`. The root repo dogfoods the same pinned skills sync the
template ships: `.skills-sync.yaml` pins a released harmon-devkit tag,
`task sync:skills` vendors the `universal` and `repo` categories — the
dev-workflow session skills plus `standardize-repo` — into `.claude/skills`, and
CI/pre-push run `task verify:skills` / `verify:skills:offline` as drift checks.
Keep the category list in step with `skill_categories` in `.dogfood-answers.yml`,
or `task audit:dogfood` reports a permanent root/template difference.

Bumping that pin after a harmon-devkit release is **automated**: the root-only
`.github/workflows/sync-harmon-devkit.yml` (→ `task sync:devkit-release` →
`scripts/sync-devkit-release.sh`) validates the released tag, rewrites both
pins, re-vendors, verifies, and opens or updates ONE rolling
`bot/sync-harmon-devkit` PR. It never merges anything — both repositories keep
their intentional release gates. To trigger or recover by hand, send the
dispatch (`gh api repos/evanharmon1/harmon-init/dispatches -f
event_type=harmon-devkit-released -f 'client_payload[tag]=vX.Y.Z'`) or run
`task sync:devkit-release -- vX.Y.Z` locally. See
[docs/architecture/ci-cd.md](docs/architecture/ci-cd.md).

## Common Commands

```bash
# Generate a new project from this template
copier copy harmon-init new-project --trust

# Local verification gate (lint + fast guards + template generation tests)
task verify

# Full CI mirror on demand (verify's checks + skills drift + devcontainer
# assert + security)
task ci

# Lint only (fast gate — safe for editors, hooks, and agents on every change)
task check

# Auto-format then lint
task fix

# Render the template into a temp dir and validate the output
task test          # = task test:template (all profiles)
task test:template

# Report root<->template drift for jinja twins (a report, not a gate)
task audit:dogfood              # full diffs
task audit:dogfood -- --summary # filenames + diff sizes only

# Free security baseline (Semgrep CE + gitleaks + dependency audit)
task security

# Optional Codex second-model review — advisory, never part of verify/ci
task challenge       # adversarial review (task challenge:codex under the hood)
task review          # verification checkpoint (task review:codex)
task codex:gate:enable   # auto Claude → Codex stop-gate (also :disable / :status)

# Foreman: dispatch ready issues to headless agents, shepherd their PRs
task foreman:plan -- --milestone <n|title>   # dry-run the graph/waves
task foreman:dispatch -- --issue <n>         # worktree → agent → verify → PR
task foreman:watch -- --milestone <n>        # unattended loop (humans merge)

# Releases are INTENTIONAL — never automated on merge to main
task release:patch   # or release:minor / release:major
```

`check` is deliberately kept fast (lint only) so editors, git hooks, and AI
agents can run it on every change without getting bogged down. `verify` is the
definition-of-done gate — check + the quick Taskfile/hook/parity guards + this
repo's test tier, which renders the whole template via `test:template` and is
therefore inherently heavier than a generated repo's (the Foreman v2 vocabulary:
verify = check + build + test). `ci` is the full pipeline — everything CI runs
(`verify`, the network skills-drift check, the devcontainer permission assert,
`security`) — so you can reproduce a CI run locally on demand instead of waiting
on a PR. Keep it that way: a check the build workflow **gates on** and that can
run locally belongs in `ci` too, or the "mirror" quietly stops being one. The
one carve-out: a check that needs **CI-only infrastructure** (a browser install,
a service container, credentials that only exist on a runner) stays out of `ci`
and is documented as an exception rather than being faked locally.

**Foreman** (`taskfiles/foreman.yml`, `.foreman.toml`) is the deterministic
supervisor for milestone-driven agent dispatch: explicit arming via
`foreman:*` labels (the only attributable mode — v2 refuses issue-field
arming because GitHub exposes no actor for field changes), hardened
doneness, a strict
write contract, and **never a merge**. The CLI lives in
[ponderousdev/foreman](https://github.com/ponderousdev/foreman) (spec, ADRs,
and architecture docs there); this repo pins a released tag via
`FOREMAN_VERSION` and runs it through `uvx` — no source is vendored (ADR 0002
records the v1 in-repo design this superseded). The wrapper and config ship
to generated repos, so they are two-layer twins. Foreman's own PRs follow
the same draft-first lifecycle as the Dev Loop below: it opens draft PRs
(labelled `foreman:dispatched`) under its own verify gate and promotes them
only through its readiness gate — checks green, review threads resolved, and
the `[reviewer]` current-head gate configured in `.foreman.toml`, wired to
the same `@codex review` contract the shepherd stage uses (fail-closed,
bounded attempts) — to `foreman:ready-for-review`, the hand-off to human
review. Humans still do every merge. On this public repo, D4 classifies
every unit `untrusted-input`, so **dispatch refuses under the local runner
by design** (plan / vet / status / preflight all work) until an isolated
runner ships.

## Dev Loop

Bias toward shipping: drive every change to a PR instead of stopping at a green
local diff. Work in small, PR-sized units, and move to the next stage on your
own — a PR handed to a human is the default deliverable, not something to ask
permission for.

**The draft PR is the workbench.** GitHub reports drafts and non-drafts alike as
`OPEN`, so "open PR" says nothing about whose turn it is. These three states do:

- **Draft PR** — the agent's workbench. Implementation, CI, bot review, and
  shepherd fixes are still in progress. Nobody is waiting on a human.
- **Ready-for-review PR** — non-draft. The automated lifecycle is complete and
  the change is handed to a human. Reaching it is a gate, not a judgement call.
- **Merged PR** — always a separate human decision. Agents never merge.

```text
preflight/claim → implement → task verify → task challenge → task review
  → task ci → create DRAFT PR → shepherd the draft (CI, deferred findings,
  reviewers) → readiness gate → mark ready for review → human review
  → human merge
```

Creating the draft is a phase transition, not a terminal state, and every stop
short of the readiness gate leaves the PR **draft** with a blocker report — a
non-draft PR must always mean the automated work is done.

**Round caps are resolved, not stated here.** The challenge, review, and
shepherd stages below are each capped, but this file names no numbers: they
live in [`.devflow.toml`](.devflow.toml) as `rigor` tiers, so there is one
place to change them and a parity gate that catches a change made on only one
side. Resolve in this order — an explicit instruction in this session, then a
`rigor:*` label on the issue, then `default_rigor`, then a built-in 4 / 4 / 4
if the file is absent — with a `min_rounds` floor of 1 for any tier that
does not define it — the absent-file case, a legacy config predating the key,
and a partially migrated one where only some tiers state it alike — which is
also the floor every shipped tier states explicitly. When the change under review **edits `.devflow.toml`
itself**, resolve its caps **and floor** from the **merge-base** copy rather
than the branch copy: otherwise a branch can lower the very gate it is
changing — the floor included, since a self-lowered `min_rounds` buys an
earlier empty-round exit — dropping every
tier and `default_rigor` together passes the validator and evades the
below-default disclosure, because nothing is left to be below. An explicit
instruction from Evan still overrides, since that is an attributable human
decision rather than the branch deciding for itself. GitHub labels are
multi-select and nothing stops an
issue carrying two, so resolution is **per stage, taking the highest cap
present**: a conflict can then only ever buy more review, never less, and no
ranking of the tier names has to be agreed on anywhere. `min_rounds` resolves
under the same principle — the highest floor present wins — so a label
conflict cannot quietly select the lower floor either. Because that is per
stage, two retuned tiers can yield caps belonging to no single tier — so what
you announce is the **caps**, naming a tier only when one supplied all of
them — the floor included,
and the disclosure below compares caps rather than tier names. A `rigor:` value
that names no tier in the file is ignored rather than guessed at. Treat the
label as advisory: it is applied by people and verified by nothing, and
GitHub's **triage** role can label an issue with no push access at all — so a
budget can be retuned by someone who could not edit `.devflow.toml`. An agent
never applies one to itself, and **says so in the announcement and in the PR
body whenever any resolved cap or floor is below what `default_rigor` would give**, so a
reduced budget is visible to the human reviewer instead of silent.
**Announce the resolved caps on entering
the loop** — "rigor: `<tier>` (`<source>`) → challenge ≤`<n>`, review ≤`<n>`,
shepherd `<n>`, min_rounds `<n>`", filled in by reading the file rather than
from memory — and
carry it into the PR body, so a later round or a different session can see
which budget it is spending instead of inferring one. Everything else about
these stages is policy rather than a parameter and does not vary by tier: the
exit condition,
the round-2 scaffolding checkpoint, the escalation rule, and the deferred-P2
sidecar all hold identically at every rigor. A cap is a ceiling, never a quota
— a stage that meets its exit condition on round 1 is done, whatever the tier
allowed.

- **Branch** — feature branch off `main`; never commit directly to `main`. For
  parallel or isolated work, take the branch in its own worktree via
  **`task worktree:new -- <name>`** (and `task worktree:rm -- <name>` when
  done) rather than a hand-rolled `git worktree add` — it installs that tree's
  dependencies and proves the hooks fire in it. See
  [docs/conventions.md](docs/conventions.md) § Worktrees, including why
  `-c core.hooksPath=.git/hooks` must never be passed inside one.
- **Edit + `task check`** — the fast inner loop; run it constantly and fix
  lint immediately. (Remember dogfood parity: template twins in the same
  change.)
- **`task verify`** — when the change feels done, loop edit → verify until
  green; verify is the definition-of-done gate (includes the render matrix).
- **`task challenge`** — adversarial second-model review, under the resolved
  **challenge cap**. `/gauntlet` is the procedure, and it is **user-invocable
  only** (`disable-model-invocation: true`): an agent enters the stage by
  reading `.claude/skills/gauntlet/SKILL.md` and following it, not by calling
  a slash command it cannot call. The skill carries the mechanics this file
  deliberately does not restate — backgrounding the long reviewer runs, the
  adjudication table and its ledger, the deferred-findings sidecar, and the
  PR-open ritual. What stays here is the policy those mechanics run under, and
  where a **vendored** skill (`/gauntlet`) states a different cap, floor, or
  exit condition, **this file wins** — the skills are synced from harmon-devkit
  on its own release cadence and can lag a policy change made here.
  The stage ends when **two consecutive
  rounds adjudicate to zero P0 and zero P1 findings** — whether those rounds
  came back empty, all-P2 as labeled, or P1-labeled and adjudicated down to
  P2. Severity is read off the **adjudicated** column of your adjudication
  table, not off the reviewer's label, and nothing further is owed after the
  second such round: the second round *is* the confirmation, so there is no
  extra clean run to buy. A round that returns **no findings at all** ends
  the stage on its own **once at least `min_rounds` rounds have run** — an
  empty round is the old rule's clean re-run, so neither a trivial change nor
  a clean post-fix re-run pays for a confirmation pass, but a tier that sets a
  floor buys the rounds it asked for before that shortcut opens. The other two
  exits satisfy any floor of 2 or less by construction — two consecutive clean
  rounds *are* two rounds, and a capped final round is at least the cap, which
  is never below 2 — so `min_rounds` binds the empty-round path and nothing
  else. Fixing the findings is still not the exit
  condition; adjudicated-clean rounds are. The exit carries one
  precondition: every P2 you deferred during the stage must already be in the
  deferred-findings sidecar (see "Deferring P2s" below) — an exit that drops
  a P2 is not an exit, because nothing downstream will ever see it again.
  **P2s do not gate this stage**: carry
  them to the PR. This loop is
  **self-referential** — the fixes you make in response to a round become the
  next round's input, so it can generate its own work indefinitely — and that
  is what the cap defends against: the resolved **challenge cap** bounds the
  challenge → fix → re-challenge rounds; if P0/P1 findings persist at it, stop
  and escalate to Evan. A capped
  final round that adjudicates to zero P0/P1 ends the stage by itself — its
  confirmation would be a run the cap forbids, and a clean last round is
  convergence, not the persisting disagreement escalation exists for.
  "Between rounds, check what the findings are about" below is how you catch
  the loop feeding on itself before the cap does, and round 2 is where that
  check is owed rather than optional.
- **`task review`** — verification-checkpoint review, run out of the same
  skill; same adjudication, the
  same exit condition counted over its own
  rounds, the same self-referential shape and so the
  same reason for a cap, under
  its own resolved **review cap**. The two stages are counted separately — and
  capped separately, even where the tier gives them equal numbers: a converged
  challenge says nothing about review.
- **`task ci`** — the full CI mirror; fix anything it catches.
- **Open the draft PR** — conventional commit, push the branch,
  **`gh pr create --draft`** with a clear what/why/verification summary (mind
  the `template/` → `fix:`/`feat:` title rule below). Then fetch
  `headRefOid,isDraft` and require both the SHA you pushed and
  `isDraft == true`: a non-draft result is not the normal publication path, so
  reconcile it before going further.
- **Git transport** — pushes authenticate over HTTPS via `gh`. Provisioned hosts
  and the devcontainers rewrite GitHub SSH URLs to HTTPS via `url.insteadOf` so
  that git never needs an SSH agent: a headless container has none, forwarding
  one into an interactive container is lockout-prone, and `gh` already holds an
  HTTPS credential that works for both. Never work around an SSH failure by
  pushing to a raw `https://…` URL — a URL push bypasses the named remote and
  leaves stale tracking refs. On an unprovisioned host, force the helper
  and the rewrite against the *named* remote:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' -c url."https://github.com/".insteadOf="git@github.com:" -c url."https://github.com/".insteadOf="ssh://git@github.com/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com:443/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com/" push`
  (a credential helper only applies to HTTPS, and `insteadOf` is prefix
  matching — every SSH form needs its own mapping, hence all four).
- **Shepherd the draft to ready for review (`/shepherd`, under the resolved
  shepherd cap).**
  `gh pr create --draft` returning is
  the trigger for this stage, not the end of the work — enter it deliberately
  instead of judging for yourself when the PR is finished. The PR stays draft
  for the whole stage; only the readiness gate below may promote it.
  `/shepherd` is the
  procedure, and it is **user-invocable only**
  (`disable-model-invocation: true`): an agent enters the stage by reading
  `.claude/skills/shepherd/SKILL.md` and following it, not by calling a slash
  command it cannot call. Start by
  re-reading the **unchecked** entries under `## Deferred findings` in the PR
  description — those P2s are open work, not a changelog; tick each one off
  in the body as you settle it. Then watch CI
  (`gh pr checks <n> --watch`) and incoming bot/human reviews. When a check
  fails or a review lands findings, treat the findings as hypotheses: verify
  them against the code, fix only what's confirmed, explain rejections in a
  PR comment, push the fix commit, and watch again. **This is where P2s are
  settled** — the ones the PR description defers here plus anything the PR
  reviewers raise: fix, decline with reasoning, or file as a follow-up issue,
  but do not leave them unaddressed. Shepherd-round fixes must pass `task
  verify` before each push; the local challenge/review loops are not
  re-entered — the post-push cloud/bot review is the second-model check at
  this stage.
  **Require a current-head Codex result.** On initial shepherd entry and
  immediately after every fix push, capture the PR's current `headRefOid` and
  the head's push time.
  **Do not hand-roll the polling.** Run the vendored
  `.claude/skills/shepherd/assets/check-codex-cloud-review.sh`, in its order:
  `reserve` a cycle against the captured head **before** posting the
  trigger — the durable state must exist before the GitHub write, or an
  interruption between the two leaves an untracked trigger a resumed session
  can double-spend — then post `@codex review`, `attach` the comment ID
  returned for that trigger, and `check`, acting on the exit code it returns
  (0 clean, 10 findings, 11 pending, 12 retry, 13 escalate,
  2 indeterminate). The
  script exists
  because ad-hoc pollers fail in one specific, repeatable way — they watch
  reviews and inline comments and miss the **top-level comment** surface, so a
  clean `Reviewed commit:` verdict posted there reads as silence and a
  finished cycle is reported incomplete (harmon-devkit#334; seen again on
  PR #731). It never writes to GitHub, so posting the trigger comment stays
  yours.
  The contract below is normative and stays here whatever tooling runs it: it
  is what "terminal" means, and the script is the implementation you are
  required to use rather than a substitute definition. A Codex result is
  terminal for that captured head only
  when it is either: a clean review or top-level comment authored by GitHub
  actor ID `199175422` (`chatgpt-codex-connector[bot]`, type `Bot`) whose
  `Reviewed commit:` identifies that head; a fresh 👍 from that bot on that
  exact trigger comment, created after both the head push and the review
  request, with no newer contradictory bot result; or review findings authored
  by that bot which identify that head and must be adjudicated before the
  cycle can become clean. Earlier comments, reviews,
  inline findings, and reactions never count for a newer head. A 👀 is pending,
  not success; if it disappears without a terminal result, the attempt is
  incomplete.
  Give each attempt a full 10–15 minute window. An attempt is **incomplete**
  when its window elapses with no terminal result for the captured head
  (the script's exit 12). After an incomplete first attempt, repeat the
  reserve-first sequence as attempt 2: `reserve --attempt 2` against the same
  head, then post `@codex review` once more, then `attach` the comment ID
  returned for that trigger, and run one more full window. If both attempts
  are incomplete, stop and escalate without reporting green (the script's
  exit 13). Waiting and the
  one allowed re-trigger do not consume a shepherd fix round. Immediately
  before accepting the result or reporting green, re-`check` the cycle and
  re-read `headRefOid`; a changed head invalidates the result and starts
  a new current-head cycle.
  A badged finding stated **outside an inline thread** — in a top-level
  comment or in a review's own body — has no reply linkage, so the
  reply-based adjudication path cannot reach it and findings outrank a later
  clean result on the same head. The checker's `settle` subcommand records the
  disposition instead; its exact invocation lives with the recipe in
  `.claude/skills/shepherd/SKILL.md`, which this file deliberately does not
  restate — the same reason it routes you to the checker rather than
  describing how to poll.
  What belongs here is when it applies. Answer the finding on the PR as usual,
  and note that only two of the three answers end with `settle`: **fixing** it
  means a push, which moves the head and starts a fresh cycle that reviews the
  fix on its own merits, and `settle` neither applies nor accepts that
  disposition. It records the two answers that leave the code alone —
  declining with evidence, or filing it as follow-up work — and requires a
  note for exactly that reason: the record is a human's adjudication, not a
  suppression. It is head-bound and fingerprinted against the body it settled,
  so a finding Codex edits afterwards blocks again while the superseded entry
  survives as the record of what was decided about the earlier text. Once
  every non-thread finding on the head carries one, `check` reports clean with
  a detail naming the disposition applied.
  Shepherd is **externally driven** — CI results and other people's comments
  are its input, so it cannot manufacture a round on its own. A round is one
  fix push, or one no-change cycle where everything is answered and nothing
  needs fixing; waiting on CI or a reviewer is never a round, and this cap is
  independent of any other stage's. What it bounds is other people's findings,
  not self-generated work. It is not wholly immune, though — a reviewer can
  flag the fix your *last* round pushed, so if the rounds start circling your
  own patches, step back and ask whether the findings are about the change you
  set out to make or about a previous round's fix. Whether anything more has
  landed is settled by "Checks green is a non-terminal state" below, not by
  the absence of an immediate reply. Stopping one stage's loop is never a
  decision about another's:
  **a decision to stop one loop does not transfer to another**,
  because each is bounded for its own reason. "We have looped enough" is a
  judgement about one loop's self-generated work, and carrying it here skips
  this stage instead of bounding it, leaving the PR with reviews unanswered.
  The converse also holds: stopping to **escalate** something you cannot
  resolve halts the whole change rather than one loop, so it is not a licence
  to move on to the next stage either — a persistent P0/P1 at the challenge or
  review cap means wait for Evan, not open the PR anyway.
  If checks still fail or findings remain at the shepherd cap, stop and
  summarize what's unresolved on the PR for Evan. That cap does not vary by
  rigor tier — it bounds other people's findings, not your own work, so
  lowering it would abandon unanswered reviews rather than save effort.
  Where a **vendored** skill (`/shepherd`)
  states a different cap or exit condition, **this file wins** — the skills
  are synced from harmon-devkit on its own release cadence and can lag a
  policy change made here.
- **Checks green is a non-terminal state.** Reporting "all checks pass"
  without having polled reviews and inline comments is not a handoff — it is
  the middle of the shepherd stage. Bot and human reviews land *after* checks
  settle, so `gh pr checks --watch` returns at exactly the moment the review
  has not run yet: an empty comment list read at that instant means "not
  reviewed yet", not "nothing to answer". Wait for **both** signals: every
  check must conclude, and the required current-head Codex cycle above must
  reach a terminal result. Green CI while that cycle is pending or incomplete
  is still non-terminal.
- **Stop at ready-for-review.** When the readiness gate below passes, promote
  the draft **exactly once** with `gh pr ready <n>`, confirm `isDraft == false`
  on the same head, report, and stop. Human approval is deliberately *not* a
  precondition: ready-for-review is the request for that review, not permission
  to merge. Merging is always a human decision.

### Readiness gate

The single definition of "the automated lifecycle is complete", used by
interactive shepherding and by Foreman alike. A draft may be marked ready for
review only when **all** of the following hold for its current `headRefOid`:

- Required CI checks have concluded successfully. An empty check list is
  *indeterminate*, not a pass — GitHub populates it asynchronously, so a read
  taken moments after the push reports nothing having run rather than nothing
  to run.
- The current-head Codex cycle above is terminal and clean — including clean
  by way of dispositions recorded with `settle` (Codex review is
  enabled here; where it is off, this condition drops out).
- Every review finding is fixed, declined with evidence, or filed as follow-up
  work.
- Every inline review comment has its required per-thread reply.
- Every `## Deferred findings` entry in the PR body is ticked with its
  disposition.
- `reviewDecision` is not `CHANGES_REQUESTED`.
- `mergeStateStatus` is none of `DIRTY`, `BEHIND`, `UNKNOWN`.
- No newer push invalidated any result the gate relied on — re-read
  `headRefOid` immediately before promoting and compare.

A failed **or indeterminate** condition is not a pass: leave the PR draft, post
a blocker report naming what is unresolved, and stop. "The check never ran",
"the fetch errored", and "the reviewer never answered" are all indeterminate.
Promotion is the one-way door in this lifecycle — it notifies CODEOWNERS and
requested reviewers, and `gh pr ready --undo` cannot unsend that — so an
unproven condition means stay draft, not promote and watch.

## Critical Copier Gotchas

- **`--vcs-ref=HEAD` is load-bearing.** Without it, `copier copy` from a local path
  renders the **latest git tag**, silently ignoring all uncommitted AND committed-
  but-untagged work. With it, copier auto-includes dirty/untracked changes via a
  throwaway commit in a temp clone (`DirtyLocalWarning`) — your working tree is
  never touched. `scripts/test-template.sh` always passes it.
- Side-effectful copier answers (`bunch_add`, `github_remote_create`,
  `github_release_init`, `run_task_install`) must default to **no** so
  `copier copy --defaults` is CI-safe.
- **Optimize for regular rolling updates, not every historical migration path.**
  Repositories standardized by harmon-init are expected to stay near the current
  release. Give new answers sensible defaults and let the standardization PR apply
  repository-aware judgment. Do not add permanent migrations or version-pair
  fixtures for arbitrary old/new combinations; handle unusual version gaps and
  customizations in the downstream PR unless a demonstrated fleet-wide,
  deterministic transformation cannot be handled safely there.
- After changing `copier.yml` or anything in `template/`, `task test:template:all`
  must pass.

## Development Workflow

- No direct commits to main (enforced by lefthook `guard:no-commit-to-main` and the
  branch ruleset). Work on feature branches; PRs require code-owner review and the
  `verify` + `security` status checks.
- **Agents never merge to main** — no `gh pr merge`, `git merge`, or push to
  `main` without Evan's explicit, per-merge approval, even when CI is green and
  the ruleset would allow it. Open the draft PR and shepherd it — checks green
  with reviews unpolled is not the stopping point — then promote it through the
  readiness gate, report, and stop; merging is always a human decision.
  (`.claude/settings.json` backstops this with `permissions.ask` rules on merge
  commands.) `gh pr ready` is *not* a merge and agents may run it — but only
  out of a passing readiness gate, never to signal "I think this looks done".
- **Reply to every inline PR review comment in its own thread** — bot
  reviewers and humans alike. Treat findings as
  hypotheses: verify each against the code, fix what's confirmed, and post the
  rejection reasoning with evidence otherwise. Post replies with
  `gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment-id>/replies -f body=…`
  (comment IDs from `gh api …/pulls/<n>/comments`). A rollup summary comment
  on the PR is optional in addition, never a substitute for per-thread
  replies.
- Git hooks are managed by **lefthook** (`task install:hooks`); every hook delegates
  to a Taskfile target so local hooks, CI, and manual runs execute identical
  commands. Never bypass hooks with `--no-verify`.
- Commit messages follow **Conventional Commits** (enforced by commitlint):
  types `build, chore, ci, docs, feat, fix, perf, refactor, revert, style,
  test`.
- **A PR that changes `template/` must use a `fix:`/`feat:` (or breaking) PR
  title.** Consumers receive harmon-init only via `copier update` to a released
  tag, and squash-merge feeds the PR title to release-please, which tags only
  feat/fix/breaking — so a `chore:`/`docs:` title over `template/` would merge
  without cutting a release and downstream repos would never pick the change up.
  The `release-content-guard.yml` check enforces this; **retitle rather than
  bypass** (e.g. `fix: update to harmon-init …`, not `chore:`). Non-`template/`
  changes (docs, this repo's own tooling) keep their normal type. Pre-flight it
  locally before opening the PR with your intended title:
  `PR_TITLE="<title>" BASE_SHA=main task guard:release-title`.

## Second-Model Review (Codex)

A second AI model (the OpenAI Codex CLI) reviews changes on demand — opt-in
for generated repos via the `use_codex_review` answer; this repo dogfoods it.
Local and advisory only: nothing runs in CI, and no `verify`/`ci` step depends
on Codex. Setup and mechanics: `docs/guides/codex-review.md`.

- `task challenge` (→ `challenge:codex`) — adversarial review: challenges the
  architecture and approach; hunts authorization bypasses, data-loss paths,
  unsafe rollback, races, hidden coupling, operational failure modes, and
  needless complexity. Steer it with e.g.
  `task challenge -- --base main focus on the update/migration path`.
- `task review` (→ `review:codex`) — verification checkpoint: double-checks
  the implementation, consistency, and test coverage before `task ci`.
- `task codex:gate:enable` / `:disable` / `:status` — the automatic
  Claude Code → Codex stop-gate (the codex plugin's Stop hook reviews each
  editing turn and blocks completion on material findings). Per-repo,
  per-machine state; defaults off. Inside Claude Code the equivalents are
  `/codex:review`, `/codex:adversarial-review`, and `/codex:setup`. The
  toggles are approval-gated (`permissions.ask`), `disable` refuses
  non-interactive shells, and agents must **never disable the gate to get
  past a BLOCK** — adjudicate the finding or escalate to Evan instead.

These tasks slot into the **Dev Loop** above: after `task verify` goes green,
before `task ci` — and the procedure for running them to convergence is the
vendored `/gauntlet` skill, entered by reading
`.claude/skills/gauntlet/SKILL.md`. What follows here is the policy that skill
runs under; where the two disagree, this file wins. Codex cloud review is also connected to this repo's PRs —
it posts inline comments only for high-priority findings. During shepherding,
accept its clean comments, reviews, or reactions only under the current-head
cycle above: stale activity is not evidence for the current commit, and a lone
👀 that disappears or never resolves is an incomplete attempt.

**Codex Automatic reviews must stay disabled.** Codex triggers a cloud review
on three events: opening a PR for review, marking a draft ready, and an
explicit `@codex review`. The first two fire too late to inform a draft
workbench, and the second is actively harmful here — `gh pr ready` would kick
off a fresh asynchronous review *after* the gate that was supposed to complete
the automated work, so non-draft would stop meaning "ready for a human". The
lifecycle therefore uses explicit `@codex review` requests while the PR is
draft, per the current-head cycle above. They are disabled, platform-wide:
personal Auto review is off, and the repository's Auto code review preference
and its review **Trigger** are both on **Follow personal** — confirmed by the
maintainer 2026-08-13 and recorded under docs/CHECKLIST.md's [human-only]
item. Nothing in the lifecycle gates on it. One thing is worth telling the
maintainer: if a Codex cloud review ever fires **unsolicited** — after a push
or a promotion that no `@codex review` comment triggered — say so; that is
the signature of the knobs drifting back on (observed and corrected
2026-08-10). Reporting an anomaly you happened to observe is not a check to
run, and nothing waits on it.

**Treat Codex findings as hypotheses, not authority.** For every finding:

1. Verify it against the actual implementation, surrounding code,
   requirements, and tests.
2. Classify it: confirmed, plausible but unproven, or false positive.
3. Fix only confirmed findings; add or improve regression tests where
   appropriate.
4. Explain why any rejected finding is incorrect or irrelevant.
5. Re-run `task verify` (and the other relevant gates) after fixes.
6. Finish the round with an adjudication table and record it; the skill
   defines the columns and the per-branch ledger they are written to.

**Between rounds, check what the findings are about.** Those six steps are all
*per-finding*, so a reviewer can be right every round while the loop as a whole
diverges: each fix adds surface, the next round attacks that surface, and the
findings stay individually defensible right up to the cap. Before starting a
round's fixes, ask where they *live* — in the change you set out to make, or in
code that exists only because an earlier round asked for it. **A round whose
findings are all about the previous round's fix is the tell**, and it is
visible in round 2 — the first round that can show it. Do not wait for the
pattern to be unmistakable in round 3, by which point only one round is left.

**Round 2 is the checkpoint, not a suggestion.** Under the two-consecutive
exit the cap is no longer the only thing standing between you and a loop that
feeds on itself, so the check has to happen where it first can. At round 2,
for every finding, say on the adjudication table whether its subject exists
only because an **earlier round of this same stage** added it. A finding that
does gets adjudicated with one of three dispositions written out: **delete**
the scaffolding (which moots the finding — see below), **restructure it to
invariants** (deletion by abstraction — see below), or state that it is in
scope and why the change genuinely needs it. What is not allowed is hardening
round-1's scaffolding by reflex and letting round 3 attack the result.

**Deleting the added code is a legitimate way to converge.** When a
round's findings are about scaffolding rather than the change, weigh removing
that scaffolding against hardening it once more — a remediation can be correct
in the abstract and wrong for the artifact. A documentation guide that has
grown a hand-rolled process supervisor earns real, defensible P1s about per-run
state, process-group supervision, and PID reuse; every one of them becomes moot
when the recipe is deleted instead of hardened. That is not giving up on the
findings — and it is not a way to re-score the round that raised them. A
confirmed P0/P1 keeps its adjudicated priority for its own round whether the
remedy is a fix or a deletion; the remedy either way is input to the **next**
round, and only that later round's review of the changed tree counts toward
convergence. What deletion buys is that the next round finds nothing left to
re-raise. Name the mooted findings
in the adjudication table *and* in the message of the commit that removes the
code — the table is scrollback, but the commit is why the code is gone, and it
is the record a later round or a different session can still find.

**Restructuring to invariants is the same move where deletion is unavailable**
— deletion by abstraction. When the artifact is a spec or a document whose
accreted procedure-prose *cannot* simply be dropped because earlier rounds
legitimately demanded it, replace the attackable procedure with the
universally-quantified property it was approximating, delegate the mechanism to
the implementation surface that can be tested, and carry the review's attack
scenarios over as required test cases. The next round finds no wording seam to
attack, and the obligation is preserved rather than dropped — which is what
separates this from quietly deleting a requirement. Name it on the table and in
the commit message exactly as a deletion is named.

One endpoint is worth knowing: if the deletion empties the change *entirely*,
there is no round to converge on — `codex-review.sh` refuses an empty scope
non-zero by design, so the stage cannot pass and re-running will not change
that. Treat it as the answer rather than a failure to work around: a change
that has become empty is abandoned, not reviewed clean.

**Severity gating.** Both tasks ask Codex to label every finding `P0`
(breaks correctness, security, or data integrity in ordinary use, or breaks
an existing contract), `P1` (a real defect or materially wrong design
decision with a plausible trigger), or `P2` (worth knowing, not
merge-blocking: hardening, unlikely edge cases, maintainability, non-critical
test gaps). The scale is defined in `scripts/codex-review.sh`, not inherited
from the Codex CLI's own labels, so the gate keeps its meaning if Codex
changes its output. **Only P0 and P1 gate the local loops.** Adjudicate P2s
too — never suppress or ignore one — but carry them to the PR-shepherd stage
rather than spending a local round on them. A P2 you judge worth fixing
immediately may of course be fixed in place; it just does not hold the stage
open.

**Deferring P2s.** The handoff is the **PR description**: list every deferred
P2 under a `## Deferred findings` heading as an unchecked task-list item —
`- [ ] <file:line> — <finding>` — with enough detail to adjudicate it later.
This is not bookkeeping: `task challenge` and `task review` run locally and
their output is ephemeral, and the cloud reviewer reposts only high-priority
findings, so a P2 that is not written into the PR body is simply lost.

Record each one **the moment you defer it**, and never twice. Challenge and
review both run before `gh pr create`, so there is usually no PR body to write
to yet: it goes to the per-branch sidecar in the git directory, and the sweep
for stray notes happens when you open the PR. The path, the reason it is keyed
by branch and lives outside the worktree, and the append-once matching rule
are the skill's (`.claude/skills/gauntlet/SKILL.md`), with the recipe in
[docs/guides/codex-review.md](docs/guides/codex-review.md) — this file states
only the obligation, because terminal scrollback is not a record: a context
reset between `task challenge` and `gh pr create` would take the findings with
it.

The shepherd stage settles every entry and **edits the PR body to tick it**
(`- [x] … — fixed in <sha>` / `declined: <reason>` / `filed as #<n>`) in the
same round. The checkbox is the resolution state: an entry left unchecked is
open work, so a later round — or a different session — can tell at a glance
what it still owes without re-adjudicating what is done. That obligation is
stated here and in the Dev Loop above, and holds whether or not the optional
`/shepherd` skill is installed to automate it.

**Loop cap and exit:** a stage — challenge and review counted separately —
ends when **two consecutive rounds adjudicate to zero P0 and zero P1
findings**, and never on "findings fixed" alone. Those rounds may be empty,
all-P2 as labeled, or P1-labeled and adjudicated down to P2; what counts is
the **adjudicated** column of the table, not the reviewer's label, and the
second such round is itself the confirmation, so no further run is owed. Two
exits are faster still. A round with **no findings at all** ends the stage by
itself **once the stage has run at least `min_rounds` rounds** (the per-tier
floor in `.devflow.toml`; 1 if the file is absent) — an empty round is exactly
the old rule's clean re-run, so neither a trivial change nor a clean post-fix
re-run pays for a confirmation pass, and the floor only stops that shortcut
being taken before the tier's minimum work has happened. Say plainly what
follows: the other two exits satisfy any floor of 2 or less **by
construction** — the two-consecutive exit runs two rounds by definition, and
the capped-clean exit runs the cap, which is never below 2 — so `min_rounds`
constrains the empty-round exit alone and needs no separate check on the
other two. And a **capped final round** that adjudicates to zero
P0/P1 also ends the stage by itself: the confirmation it would otherwise owe
is a run the cap forbids, and a rule that strands a stage holding a clean
last round and no valid exit would be wrong — the cap bounds work, it does
not manufacture escalation. What the rule spends is bounded the other way
too: a stage pays at most one round confirming convergence, where the old
practice could spend every remaining round re-proving a change nobody still
disputed. Two things ride along with the exit: every P2
deferred during the stage must already be recorded in the sidecar (an exit
that drops a P2 is not an exit), and round 2 owes the scaffolding checkpoint
above. Each stage's cap is the one resolved from `.devflow.toml` per "Round
caps are resolved, not stated here" in the Dev Loop above (challenge → fix →
re-challenge, and likewise for review), counted separately per stage; if
P0/P1 disagreement persists at the cap, stop and surface it to Evan instead
of iterating further — escalation at the cap is for P0/P1 that **persist**,
nothing else. Evan may always ask for more rounds — convergence is a
floor on when you may stop, not a ceiling on what he can order.

One caveat on the automatic stop-gate: the codex plugin's Stop hook applies
its **own** notion of a material finding and may BLOCK on something you have
classified P2. Adjudicate it (fix it, or state the reasoning) — **never**
disable the gate to get past a BLOCK. A BLOCK is settled on its own terms and
against the hook, not against this rule: it neither reopens a stage that has
already converged nor counts as one of that stage's rounds.

## Conventions

Full reference: [docs/conventions.md](docs/conventions.md). Highlights beyond
the workflow rules above:

- `group:action` Taskfile naming (e.g. `lint:shell`, not `shell:lint`); pin
  actions by SHA + `# vX.Y.Z`.
- **Never gate a template file on `skill_categories`** — filename, `[% if %]`,
  or a computed answer alike. The answer is recorded at scaffold time while
  consumers are told to change categories in `.skills-sync.yaml`, so a gate on
  it is permanently wrong for the repos it was meant to serve. Gate on
  `use_skills_sync` and check for the asset at runtime, the way
  `claim-release.yml` does. `task test:category-gates` enforces it; the
  reasoning is in [docs/conventions.md](docs/conventions.md) under "Template
  authoring".
- Git hooks are managed by lefthook (`lefthook.yml`) and delegate to Taskfile
  targets — don't duplicate logic in hooks or workflows.
- Secrets never go in git; local env via 1Password (`op run` / `op inject`).
- When generating or rotating secrets, keep secret values on stdin and use the
  destination-only helpers:
  `task secret:set:1p VAULT=... ITEM=... FIELD=... [SECTION=...]` for existing
  1Password fields and `task secret:set:gh NAME=... REPO=owner/repo` for GitHub
  repo secrets. Never pass secret values as command arguments, `--body` values,
  exported env vars, or Taskfile vars. The hard rule above still applies:
  agents must not run `secret:set:1p` or otherwise write to a password manager
  without explicit user confirmation for that exact write.
- The skills sync manages ONLY the directories listed on the `# managed:` line
  of `.claude/skills/.SKILLS_PROVENANCE`. Anything else under `.claude/skills/`
  is a local skill this repo owns; never hand-edit a vendored one — change it in
  harmon-devkit and bump the pin.

## Code Style

- Indentation: 2 spaces default; 4 spaces for Python/Terraform/Shell
  (see `.editorconfig`).
- Shell scripts must pass `shellcheck --severity=error` and `shfmt -d`, and stay
  portable across macOS bash 3.2 (no `mapfile`, no `grep -P`) and Linux.
- Keep Taskfile `cmds:` trivial. Inline command strings are **not** seen by
  `shellcheck`/`shfmt` (`lint:shell` only covers `scripts/*.sh`), so non-trivial
  logic — pipelines, conditionals, loops, `curl | bash`, anything with `&&`/`||`
  — belongs in a `scripts/*.sh` file that the task calls. `task test:tasks` guards
  the floor (the Taskfile compiles; setup tasks are safe no-ops), but extracting
  the shell is what actually gets it linted.
- YAML linted with yamllint; workflows with actionlint; markdown with
  markdownlint-cli2.
- Pin third-party GitHub Actions by commit SHA with a trailing version comment and
  manage tool versions with `# renovate:` datasource annotations.

## CI/CD

- `.github/workflows/build.yml` — jobs `lint`, `security`, `template-test` (matrix
  of copier answer profiles), and the aggregate `verify` gate. All jobs delegate to
  `task` targets.
- `.github/workflows/devcontainer-build.yml` — builds the dual-profile
  devcontainer images (bot + dev) and pushes them to GHCR as build caches. The
  root repo dogfoods the same `.devcontainer/` the template generates
  (`task test:devcontainer:root` / `test:devcontainer:dev` smoke-test them).
  Rendered template devcontainers are config-validated (`read-configuration` in
  `template-test`), **not** built per profile — the dogfood build covers every
  profile only because the template `Dockerfile` is kept free of copier
  conditionals (profile-invariant). See `docs/architecture/ci-cd.md`.
- `.github/workflows/publish-harmon-devcontainer.yml` — root-only producer for
  the public shared amd64/arm64 toolchain image. Candidate PRs build without
  registry credentials; trusted `main` publishes immutable source tags and the
  tested helper maintains one reviewed consumer-pin PR. See
  `docs/architecture/devcontainer-image.md`.
- `.github/workflows/claude-{plan,implement,review}.yml` — Claude Code GitHub
  Actions. They (and `release.yml`) authenticate as the CI **GitHub App**
  (`CI_APP_CLIENT_ID` variable + `CI_APP_PRIVATE_KEY` secret) and need the
  `CLAUDE_CODE_OAUTH_TOKEN` secret. See `docs/architecture/security.md`.
- Dependency updates via Renovate (`renovate.json`); second-model reviews use
  Codex.
- `release.yml` runs release-please: releases stay intentional (merge the rolling
  release PR to cut a tag); `task release:*` remains a manual override.
- `release-content-guard.yml` fails a PR that changes `template/` under a
  non-releasing title (see Development Workflow) — the guard logic is
  `scripts/require-release-title.sh` (unit-tested by `task test:release-title`),
  driven by the `RELEASE_CONTENT_PATHS` var on the `guard:release-title` task.
  Generated repos render the same guard from the `release_content_paths` copier
  answer (empty = no guard).
