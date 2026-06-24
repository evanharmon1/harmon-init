# Changelog

All notable changes to harmon-init are documented here. Versioning is
[SemVer](https://semver.org) via git tags. Releases are intentional:
release-please maintains a rolling release PR from conventional commits — merge
it to publish the tag, GitHub release, and changelog entry. `task release:*`
remains a manual override. New entries are appended above by release-please;
entries at and below v3.0.0 were hand-written in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) style.

## [3.2.1](https://github.com/evanharmon1/harmon-init/compare/v3.2.0...v3.2.1) (2026-06-24)


### Bug Fixes

* **template:** skip private vulnerability reporting on private repos ([#93](https://github.com/evanharmon1/harmon-init/issues/93)) ([8c755e2](https://github.com/evanharmon1/harmon-init/commit/8c755e2f7b43d6637f7cd1aa05b7621c25cce1de))

## [3.2.0](https://github.com/evanharmon1/harmon-init/compare/v3.1.1...v3.2.0) (2026-06-24)


### Features

* **devcontainer:** delegate Claude hooks to Taskfile and add permission tests ([#88](https://github.com/evanharmon1/harmon-init/issues/88)) ([00b4217](https://github.com/evanharmon1/harmon-init/commit/00b4217dcb1cb352525399e1208e7cfe5d44d7f6))
* **template:** add `task setup:github` for idempotent repo settings ([#86](https://github.com/evanharmon1/harmon-init/issues/86)) ([88a0940](https://github.com/evanharmon1/harmon-init/commit/88a0940c6f7337807693341c553f353bbfa30450))
* **template:** add code_owner question and improve issue/PR templates ([#89](https://github.com/evanharmon1/harmon-init/issues/89)) ([af4e742](https://github.com/evanharmon1/harmon-init/commit/af4e742e2bbc5e2fe57b016ece62169b82ec4121))


### Bug Fixes

* **template:** markdownlint — exclude artifact dirs + MD024 siblings_only ([#84](https://github.com/evanharmon1/harmon-init/issues/84)) ([7c7ae07](https://github.com/evanharmon1/harmon-init/commit/7c7ae072b0205ed85f966d94e7438c8b24ef4087))

## [3.1.1](https://github.com/evanharmon1/harmon-init/compare/v3.1.0...v3.1.1) (2026-06-23)


### Bug Fixes

* don't enforce a repo-wide YAML extension convention ([#81](https://github.com/evanharmon1/harmon-init/issues/81)) ([bb5b42d](https://github.com/evanharmon1/harmon-init/commit/bb5b42dc557eb903bb44cf61eb10e32b0cd500b5))
* ensure rendered LICENSE ends with a trailing newline ([#80](https://github.com/evanharmon1/harmon-init/issues/80)) ([42bc585](https://github.com/evanharmon1/harmon-init/commit/42bc585acd141d1fc1ded3b4c69759410fe3c3de))

## [3.1.0](https://github.com/evanharmon1/harmon-init/compare/v3.0.3...v3.1.0) (2026-06-22)


### Features

* authenticate CI workflows as a GitHub App (not a PAT) ([#74](https://github.com/evanharmon1/harmon-init/issues/74)) ([4931dfe](https://github.com/evanharmon1/harmon-init/commit/4931dfe39b5742117c1a41c2eec50692797bb469))
* release-please, DESIGN.md, IaC scaffolds, and CI polish ([#72](https://github.com/evanharmon1/harmon-init/issues/72)) ([b925224](https://github.com/evanharmon1/harmon-init/commit/b925224de9840246bf91459cebe87990d465f090))

## [3.0.0]

Breaking redesign porting the current repo conventions from harmon-infra and
sommerlawn-web into the template.

### Added

- Template generation test harness (`task test:template:*` +
  `scripts/test-template.sh`) with a 4-profile matrix (minimal/web/iac/full)
  run locally, in pre-push hooks, and in CI.
- New copier questions: `github_org`, `project_type`
  (general | web-astro | web-app | iac | docs), `include_terraform`,
  `include_ansible`, `ci_runner` (ubuntu-latest | self-hosted).
- Template: lefthook + commitlint + gitleaks, namespaced Taskfile,
  Claude Code GitHub workflows (plan/implement/review), CodeQL,
  devcontainer prebuild workflow (GHCR), branch-protection ruleset JSON,
  renovate.json, .coderabbit.yaml, dual-profile devcontainer (AI bot +
  human dev with Tailscale) ported from harmon-infra, docs tree
  (architecture/decisions/guides/runbooks/product + README/tests/
  troubleshooting/glossary/roadmap/onboarding/branch-protection/CHECKLIST),
  specs/ and tests/ at root, CHANGELOG.md, .claude settings, conditional
  pyproject.toml/.python-version (uv), terraform/ansible skeletons.
- Canonical `AGENTS.md` with `CLAUDE.md`/`GEMINI.md` symlinks (both layers).

### Changed

- Custom jinja delimiters `[[ ]]` / `[% %]` via `_envops` (no more
  `{% raw %}` escaping); `_preserve_symlinks: true`.
- `devcontainer` defaults to yes; `bunch_add` defaults to no (CI-safe).
- Root layer dogfoods the same conventions (lefthook, gitleaks, namespaced
  Taskfile, renovate, coderabbit).

### Removed

- Auto-release on merge to main (both layers) — releases are now manual via
  `task release:patch|minor|major`.
- pre-commit, whispers, check_for_pattern.sh, justfile/howzit conditionals,
  dependabot.yml (Renovate owns version updates; Dependabot alerts are repo
  settings), legacy questions (`ci_cd`, `git_provider`, `docker_*`,
  `project_url`, `github_collaboration_templates`, ...).
