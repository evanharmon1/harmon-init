# Post-Generation Checklist — Harmon Init

Work through this after generating the repo from harmon-init. Delete items
that don't apply, then keep this file as a record of what was configured.

## 1. Local setup

- [ ] `task install` — Brewfile deps, and lefthook git hooks
- [ ] `task verify` passes locally

## 2. GitHub repo settings

- [ ] Import the branch ruleset (see [branchProtection.md](branchProtection.md)):

  ```bash
  gh api "repos/evanharmon1/harmon-init/rulesets" --method POST \
    --input ".github/Branch Protection Ruleset - Protect Main.json"
  ```

- [ ] Settings → Advanced Security: enable **Dependabot alerts** and
      **Private vulnerability reporting** (do NOT add dependabot.yml —
      Renovate owns version updates)
- [ ] Install the [Renovate app](https://github.com/apps/renovate) on the repo
- [ ] Install the [CodeRabbit app](https://github.com/apps/coderabbitai) on the repo (`.coderabbit.yaml` is pre-configured)
- [ ] Actions secrets: `CLAUDE_CODE_OAUTH_TOKEN` (claude-* workflows),
      `GH_WORKFLOW_PAT` (fine-grained PAT for the bot account; see
      branchProtection.md for required scopes), `SNYK_TOKEN` (snyk tasks)
- [ ] Actions variables: set `FULL_SECURITY_SCAN=true` to enable CodeQL
- [ ] GHCR: ensure the org/user allows publishing packages; the first
      devcontainer prebuild populates `ghcr.io/evanharmon1/harmon-init-devcontainer` on merge to main

## 3. Framework scaffolding (conventions-only template)

- [ ] Add the project's primary toolchain; extend Taskfile `build`/`test` accordingly

## 4. Secrets & environment

- [ ] No secrets in git — gitleaks enforces this on pre-push and in CI
- [ ] For local `.env` needs, use 1Password: `op inject`/`op run` or the
      1Password Developer Environments feature; commit only `.env.example`-style files
- [ ] Devcontainer secrets land in `.devcontainer/devcontainer.env` via
      `init-env.sh` (1Password locally, host env on Coder) — never committed

## 5. Docs & meta

- [ ] Fill in the `TODO:` markers in README.md and docs/ (architecture diagram first)
- [ ] Confirm README badges render (Actions URLs are correct once CI runs)
- [ ] Initial release when ready: `task release:init` (v0.1.0) — releases stay manual
