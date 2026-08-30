# Conventions

How we do things in Harmon Init — the conventions a contributor (human or
AI) should follow. Most are **enforced** by git hooks (lefthook) and CI; the rest
is the residue a linter can't mechanize. A **flat lookup** — grep for the rule
you need rather than reading it through. `AGENTS.md` is the AI quick-reference;
it points here.

## Commits & git

- **Conventional Commits**, enforced by commitlint at the `commit-msg` hook.
  Allowed types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
  `refactor`, `revert`, `style`, `test`. Format
  `type(scope): subject`, imperative mood.
- **Subject and body lines ≤ 100 characters** (config-conventional).
- **Breaking changes:** `feat!:` (or a `BREAKING CHANGE:` footer) — drives a
  major bump.
- **Feature branches only.** Direct commits to `main` are blocked by the
  `guard:no-commit-to-main` pre-commit hook and the branch ruleset. Land changes
  via a PR; code-owner review and the `verify` + `security`
  checks are required.
- **Never bypass hooks** (`--no-verify` is forbidden) — fix the underlying issue.
  In the devcontainer a Claude Code hook actively blocks `--no-verify` and
  validates commit messages.
- **Ask before terminating processes.** `guard-process-kill.sh` is registered
  for Claude Code, Codex, and agy Bash commands. It requests approval for every
  terminating `kill`, `pkill`, `killall`, or `xkill` invocation; only direct
  `kill -l` and `kill -0 <PID>` probe segments are automatic. Do not infer that
  a PID belongs to the current session.
- Run **`task verify`** before pushing; the pre-push hook runs secret scanning
  (and type/IaC checks where applicable).

## Worktrees

- **`.worktrees/` is THE location** for linked git worktrees, and it is
  gitignored. Lint globs, security-scan excludes, and the copier-validator scans
  already assume it; put a tree anywhere else and those excludes stop applying.
- **Create them with `task worktree:new -- <name>`**, never a bare
  `git worktree add`. The task (`scripts/worktree-new.sh`) creates or attaches
  the branch — including one that exists only on a remote, which it tracks
  rather than recreating — installs **this tree's** dependencies, proves the
  git hooks fire inside it, prints the ready path, and rolls the tree back if
  any of that fails. A new branch is based on the **main worktree's HEAD**, not
  the caller's — and when that branch's configured upstream resolves, the base
  is first verified against it: behind means the fresh upstream tip is used
  (announced), diverged refuses with a `--base` remedy, so a tree never
  silently starts from stale history. Running the task from inside a worktree
  does not silently stack the new branch on that one; `--base HEAD` stacks
  deliberately. Creating a genuinely new branch also probes every configured
  remote for a same-named branch first — a branch that exists remotely is
  tracked, never recreated — so that path needs the remotes reachable: an
  offline run fails closed with the fix in the message, and an explicit
  `--base <ref>` skips the remote lookup entirely.
  `--branch` and `--no-install` cover the rest.
  One entrypoint means a second agent session, a terminal multiplexer, or a
  human all get the same tree instead of each rediscovering the setup.
