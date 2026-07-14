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
[![Devcontainer Build](https://github.com/evanharmon1/harmon-init/actions/workflows/devcontainer-build.yml/badge.svg)](https://github.com/evanharmon1/harmon-init/actions/workflows/devcontainer-build.yml)
[![Open in Dev Containers](https://img.shields.io/static/v1?label=Dev%20Containers&message=Open&color=blue&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/evanharmon1/harmon-init)
[![Latest Release](https://img.shields.io/github/v/release/evanharmon1/harmon-init?sort=semver)](https://github.com/evanharmon1/harmon-init/releases)
[![Renovate](https://img.shields.io/badge/maintained%20with-renovate-blue?logo=renovatebot)](https://github.com/apps/renovate)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Copier](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/copier-org/copier/master/img/badge/badge-grayscale-inverted-border-orange.json)](https://github.com/copier-org/copier)

## Part of harmon-platform

This repo is part of **harmon-platform** — my custom development platform with machine configuration, DevOps systems, homelab infrastructure, and automation repos that work together to help me develop software and manage my homelab.

| Repo | What it is |
| --- | --- |
| [**harmon-init**](https://github.com/evanharmon1/harmon-init) **(this repo)** | Copier template that bootstraps & standardizes new repos (CI/CD, devcontainers, AI steering, tooling). |
| [harmon-devkit](https://github.com/evanharmon1/harmon-devkit) | Reusable boilerplates & code templates, standalone scripts, and AI assets (skills, prompts, agents). |
| [harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) | Shell & app dotfiles, managed declaratively with chezmoi. |
| [harmon-ops](https://github.com/evanharmon1/harmon-ops) | Personal machine bootstrapping, package management & dev-environment setup across macOS/Windows/Linux. |
| [harmon-infra](https://github.com/harmonops/harmon-infra) | Homelab infrastructure as code — Terraform, Ansible, and Docker Compose services. |

## Usage

### New project

```bash
# Update the ref deliberately when adopting a newer harmon-init release.
copier copy --trust --vcs-ref=v3.26.1 \
  https://github.com/evanharmon1/harmon-init.git new-project
```

Use the canonical GitHub source and a released tag for a real project. That
gives Copier a durable source/commit lineage it can fetch again during future
`copier update` runs. A local dirty `HEAD` is for template development and
pre-release previews only.

Key questions: `project_type` (general | web-astro | web-app | iac | docs),
`github_org`, `ci_runner` (ubuntu-latest | self-hosted), `devcontainer`,
`include_terraform` / `include_ansible`, `license`. Hidden defaults (author
identity, org info, directories) live in `copier.yml` under `when: false` —
customize those once before first use.

After generation, work through the project's `docs/CHECKLIST.md` (branch
ruleset import, Dependabot alerts, Renovate/CodeRabbit apps, Actions secrets,
framework scaffolding for web projects).

### Apply to / update an existing project

Which copier operation to use depends on the repo's situation. The
**standardize-repo** skill (in harmon-devkit) detects the situation and runs the
right one for you; the underlying commands are:

| Situation | Operation |
|---|---|
| New, empty project | `copier copy` (scaffold) |
| Existing repo, never templated, **or** generated from **v2** (pre-v3 breaking redesign) | `copier copy` from the canonical GitHub source at a released ref, then reconcile by hand |
| Existing repo generated from **v3+** (has `.copier-answers.yml`) | `copier update` (three-way merge) |

```bash
cd existing-project
copier update --trust            # v3+ repo: merge in the latest template
# or, to adopt a repo that was never templated / is on v2:
copier copy --trust --vcs-ref=v3.26.1 \
  https://github.com/evanharmon1/harmon-init.git .
```

#### How updates keep repos current (copier's three-way merge)

`copier update` does **not** overwrite your files. It re-renders the template at
the version your repo was last generated/updated from (recorded in
`.copier-answers.yml`), diffs that against the latest template, and applies just
that delta to your working tree as a three-way merge. So:

- **Template improvements flow in** — a new README section, a fixed `bootstrap`
  task, an updated `status.sh` land in your files automatically.
- **Your customizations are preserved** — edits to template-owned files (a project
  task in `Taskfile.yml`, a custom `status` section in `scripts/status.sh`) survive;
  only a region you *and* the template both changed becomes a conflict to resolve.
- **No special repo structure** — generated repos stay plain. Customize files **in
  place**; there's nothing harmon-init-specific to learn to work in one, and no
  "template-owned vs custom" file split. (Reconcile a conflict by keeping *both*
  the template's change and your edit in the same file — never extract anything
  into a separate file.)

Two `copier.yml` settings keep updates safe (both invisible to repo users):

- First-run `_tasks` (git init, the initial commit, `gh repo create`,
  `release:init`, the macOS meta moves) are gated on `_copier_operation == 'copy'`,
  so `copier update` never makes a spurious commit, re-inits git, or re-cuts a
  release.
- `_skip_if_exists` is kept to just **`CHANGELOG.md`** (owned by release-please).
  Everything else is deliberately left out so the three-way merge can deliver its
  improvements to existing repos — listing a file there *freezes* it and blocks all
  template updates to it.

For the repeatable, verified workflow (preview drift → update → reconcile → verify),
use the standardize-repo skill's **`update`** mode; it ships `diff-template.sh`,
which shows exactly which template-owned files are behind the template.

### Template development gotcha: `--vcs-ref=HEAD`

`copier copy` from a local path renders the **latest git tag** by default —
NOT your working tree. When testing template changes, always pass
`--vcs-ref=HEAD`. With it, copier auto-includes dirty/untracked changes via a
throwaway commit in a temp clone (`DirtyLocalWarning`); your working tree is
never touched. That temporary commit may not exist on the canonical remote, so
do not use a dirty local `HEAD` to establish a real project's Copier lineage and
do not "repair" it by rewriting only `_src_path` in `.copier-answers.yml` unless
the recorded `_commit` is verified reachable from the canonical source. `task
test:template` handles the local preview correctly for template development.

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
task test:template         # all answer profiles (minimal/web/iac/full/meta) + update
task test:template:web     # one profile
task test:template:update  # `copier update` is safe: improvements merge in,
                           # repo edits + CHANGELOG survive, no churn or conflicts
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
| `task status` | Project dashboard (also `status:git`/`:gh`/`:code`/`:env`) |
| `task status:setup` | Setup audit: GitHub config, toolchain, devcontainer, dev env |
