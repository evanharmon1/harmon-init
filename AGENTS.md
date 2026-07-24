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

## harmon-platform

One of five repos in **harmon-platform** (Evan's developer & DevOps platform + homelab):
[**harmon-init**](https://github.com/evanharmon1/harmon-init) (this repo — the template),
[harmon-devkit](https://github.com/evanharmon1/harmon-devkit) (boilerplates/scripts/AI assets),
[harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) (chezmoi dotfiles),
[harmon-ops](https://github.com/evanharmon1/harmon-ops) (machine setup),
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
both. For **verbatim** twins — template files *without* a `.jinja` suffix, copied
byte-for-byte into generated repos — `task test:dogfood-parity` (part of `task
verify`) enforces byte-equality with the root copy, so a fix applied to only one
side fails the gate instead of silently shipping stale content downstream
(intentional root-only divergences are allowlisted in
`scripts/test-dogfood-parity.sh`).

The **standardize-repo skill** is vendored at `.claude/skills/standardize-repo`
(so the devcontainer and cloud claude-* workflows can use it); the canonical copy
lives in harmon-devkit (`ai/skills/repo/standardize-repo`). The root repo
dogfoods the same pinned skills sync the template ships: `.skills-sync.yaml`
pins a released harmon-devkit tag, `task sync:skills` vendors the `repo`
category into `.claude/skills`, and CI/pre-push run `task verify:skills` /
`verify:skills:offline` as drift checks. After a harmon-devkit release, bump
the `ref` pin, run `task sync:skills`, and commit the refresh.

## Common Commands

```bash
# Generate a new project from this template
copier copy harmon-init new-project --trust

# Local verification gate (lint + fast guards + template generation tests)
task verify

# Full CI mirror on demand (verify's checks + devcontainer assert + security)
task ci

# Lint only
task check

# Render the template into a temp dir and validate the output
task test:template

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

**Foreman** (`scripts/foreman/`, `taskfiles/foreman.yml`) is the deterministic
supervisor for milestone-driven agent dispatch: explicit arming via
`foreman:*` labels (issue fields on org repos), hardened doneness, a strict
write contract, and **never a merge** — see `docs/architecture/foreman.md`
and ADR 0002. It ships to generated repos, so its files are two-layer twins.

## Dev Loop

Bias toward shipping: drive every change to an open PR instead of stopping at
a green local diff. Work in small, PR-sized units, and move to the next stage
on your own — an open PR with green checks is the default deliverable, not
something to ask permission for.

- **Branch** — feature branch off `main`; never commit directly to `main`.
- **Edit + `task check`** — the fast inner loop; run it constantly and fix
  lint immediately. (Remember dogfood parity: template twins in the same
  change.)
- **`task verify`** — when the change feels done, loop edit → verify until
  green; verify is the definition-of-done gate (includes the render matrix).
- **`task challenge`** — adversarial second-model review. Adjudicate per
  "Second-Model Review" below, fix confirmed findings, re-run `task verify`,
  then **re-run `task challenge`**. The stage passes only when a re-run comes
  back with **no material findings** — fixing the findings is not the exit
  condition, a clean pass is. Max **5** challenge → fix → re-challenge
  rounds; if findings persist, stop and escalate to Evan.
- **`task review`** — verification-checkpoint review; same adjudication and
  same clean-pass exit condition, with its own max **4** rounds.
- **`task ci`** — the full CI mirror; fix anything it catches.
- **Open the PR** — conventional commit, push the branch, `gh pr create` with
  a clear what/why/verification summary (mind the `template/` → `fix:`/`feat:`
  title rule below).
- **Shepherd the PR (max 4 rounds).** Opening the PR is not the end. Watch CI
  (`gh pr checks <n> --watch`) and incoming bot/human reviews. When a check
  fails or a review lands findings, treat the findings as hypotheses: verify
  them against the code, fix only what's confirmed, explain rejections in a
  PR comment, push the fix commit, and watch again. Shepherd-round fixes
  must pass `task verify` before each push; the local challenge/review loops
  are not re-entered — the post-push cloud/bot review is the second-model
  check at this stage. This cap is independent of the other loop caps. If
  checks still fail or material findings remain after 4 rounds, stop and
  summarize what's unresolved on the PR for Evan.
- **Stop at green.** Report that checks pass, then stop — merging is always a
  human decision.

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
  `verify` + `security` + `codeql-verify` status checks.
- **Agents never merge to main** — no `gh pr merge`, `git merge`, or push to
  `main` without Evan's explicit, per-merge approval, even when CI is green and
  the ruleset would allow it. Open the PR, report that checks pass, then stop;
  merging is always a human decision. (`.claude/settings.json` backstops this
  with `permissions.ask` rules on merge commands.)
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
before `task ci`. Codex cloud review is also connected to this repo's PRs —
it posts inline comments only for high-priority findings; a bare 👍 reaction
from the Codex bot is its clean pass, and a lone 👀 that never resolves means
the cloud run failed.

**Treat Codex findings as hypotheses, not authority.** For every finding:

1. Verify it against the actual implementation, surrounding code,
   requirements, and tests.
2. Classify it: confirmed, plausible but unproven, or false positive.
3. Fix only confirmed findings; add or improve regression tests where
   appropriate.
4. Explain why any rejected finding is incorrect or irrelevant.
5. Re-run `task verify` (and the other relevant gates) after fixes.
6. Finish with a concise adjudication table: finding → classification →
   evidence → action taken.

**Loop cap and exit:** a stage exits only on a **clean re-run** (no material
findings) — never on "findings fixed" alone — with at most **5** challenge
iterations and **4** review iterations (challenge → fix → re-challenge, and
likewise for review). If material disagreement persists at the cap, stop and
surface it to Evan instead
of iterating further.

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