- **Remove them with `task worktree:rm -- <name>`** (`--force` to discard
  uncommitted work). It refuses on uncommitted changes **and** on ignored local
  files such as a `.env` — `git worktree remove` counts modified and untracked
  files but not ignored ones, so a plain remove would take those with it.
  Edits hidden by `skip-worktree`/`assume-unchanged` refuse too, a deleted
  flagged file included. In a sparse checkout an absent flagged path is exempt
  only when the tree's active sparse rules exclude it (asked via
  `git sparse-checkout check-rules`); on git < 2.42, which lacks
  `check-rules`, the exemption deliberately stays per-tree rather than
  failing closed, so clean sparse worktrees remain removable on e.g. macOS
  system git (harmon-init#919).
  Ignored *directories* (`node_modules/`, `.venv/`, `dist/`) do not block it:
  `worktree:new` reinstalls them, and refusing there would make `--force`
  routine and so meaningless. It also prunes the registry and clears leftover
  gitlink directories — stale ones make later tooling treat a dead path as a
  live checkout.
- **Sweep leftover admin records with `task clean:worktree-records`**, never a
  raw `git worktree prune` — a stale record's detached HEAD can be the only
  thing keeping a commit alive, and a raw prune makes it unreachable. The task
  removes records only (never a worktree directory), refuses records carrying
  single-copy state, and pins a detached commit as
  `refs/session-cleanup/pin/<record>` *before* the record goes; pins are
  settled only by explicit human action (`task audit:session-artifacts` lists
  the pending ones). Removal serializes with `worktree:new`/`worktree:rm`
  through the shared lifecycle lock — for trees under the blessed
  `.worktrees/` layout; a tree from a raw `git worktree add` elsewhere is
  outside that protocol — as is a `git worktree lock` racing the removal
  itself — which is the documented residual for keeping to the tasks.
- **A fresh worktree has no `node_modules`/`.venv`.** Working files are per-tree,
  so dependency install is per-tree too; that is what `worktree:new` runs and
  why "it worked in the main checkout" is not evidence.
- **The Node installer is selected from the repo's own signals** — a
  `package.json` alone proves "Node repo", never "pnpm repo". Precedence:
  the `packageManager` field in `package.json` (the Corepack declaration)
  wins — including over a stale foreign lockfile, when its own manager's
  files are present; otherwise exactly one manager's files at the tree
  root — `pnpm-lock.yaml`/`pnpm-workspace.yaml` → pnpm,
  `package-lock.json`/`npm-shrinkwrap.json` → npm, `yarn.lock` → Yarn,
  `bun.lock`/`bun.lockb` → Bun. Every contradiction fails loudly before
  any install touches the tree: files from two managers with no
  declaration, a declaration whose manager has no files here while other
  managers' files exist (installing would write a second lockfile), an
  unsupported `packageManager` value, and a declared numeric major that
  the installed binary does not match (a drifted major can rewrite the
  committed lockfile; corepack-shimmed binaries report the pinned version
  and pass). When the selected manager's own lockfile exists the install
  runs in its immutable mode (`npm ci`, `--frozen-lockfile`, Yarn Berry
  `--immutable`), so lockfile drift fails and rolls back instead of
  rewriting a committed file; with no lockfile, plain `install` runs and
  may create one. A bare `package.json` with no signal skips the install
  with a note — declare `packageManager` to make it deterministic.
- **Never pass `-c core.hooksPath=.git/hooks` to git in a worktree.** In a
  linked worktree `.git` is a **file**, not a directory, so that path resolves
  to nothing and commits run **hook-less and silently**. Git's own defaults are
  correct: hooks live in the shared `$GIT_COMMON_DIR/hooks` and
  `git rev-parse --git-path hooks` resolves them from any tree. Plain
  `git commit` is the right command.
- **Devcontainer smoke tests are an explicit exclusion.** Only the workspace
  folder is mounted, and a linked worktree's `.git` file points outside it, so
  post-create sees no repository. `scripts/devcontainer-smoke.sh` detects this
  and says so instead of failing opaquely. Run it from the main checkout, or
  build the image and `docker run` it directly.

## Task runner (Taskfile)

- Tasks are named **`group:action`** — the group/domain comes first, the action
  is the leaf: `lint:shell`, `lint:typescript`, `test:e2e`, `security:secrets`,
  `install:hooks`, `status:git`. **Never action-first** (`typescript:lint`,
  `yaml:lint`).
- Pipeline order is **`check → build → validate → test → security`**, with
  `verify` and `ci` as the aggregates. `check` is the fast inner-loop/hook gate
  (lint only). `verify` is the definition-of-done gate — `check` + the
  Taskfile/hook/dogfood guards + this repo's test tier, which renders the whole
  template via `test:template` and is therefore heavier than a generated repo's.
  `ci` is the full CI mirror — `verify` + the network skills-drift check
  (`verify:skills`) + the devcontainer permission assert + `security`. A check
  the build workflow **gates on** and that can run locally belongs in `ci` too,
  or the mirror quietly stops being one. The one exception is a check that needs
  **CI-only infrastructure**: document it in `AGENTS.md` as an exception instead
  of faking it locally.
- **`lint:*` and `check` are read-only gates** — they report and fail, never
  modify files. All auto-fixing lives in **`task format`**, **`task format:file
  -- <path>`**, and **`task fix`** (= format then lint). Pre-commit hooks run the
  read-only `lint:*`, so a failing check **blocks the commit and tells you** to
  run `task format` rather than silently rewriting your tree.
- Formatters (e.g. Prettier, Black, shfmt, `terraform fmt`, markdownlint) expose
  a check side in `lint:*` and a write side in `format`; pure analyzers (e.g.
  shellcheck, actionlint, yamllint, ESLint) are check-only by design.
- **Workflows delegate to `task` targets** so local hooks, CI, and humans run
  identical commands — the Taskfile is the single source of truth. Don't
  reimplement command logic in a workflow or a hook.

## Code style

- Indentation: **2 spaces** by default; **4 spaces** for Python, Terraform, and
  Shell (`.editorconfig`). Final newline; trim trailing whitespace (except
  Markdown/MDX).

## TODOs

- Mark unfinished work with `TODO: <description>` — the literal `TODO:` prefix, in
  code and docs alike, so it stays greppable (`rg 'TODO:'`).

## YAML, Markdown & shell

- **YAML:** 2-space indent, linted by yamllint. Use whichever extension
  (`.yml` or `.yaml`) each tool conventionally uses (e.g. `Taskfile.yml`,
  `.yamllint.yml`) — don't normalize extensions repo-wide.
- **Markdown:** markdownlint — ATX headings, no duplicate headings, emphasis and
  strong markers consistent within a file; line-length and first-line-heading
  rules are off.
- **Shell:** must pass `shellcheck --severity=error` and `shfmt -d`, and stay
  portable to macOS bash 3.2 (no `mapfile`, no `grep -P`).

## CI / GitHub Actions

- **Pin third-party actions by full commit SHA** with a trailing `# vX.Y.Z`
  comment, and annotate tool versions with `# renovate: datasource=…` so
  Renovate keeps them current.
- Third-party CI/SaaS integrations that require an account, app installation,
  trial, or payment must be explicit opt-ins that default off. Document free-tier
  and private-repository limitations before adding them to generated output.
- **Least-privilege `permissions:`** per job; never log secrets.
- CI authenticates as the **`evanharmon1-ci` GitHub App** (short-lived
  tokens), not a PAT — see [architecture/security.md](architecture/security.md).

## Secrets

- Local env comes from **1Password** (`op run` / `op inject`); CI reads GitHub
  Actions secrets. `gitleaks` runs on pre-push and in CI.
- When generating or rotating secrets, keep the value **on stdin** and use the
  destination-only helpers: `task secret:set:1p VAULT=… ITEM=… FIELD=…
  [SECTION=…]` for existing 1Password fields, `task secret:set:gh NAME=…
  REPO=owner/repo` for GitHub repo secrets. Never pass secret values as command
  arguments, `--body` values, exported env vars, or Taskfile vars — they end up
  in shell history and process listings.

## Docs & AI steering

- **`AGENTS.md` is the single source of truth** for AI guidance; `CLAUDE.md`,
  `GEMINI.md`, and `.github/copilot-instructions.md` are **symlinks** to it —
  edit only `AGENTS.md`.
- **`.devflow.toml` is the single source of truth for rigor/strategy
  execution-policy values** (review-pass caps, role tiers, budgets,
  topologies); [docs/guides/devflow.md](guides/devflow.md) expands the model
  and the resolution rules, `AGENTS.md` states only resolution mechanics, and
  neither restates the config's numbers.
- **Vendored vs local skills:** the skills sync manages ONLY the directories
  listed on the `# managed:` line of `.claude/skills/.SKILLS_PROVENANCE`. Any
  other directory under `.claude/skills/` is a **local skill owned by this
  repo** — create, edit, and delete it freely; `task sync:skills` and the
  `verify:skills*` drift checks never touch or report it. Never hand-edit the
  managed (vendored) skills — change them in harmon-devkit and bump the pin.
- **Vendored vs local agents:** the same rule, one directory over. The
  `agents:` block in `.skills-sync.yaml` vendors harmon-devkit's shared
  subagents into `.claude/agents/`, and the sync manages only the files on the
  `# managed:` line of `.claude/agents/.AGENTS_PROVENANCE`. Agents are pinned by
  the **same `source.ref` as the skills** — deliberately, because a shared agent
  is thin and defers to a skill by reading it, so two pins that could disagree
  would leave an agent following a procedure that no longer exists.
- **The sync engine must not lag the manifest.** `scripts/sync-skills.sh` and
  its `template/` twin are copied verbatim from a harmon-devkit release. An
  engine older than a manifest feature **ignores it silently** — one predating
  `agents:` support vendors the skills, exits 0, and never mentions the block it
  skipped, and its `verify` is silent too. No handshake can catch that: a
  released program cannot recognise a future manifest key. So when a devkit
  release adds a manifest feature, update the engine in the same change as the
  manifest that uses it.
- **Doc filenames are kebab-case** (`branch-protection.md`, `ci-cd.md`). The
  conventional uppercase project files keep their names: `README.md`,
  `AGENTS.md`, `DESIGN.md`, `CHANGELOG.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `LICENSE`, `CHECKLIST.md`.
- Documentation layering: `docs/product/` (why/where) · `specs/` (what to build)
  · `docs/architecture/` (how) · `docs/decisions/` (ADRs, date-named
  `YYYY-MM-DD-…`; older records keep their `0001-` names) ·
  `docs/guides/` (build it) · `docs/runbooks/` (operate it). Folder landing
  pages are `README.md`.

## Template authoring

Root-only — these rules govern files under `template/`, which no generated repo
has.

- **Never gate a template file on `skill_categories`.** Not a filename
  condition, not a `[% if %]`, not a computed answer's `default:`/`when:`.
  `task test:category-gates` enforces this (`scripts/test-category-gates.sh`,
  in both `verify` and the CI lint job).

  The guard works by **allowlist**: every occurrence of the answer under
  `template/` fails unless it is listed in the script with a reason (today,
  three — the `.skills-sync.yaml` seed loop and two prose mentions). So adding
  a legitimate new mention costs one allowlist line, and that line is the point
  — it forces the "is this a gate or a seed?" question at review time. An
  earlier revision enumerated the *banned* forms instead and was evaded three
  times in three review rounds by ordinary Jinja (a wrapped conditional,
  `[%+ if`, `[% if(...)`); a denylist over an open-ended grammar can only be as
  complete as the last author's imagination, and it reports success over
  everything it failed to imagine.

  The answer is recorded once at scaffold time, but the documented way to change
  categories afterwards is to edit `.skills-sync.yaml` — said by the question's
  own help text and by the generated manifest's header. That edit never updates
  the answer, and `copier update` applies the **template's** diff rather than
  overwriting, so the consumer's manifest edit survives while the answer stays
  stale permanently. The manifest is what `task sync:skills` reads, so the
  skills vendor correctly; only a file gated on the answer breaks — silently,
  and on every future update, in exactly the repos it was meant to serve.

  **Instead:** gate on `use_skills_sync` (whether the repo vendors skills at
  all — an answer that cannot drift) and have the shipped file check for the
  asset it needs at **runtime**.
  [`claim-release.yml`](../.github/workflows/claim-release.yml) is the worked
  example: it renders whenever the skills sync is on, and its `run:` guard exits
  0 with a notice when `release-claim.sh` is absent. Iterating the answer to
  *seed* a file — how `.skills-sync.yaml` gets its category list — stays
  correct; it is the conditional use that rots.

  Written after `claim_release_available` shipped as
  `use_skills_sync and 'universal' in skill_categories` and was caught in
  review ([#622](https://github.com/evanharmon1/harmon-init/issues/622) carries
  the analysis and the options weighed).

- The same shape of question is worth asking of **any** answer a consumer is
  told to edit elsewhere: if the file is the source of truth, the answer is a
  seed, and gating on a seed is a bug that only appears months later.

## Releases

- Releases are intentional via **release-please**: merge the rolling release PR
  to cut the tag, GitHub release, and CHANGELOG entry. `task release:*` remains a
  manual override. Nothing auto-releases on a normal merge.
- **The commit type drives the release.** release-please reads the type to pick
  the CHANGELOG section and bump: `feat` → **Features** (minor), `fix` → **Bug
  Fixes** (patch), `feat!` / `BREAKING CHANGE:` → major. The rest (`build`,
  `chore`, `ci`, `docs`, `perf`, `refactor`, `revert`, `style`, `test`) don't cut
  a release on their own — they ride along in the next one.
- **On a squash-merge repo the PR title *is* the release type.** GitHub sets the
  squash commit subject from the PR title for a multi-commit PR, and release-please
  reads only that subject — the individual `fix:`/`feat:` commits inside the PR are
  invisible in the squashed body. So a PR whose title is `chore:`/`docs:` merges
  with **no release**, even when it carries releasable content. The
  **release-content guard** (`release-content-guard.yml` →
  `scripts/require-release-title.sh`, unit-tested by `task test:release-title`)
  fails a PR that changes release-worthy paths under a non-releasing title. For
  harmon-init that path is `template/` (all consumers get it via `copier update`
  to a tag); generated repos configure their own via the `release_content_paths`
  copier answer (empty = no guard). Automated dependency PRs (Renovate/Dependabot)
  are skipped — retitle by hand if a dep bump to guarded content must ship.
- **Closing an issue is guarded separately.** The `closing-keywords` job in
  `build.yml` reads only PR and issue metadata with a read-only token, and scans
  the PR title, body, and every commit message for
  `Closes`/`Fixes`/`Resolves` references.
  A bare `#N` is same-repository work: the gate refuses it while issue `#N`
  has unchecked task-list items, or when it cannot read that issue. Explicit
  references that name another repository are informational because this
  repository cannot safely decide another repository's close policy. Use
  `Refs #N` for partial work. The check reruns when a PR is edited or new
  commits are pushed; run `task guard:closing-keywords` to pre-flight it.
- Issue types map many-to-one onto these commit types. Personal-account repos
  use the equivalent work-type labels as that mapping's substrate because native
  issue Type is unavailable there; organization repos use native Type and no
  work-type label. See [project-management.md](project-management.md).
- **Milestones use an explicit naming mode**: a version milestone is named after
  its git tag (`v1.1.0`), while a rolling-release or tooling repo may use a
  finite scope-batch name when the version is not a planning input. See
  [project-management.md](project-management.md).
