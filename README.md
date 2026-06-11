# Harmon Init

A [Copier](https://copier.readthedocs.io/en/stable/) project template that
bootstraps repos with a complete set of standardized conventions: go-task
Taskfile, lefthook git hooks, conventional commits, GitHub Actions CI (with
Claude Code plan/implement/review workflows), gitleaks/snyk/CodeQL security,
Renovate, CodeRabbit, a dual-profile devcontainer (AI bot + human) with GHCR
prebuilds, a docs tree, and AI steering docs (canonical `AGENTS.md`). It can
also be applied to existing repos to standardize them.

Author: Evan Harmon

[![Build & Validate](https://github.com/evanharmon1/harmon-init/actions/workflows/build.yml/badge.svg)](https://github.com/evanharmon1/harmon-init/actions/workflows/build.yml)
[![Copier](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/copier-org/copier/master/img/badge/badge-grayscale-inverted-border-orange.json)](https://github.com/copier-org/copier)
[![Renovate](https://img.shields.io/badge/maintained%20with-renovate-blue?logo=renovatebot)](https://github.com/apps/renovate)

## Usage

### New project

```bash
copier copy harmon-init new-project --trust
```

Key questions: `project_type` (general | web-astro | web-app | iac | docs),
`github_org`, `ci_runner` (ubuntu-latest | self-hosted), `devcontainer`,
`include_terraform` / `include_ansible`, `license`. Hidden defaults (author
identity, org info, directories) live in `copier.yml` under `when: false` —
customize those once before first use.

After generation, work through the project's `docs/CHECKLIST.md` (branch
ruleset import, Dependabot alerts, Renovate/CodeRabbit apps, Actions secrets,
framework scaffolding for web projects).

### Apply to / update an existing project

```bash
cd existing-project
copier update --trust          # if it was generated from this template
# or adopt the template in a repo that wasn't:
copier copy --trust ~/git/harmon-init . --vcs-ref=HEAD
```

### Template development gotcha: `--vcs-ref=HEAD`

`copier copy` from a local path renders the **latest git tag** by default —
NOT your working tree. When testing template changes, always pass
`--vcs-ref=HEAD`. With it, copier auto-includes dirty/untracked changes via a
throwaway commit in a temp clone (`DirtyLocalWarning`); your working tree is
never touched. `task test:template` handles this for you.

## Architecture: two layers

1. **Root** — tooling for maintaining the template itself (this Taskfile,
   lefthook, CI). The root dogfoods the same conventions the template
   generates.
2. **`template/`** — the Copier template root (`_subdirectory: template`).
   Everything here becomes the generated project.

### Custom jinja delimiters

Template files use `[[ var ]]` and `[% if x %]` (set via `_envops` in
`copier.yml`) so GitHub Actions `${{ }}`, go-task `{{.VAR}}`, and lefthook
`{staged_files}` appear verbatim with zero escaping. Rules of thumb:

- Never use bash `[[ ]]` tests inside `.jinja` files — use `[ ]`.
- An inline `[% endif %]` at end-of-line eats the next newline
  (`trim_blocks`) — write `[% endif +%]`.
- Shell scripts that don't need substitution stay plain (not `.jinja`).

## Testing the template

```bash
task verify                # lint + full generation matrix
task test:template         # all answer profiles (minimal/web/iac/full)
task test:template:web     # one profile
```

Each profile renders into a temp dir and validates the output: symlinks
(CLAUDE.md/GEMINI.md → AGENTS.md), Taskfile parses, no leaked copier
variables, actionlint, yamllint, lefthook config, shellcheck/shfmt on
rendered scripts, JSON validity, devcontainer read-configuration (CI), and
gitleaks. CI runs the same matrix on every PR (`template-test` jobs in
`build.yml`).

## Releases

Releases are intentional — `task release:patch|minor|major`. Nothing
auto-releases on merge to main. Generated projects render from the latest
tag, so **tag a release** after merging template changes you want consumers
to receive.

### v2 → v3

v3.0.0 was a breaking redesign: new question set (`project_type`,
`github_org`, `ci_runner`, ...), custom jinja delimiters, lefthook+gitleaks
replacing pre-commit+whispers, manual releases, dual-profile devcontainer,
and canonical AGENTS.md. Projects generated from v2 should be re-templated
(`copier copy` over the repo and reconcile) rather than `copier update`d.

## Repo maintenance commands

| Command | What it does |
|---|---|
| `task verify` | Lint + template generation matrix (merge gate) |
| `task check` | Root linters (template/ excluded — jinja isn't valid YAML) |
| `task security:secrets` | gitleaks scan |
| `task install` | Brewfile deps + lefthook hooks |
| `task release:patch` | Tag + GitHub release (also `:minor`/`:major`) |
