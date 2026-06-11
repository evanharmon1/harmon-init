# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Gemini CLI, Codex, etc.)
working in this repository. `CLAUDE.md` and `GEMINI.md` are symlinks to this file —
edit only `AGENTS.md`.

## Project Overview

Harmon Init is a **Copier project template** that scaffolds new repos with
pre-configured DevOps tooling, CI/CD, linting, security checks, git hooks, and task
runners — and can also be applied to existing repos to standardize them. This is NOT
an application; it is a template repository used via the
[Copier](https://copier.readthedocs.io/en/stable/) templating tool.

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

## Common Commands

```bash
# Generate a new project from this template
copier copy harmon-init new-project --trust

# Local verification gate (lint + template generation tests) — run before pushing
task verify

# Lint only
task check

# Render the template into a temp dir and validate the output
task test:template

# Secrets scan
task security:secrets

# Releases are INTENTIONAL — never automated on merge to main
task release:patch   # or release:minor / release:major
```

## Critical Copier Gotchas

- **`--vcs-ref=HEAD` is load-bearing.** Without it, `copier copy` from a local path
  renders the **latest git tag**, silently ignoring all uncommitted AND committed-
  but-untagged work. With it, copier auto-includes dirty/untracked changes via a
  throwaway commit in a temp clone (`DirtyLocalWarning`) — your working tree is
  never touched. `scripts/test-template.sh` always passes it.
- Side-effectful copier answers (`bunch_add`, `github_remote_create`,
  `github_release_init`, `run_task_install`) must default to **no** so
  `copier copy --defaults` is CI-safe.
- After changing `copier.yml` or anything in `template/`, `task test:template:all`
  must pass.

## Development Workflow

- No direct commits to main (enforced by lefthook `guard:no-commit-to-main` and the
  branch ruleset). Work on feature branches; PRs require code-owner review and the
  `verify` + `security` status checks.
- Git hooks are managed by **lefthook** (`task install:hooks`); every hook delegates
  to a Taskfile target so local hooks, CI, and manual runs execute identical
  commands. Never bypass hooks with `--no-verify`.
- Commit messages follow **Conventional Commits** (enforced by commitlint):
  types `build, change, chore, ci, docs, feat, fix, perf, refactor, remove, revert,
  style, test`.

## Code Style

- Indentation: 2 spaces default; 4 spaces for Python/Terraform/Shell
  (see `.editorconfig`).
- Shell scripts must pass `shellcheck --severity=error` and `shfmt -d`, and stay
  portable across macOS bash 3.2 (no `mapfile`, no `grep -P`) and Linux.
- YAML linted with yamllint; workflows with actionlint; markdown with
  markdownlint-cli2.
- Pin third-party GitHub Actions by commit SHA with a trailing version comment and
  manage tool versions with `# renovate:` datasource annotations.

## CI/CD

- `.github/workflows/build.yml` — jobs `lint`, `security`, `template-test` (matrix
  of copier answer profiles), and the aggregate `verify` gate. All jobs delegate to
  `task` targets.
- Dependency updates via Renovate (`renovate.json`); reviews assisted by CodeRabbit
  (`.coderabbit.yaml`).
- No auto-release workflow exists by design — use `task release:*`.
