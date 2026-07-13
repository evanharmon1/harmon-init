# Post-Generation Checklist — Harmon Init

Work through this after generating the repo from harmon-init. Delete items
that don't apply, then keep this file as a record of what was configured.

Run **`task status:setup`** at any point to audit setup completeness — GitHub
config, toolchain, devcontainer, and dev environment — against the items below
(✓ done · ✗ missing · ? unknown · – n/a).

## 1. Local setup

- [ ] `task install` — Brewfile deps, and lefthook git hooks
- [ ] `task verify` passes locally
- [ ] Verify `harmon-init.code-workspace` opens the repo's folder in VS Code and has a unique VS Code Workspace color. Then add any other related repos (e.g. other org repos) to the `folders` list in the workspace file so you have quick access to those repos
- [ ] Extend `.gitignore` for your stack — the template ships a base; add stack-specific entries via [gitignore.io](https://www.toptal.com/developers/gitignore)
- [ ] macOS: add a Raycast quicklink/alias that opens the `harmon-init.code-workspace`
- [ ] macOS (Bunch): scaffold the launcher with `task util:bunch-add` (if not generated at copier time), then `task util:bunch-install` to move it to iCloud and leave a `.meta/*.bunch` symlink (re-run install if missing)

## 2. GitHub repo settings

- [ ] **Automated settings** — run `task setup:github` (idempotent, safe to
      re-run): enables **Dependabot alerts** and **private vulnerability
      reporting**, sets the `FULL_SECURITY_SCAN` variable (CodeQL). Do NOT add dependabot.yml — Renovate owns version updates.
- [ ] Import the branch ruleset (see [architecture/branch-protection.md](architecture/branch-protection.md)) — do this once `build.yml` is on `main` so the required `verify`/`security` checks resolve. **Use the UI import:** Settings → Rules → Rulesets → **New ruleset ▸ Import a ruleset** → select `.github/Branch Protection Ruleset - Protect Main.json`. Prefer the UI over a blind API `POST`, which is not idempotent and creates duplicate rulesets. The REST API supports `merge_queue`, but safe automation must discover the existing ruleset and update its id with `PUT`. Later changes should edit the existing ruleset rather than re-importing.

- [ ] Install the [Renovate app](https://github.com/apps/renovate) on the repo
- [ ] Install the [CodeRabbit app](https://github.com/apps/coderabbitai) on the repo (`.coderabbit.yaml` is pre-configured)
- [ ] Actions secrets: `CLAUDE_CODE_OAUTH_TOKEN` (claude-* workflows),
      `SNYK_TOKEN` (snyk tasks)
- [ ] CI GitHub App `evanharmon1-ci`: create it by hand for this org (one App
      per org; **Settings → Developer settings → GitHub Apps**), or reuse the
      org's existing one;
      install it on this repo, then set `CI_APP_CLIENT_ID` (Actions
      **variable**) + `CI_APP_PRIVATE_KEY` (Actions **secret**) — org-level for
      an org, per-repo for a personal account. Set the private key by piping the
      `.pem` in (`gh secret set CI_APP_PRIVATE_KEY … < key.pem`), not by pasting —
      flattened newlines make the key undecodable. For an org, scope it
      (`--visibility selected --repos …`) and then finalize/audit repo access in
      the UI. Drives release-please, the
      claude-* workflows, and project-automation. See docs/architecture/security.md.
- [ ] GHCR: ensure the org/user allows publishing packages; the first
      devcontainer prebuild populates `ghcr.io/evanharmon1/harmon-init-devcontainer` on merge to main
- [ ] GitHub Project: run `task setup:github-project` (needs
      `gh auth refresh -s project`) to create the owner's default project (titled
      `evanharmon1 Project`) and idempotently sync its `Status` pipeline and
      `Size` number field — see
      [project-management.md](project-management.md).
      On a personal account it also creates Priority/Product/Agent/Size as
      project fields (issue fields are org-only); status automation is a separate
      follow-up — the board is set up, but issue/PR status isn't auto-synced yet.
- [ ] Labels: run `task setup:github-labels` to seed this repo's starter label
      families (concerns/source/workflow/layer/domain — see
      [project-management.md](project-management.md)). Labels are per-repo, so run
      it in each repo; org default labels (org Settings → Repository, UI-only) only
      seed new repos.
- [ ] Project views: create the starter views (Board / Triage / Agent queue /
      Planning / Mine) in the Project UI — Projects V2 has no view API,
      so this is a one-time manual step. Filters/layouts are in
      [project-management.md](project-management.md).
- [ ] GitHub Project auto-add (**adds every issue to the board**): in the
      Project's **Settings → Workflows**, turn on **"Auto-add to project"** and
      point it at this repo (filter `is:issue`, `is:pr`) so *every* new issue and
      PR lands on the board automatically, however it's created. GitHub's native
      built-in — no Actions or tokens, and it's the reliable way to guarantee
      coverage (the issue-form `projects:` key only covers form-created issues and
      needs a static project number). See
      [project-management.md](project-management.md).

## 3. Framework scaffolding (conventions-only template)

- [ ] Add the project's primary toolchain; extend Taskfile `build`/`test` accordingly

## 4. Secrets & environment

- [ ] For local `.env` needs, use **1Password Environments** (mounts a virtual
      `.env`; secrets never hit disk or git) or `op run`/`op inject`. Commit only
      `.env.example`-style files
- [ ] Devcontainer secrets: create a **1Password environment** that mounts
      `.devcontainer/devcontainer.env` (and `.devcontainer/dev/devcontainer.env`)
      with `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`
      (+ `TS_AUTHKEY` for the dev profile). `init-env.sh` enforces the per-profile
      allow-list; on Coder the values come from workspace parameters. See
      [guides/devcontainers.md](guides/devcontainers.md)

## 5. Docs & meta

- [ ] Fill in the `TODO:` markers in README.md and docs/ (architecture diagram first)
- [ ] Confirm README badges render (Actions URLs are correct once CI runs)
- [ ] Initial release when ready: `task release:init` (v0.1.0) — releases stay manual
- [ ] Stay current with harmon-init: periodically run `copier update --trust` to pull
      template improvements (a three-way merge — your own edits are preserved). The
      standardize-repo skill (`update` mode) automates this and verifies the result.
