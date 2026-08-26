# Post-Generation Checklist — Harmon Init

<!--
AI AGENTS: This checklist is a human-maintained record for humans to check off.
Do not check, uncheck, rewrite, remove, reorder, normalize, reconcile, or
otherwise update its items based on repository state. Do not try to keep it
consistent with code, configuration, tags, releases, or external services.
Read-only inspection and reporting are allowed when requested, but never mutate
checklist state based on the findings. Only edit a checklist item when the human
user clearly and explicitly asks for that specific checklist update.
-->

Work through this after generating the repo from harmon-init. Delete items
that don't apply, then keep this file as a record of what was configured.

Run **`task status:setup`** at any point to audit setup completeness — local
credentials (gh, Codex), GitHub config, toolchain, devcontainer, and dev
environment — against the items below
(✓ done · ✗ missing · ? unknown · – n/a).

## 1. Local setup

- [ ] `task install` — Brewfile deps, and lefthook git hooks
- [ ] `task verify` passes locally
<!-- Diverges from template/docs/CHECKLIST.md.jinja ON PURPOSE — do not
"reconcile" it. sync-harmon-devkit.yml is root-only harmon-platform glue with no
template twin, so a generated repo really does the manual two-step the template
describes, while harmon-init's bump is automated. Note that NOTHING will tell you
this: the parity gate skips jinja twins, the structure gate checks headings and
tasks rather than prose, and this file is on audit-dogfood.sh's SKIP list. Hence
this comment. -->
- [ ] **Vendored agent skills stay pinned**: `.skills-sync.yaml` pins which
      harmon-devkit skill categories this repo vendors into `.claude/skills/`,
      and — when the manifest carries an `agents:` block — which shared
      subagents it vendors into `.claude/agents/`, at the same pinned ref.
      **In this repo the bump is automated** — publishing a stable
      [harmon-devkit release](https://github.com/evanharmon1/harmon-devkit/releases)
      opens or updates one rolling `bot/sync-harmon-devkit` PR with both
      manifests, the provenance, and the vendored skills already moved in
      lockstep and verified. Review and merge it like any other PR; nothing
      auto-merges. See
      [architecture/ci-cd.md](architecture/ci-cd.md#harmon-devkit-skills-propagation).
      To bump by hand — or to recover a missed dispatch — run
      `task sync:devkit-release -- vX.Y.Z`, which does the same work locally.
      To see the current vendoring state without changing anything, run
      `task skills:status` (add `-- --offline` for an offline snapshot).
      **The fully manual fallback is a two-step, and this repo has TWO
      manifests:** edit `ref` in both `.skills-sync.yaml` **and**
      `template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja`,
      then run `task sync:skills` and commit the refreshed `.claude/skills/`
      (and `.claude/agents/`, if the manifest requests agents) in the same PR. `task sync:skills` reads only the root manifest, so editing
      just that one leaves the template shipping the old pin to generated repos
      — and the next automated run aborts with `pin disagreement` until someone
      reconciles them by hand. Only this fully manual route has that trap: the
      workflow and `task sync:devkit-release` both write both manifests.
      **Both mistakes are caught, by different gates.** Editing the *root*
      manifest without re-syncing fails `verify:skills` in CI and
      `verify:skills:offline` pre-push. Editing *only the template* manifest is
      invisible to those two — they read the root manifest, whose pin still
      matches the provenance — so `task test:skills-pin-parity` (in `verify` and
      CI) compares the two pins directly and fails on disagreement.
      Renovate's harmon-devkit
      rule is kept only as a passive stale-pin signal: it is Dependency
      Dashboard-gated, so it never opens a pin PR unattended. **Leave it
      unapproved while the sync workflow is healthy** — approving it opens a
      second, ref-only PR for a bump the automation is already handling, and
      Renovate cannot do the re-sync, so that PR fails `verify:skills` until
      someone finishes it by hand.
- [ ] Verify `harmon-init.code-workspace` opens the repo's folder in VS Code and has a unique VS Code Workspace color. Then add any other related repos (e.g. other org repos) to the `folders` list in the workspace file so you have quick access to those repos
- [ ] Extend `.gitignore` for your stack — the template ships a base; add stack-specific entries via [gitignore.io](https://www.toptal.com/developers/gitignore)
- [ ] macOS: add a Raycast quicklink/alias that opens the `harmon-init.code-workspace`
- [ ] macOS (Bunch): scaffold the launcher with `task util:bunch-add` (if not generated at copier time), then `task util:bunch-install` to move it to iCloud and leave a `.meta/*.bunch` symlink (re-run install if missing)

## 2. GitHub repo settings

- [ ] **Automated settings** — run `task setup:github` (idempotent, safe to
      re-run): enables **Dependabot alerts** and **private vulnerability
      reporting**. Do not add `dependabot.yml`: Renovate owns routine and
      vulnerability-remediation PRs; Dependabot owns advisory alerts.
- [ ] **Bot PAT** — the agent's `GH_TOKEN`. If a fine-grained PAT already covers
      `evanharmon1`, just add this repo to its **selected repositories**; a token is
      scoped to one resource owner, so a **new owner needs a new PAT**. Both layers
      are required — the collaborator grant sets the ceiling, the PAT's repo list
      reaches it. Procedure: [guides/bot-account.md](guides/bot-account.md).
- [ ] Import the branch ruleset (see [architecture/branch-protection.md](architecture/branch-protection.md)) — do this once `build.yml` is on `main` so the required `verify`/`security` checks resolve. **Use the UI import:** Settings → Rules → Rulesets → **New ruleset ▸ Import a ruleset** → select `.github/Branch Protection Ruleset - Protect Main.json`. (Prefer the UI over `gh api … rulesets`: the API `POST` is not idempotent — re-running creates a duplicate ruleset — and currently rejects the `merge_queue` rule. To later change the ruleset, edit the existing one in the UI rather than re-importing.)

- [ ] **Install and activate Renovate** — install the
      [Renovate app](https://github.com/apps/renovate) for **Only select
      repositories** and select this repo. In the Mend Developer Portal choose
      the **Renovate** product and **Scan and Alert** mode. Do not choose **Scan
      Only**: it puts Renovate in silent mode, which scans without creating
      checks, issues (including the Dependency Dashboard), or update/remediation
      PRs. This repo already has `renovate.json`; keep that configuration rather
      than replacing it with a generic onboarding config.
- [ ] **[human-only] Remove CodeRabbit access** — remove this repository from
      the CodeRabbit GitHub App installation and confirm the App no longer has
      access. Deleting `.coderabbit.yaml` and bot trust does not revoke an
      existing installation.
- [ ] **[human-only] Connect Codex cloud review** — connect this repository in
      ChatGPT Codex settings, grant private-repository access if applicable,
      and confirm review activity is authored by GitHub actor ID `199175422`
      (`chatgpt-codex-connector[bot]`, type `Bot`).
- [ ] **[human-only] Disable Codex Automatic reviews** — turn **personal Auto
      review** off and set this repository's **Auto code review** preference to
      **Follow personal** — and its review **Trigger** to Follow personal too,
      since an "On every push" trigger sits dormant while Auto review is off
      and arms across every Follow-personal repo at once the moment the
      personal toggle changes. The draft-workbench lifecycle drives Codex with
      explicit `@codex review` requests while the PR is draft; left on,
      `gh pr ready` starts a *new* asynchronous review after the readiness gate,
      and non-draft stops truthfully meaning "ready for a human". Ticking this
      item records that all three knobs are set; once recorded it is settled
      configuration — nothing in the lifecycle gates on it — and the one thing
      worth reporting later is an unsolicited Codex review, the signature of
      the knobs drifting back on.
- [ ] **[human-only] Any other automatic reviewer must review drafts** — if you
      enable one (GitHub Copilot code review, for example — foreman trusts its
      findings via `trusted_actors`), turn on its draft-review option.
      A reviewer that skips drafts first reports *after* promotion, so the
      readiness gate would hand a human a PR it had not actually reviewed.
      Leave it off rather than run it blind to the workbench.
- [ ] Actions secret: `CLAUDE_CODE_OAUTH_TOKEN` (claude-* workflows) — generate
      with `claude setup-token`; the value must start **`sk-ant-oat01-`** (an OAuth
      token, billed to your Claude subscription), **not** `sk-ant-api03-` (a raw API
      key, billed at pay-as-you-go API rates). Then `gh secret set CLAUDE_CODE_OAUTH_TOKEN`
- [ ] **Foreman operator setup** — provision the separate READ-ONLY PAT that
      foreman hands to dispatched agents: export/store it as
      `FOREMAN_AGENT_GH_TOKEN` where the bot devcontainer's `init-env.sh` can
      inject it (1Password → devcontainer.env). Run `task setup:github-labels`
      so the `foreman:*` arming labels exist. Import the two tag rulesets
      (`.github/Tag Protection Ruleset - Version Tag Creation.json` /
      `… Immutability.json`, same UI import as the branch ruleset), then add
      the CI GitHub App to the **Creation** ruleset's bypass list (`always`) —
      release-please tags via that App, and bypass-actor App IDs are
      per-installation so the JSON cannot ship them. (Immutability keeps an
      empty bypass list on purpose: a moved `v*` tag is code execution in
      every consumer, so nobody bypasses it.) Create the standing probe tag on
      an **orphan commit**, so it is reachable from no branch:
      `git tag v0.0.0-probe "$(git commit-tree "$(git hash-object -t tree /dev/null)" -m 'foreman tag-immutability probe target (orphan; keep unreachable from any branch)')" && git push origin v0.0.0-probe`.
      Do not tag `HEAD` or any commit on `main`: `git describe` considers only
      tags reachable from `HEAD` and prefers the nearest, so a probe tag on a
      release commit outranks the release tag and poisons every `git
      describe`-derived version — in a repo that renders itself with Copier
      that fails the template's PEP 440 version check on every commit below the
      tag, locally and in PR CI alike. The probe only needs the remote tag's
      sha to differ from `main`'s, so an orphan target satisfies it
      permanently, and `task test:tag-hygiene` guards the invariant. Preflight
      empirically asserts `v*` tags are immutable and fails until both
      rulesets and the tag exist. Then `task foreman:preflight` (inside the
      bot devcontainer — foreman refuses to start anywhere else) to assert
      the security controls before any dispatch.
- [ ] **[human-only] Foreman reviewer-gate check** — `.foreman.toml`'s
      `[reviewer]` table is foreman's current-head review gate for the PRs it
      shepherds. Before the first dispatch (and again after any Foreman bump),
      confirm the configured `login` still matches the live Codex connector
      identity (actor ID `199175422`), that its terminal results — an APPROVED
      review at the head, or a 👍 from that login on foreman's own request
      comment — still mean what the readiness gate assumes, and that required
      checks run on draft PRs (foreman promotes only after they conclude).
- [ ] **Free SAST coverage** — Harmon Init has no CodeQL workflow (its
      first-party source is shell/config; foreman is a pinned external CLI), so
      Semgrep CE runs in `build.yml` at both visibilities. Generated supported
      public stacks run CodeQL automatically; free private repos use Semgrep CE
      unless paid private CodeQL is explicitly enabled.
- [ ] **Choose the Snyk posture** — Harmon Init runs the free baseline
      (Semgrep CE + Dependabot alerts/Renovate + gitleaks) and adds Snyk as an
      advisory second opinion at `snyk_scan_schedule=weekly`. Free private repos
      keep Snyk manual/local via `task security:sast:snyk` and
      `task security:sca:snyk`; local tests consume the same Snyk Organization
      quota. Do not install the Snyk GitHub App for this posture; its PR checks
      are not required by the branch ruleset.
- [ ] **Activate scheduled Snyk (weekly)** — set the Actions secret `SNYK_TOKEN`
      (the value must be piped on stdin, e.g.
      `op read "op://<vault>/<item>/<field>" | task secret:set:gh NAME=SNYK_TOKEN REPO=evanharmon1/harmon-init`)
      and run
      `snyk-scheduled.yml` once with **Run workflow**. It runs SAST + SCA only on
      its schedule/manual dispatch—never on PR or push—and remains advisory, so
      it is never added to the branch ruleset. Confirm Snyk recognizes the public
      Git remote and does not debit private-test usage; if it does, run
      `snyk monitor` once and set the Project's Git remote URL in Snyk. A repo
      generated from this template chooses `weekly` (conservative) or `daily`
      (public or accepted unlimited OSS); prefer weekly for any deliberately
      budgeted private repo and check Organization Usage before enabling it.
- [ ] **Create** the CI GitHub App `evanharmon1-ci` by hand (one App per org;
      **Settings → Developer settings → GitHub Apps**), or reuse the org's existing one.
- [ ] **Install** the App on this repo — **Install App → Only select repositories**
      (the harmon-init repos that run release-please / claude-* / project-automation),
      **not "All"**. **Creating the App is not enough:** an App whose credentials are
      set but which is *not installed* on the repo makes
      `actions/create-github-app-token` fail at runtime with a **404**
      (`Not Found` — "not installed on this repository"). This is the single
      easiest step to miss.
- [ ] Set `CI_APP_CLIENT_ID` (Actions **variable**) + `CI_APP_PRIVATE_KEY` (Actions
      **secret**) — **pipe the `.pem` in** (never paste it; flattened newlines break
      the key), and **scope both to those same repos** (least privilege — the key can
      act as the App: commits, PRs, releases, workflow edits):

      ```bash
      gh secret set CI_APP_PRIVATE_KEY --org evanharmon1 \
        --visibility selected --repos <repo-a>,<repo-b> < evanharmon1-ci.private-key.pem
      gh variable set CI_APP_CLIENT_ID --org evanharmon1 \
        --visibility selected --repos <repo-a>,<repo-b> --body "<client-id>"  # Iv…-style, not the numeric App ID
      ```

      Personal account: use `--repo evanharmon1/harmon-init` instead of
      `--org`/`--visibility`/`--repos`. Re-running `--repos` **replaces** the list —
      re-run with the full list to add a repo. Drives release-please, the claude-*
      workflows, and project-automation; blast-radius + rotation in
      [architecture/security.md](architecture/security.md).
- [ ] GHCR: ensure the org/user allows publishing packages; the first
      devcontainer prebuild populates `ghcr.io/evanharmon1/harmon-init-devcontainer` on merge to main
- [ ] GitHub Project: run `task setup:github-project` (needs
      `gh auth refresh -s project`) to create the owner's default project (titled
      `evanharmon1 Project`) and idempotently sync its `Status` pipeline and
      `Size` number field — see
      [project-management.md](project-management.md).
      On a personal account it also creates Priority/Product/Size as project
      fields (issue fields are org-only; there is deliberately no Domain or
      Layer field — see project-management.md, "Label or field?"); status
      automation is a separate follow-up — the board is set up, but issue/PR
      status isn't auto-synced yet. Re-runs **append** any starter option a
      single-select field is missing (so a value added by a later harmon-init
      release lands on the next run) and never touch, reorder, or delete the
      options you added.
- [ ] **Upgrading from a release before #875?** If this repo's board still
      carries `Domain`/`Layer` fields from an earlier harmon-init release, they
      are not deleted automatically — retiring them is a deliberate,
      irreversible operator step. See
      [project-management.md](project-management.md), "Migrating a board that
      still has one."
- [ ] **Upgrading from a release before harmon-init#1047
      (`method:*` → `strategy:*`)?** Run `task setup:github-labels` first so
      the `strategy:*` destinations exist, then use the read-only report and
      guarded maintenance flow below. For each live value among `oneshot`,
      `plan`, `plan-approved`, `orchestrate`, `council`, and `human-led`, pass
      one `--migrate method:<v>=strategy:<v>`; the guarded flow attempts to move
      associations for matching issues, PRs, and discussions found in its paginated snapshots,
      re-reads them, and only then allows `--prune` to remove zero-association
      retired labels.
- [ ] Labels: run `task setup:github-labels` to seed this repo's starter label
      families from `label-registry.json` (see the generated taxonomy table in
      [project-management.md](project-management.md)) — grow `domain:` values
      there as the product's own problem-space vocabulary and `area:` values as
      its solution-space subsystems; both starter lists are a floor. `layer:`
      is product-independent and normally needs no edits. Labels are per-repo,
      so run it in each repo; org default labels (org Settings → Repository,
      UI-only) only seed new repos.
- [ ] **After a `copier update` that adds label families** (e.g. `tier:*` — a
      pure addition), re-run `task setup:github-labels` to provision the new
      labels here — it is additive and never deletes, so existing labels and
      the issues they sit on are untouched — then classify open issues with the
      added families. A RENAMED family (like `method:*` → `strategy:*` above)
      is not a pure addition — provision the new destinations first, then
      migrate the old associations before retiring their labels.
- [ ] **[human-only] Inspect live label drift before retiring anything** — keep
      the default setup path additive, then run
      `./scripts/setup-github-labels.sh --repo <owner/repo> --report-unregistered`
      with the same `--foreman` / `--release-please` profile flags used for
      setup when you want to mirror provisioning. Maintenance protection still
      includes every non-retired registered family, including gated tool labels,
      when those flags are omitted. This is read-only: it pages through the
      live labels, all-state issues and pull requests, and repository
      discussions, and reports separate association counts. An indeterminate read is a stop, not
      permission to clean up.
- [ ] **[human-only] Retire any legacy `agent:*` claim labels or pre-2026
      `codex`/`copilot` labels** — use the guarded maintenance flow, never a
      direct `gh label delete` or a hand-written association list. Perform its
      write path in a quiescent maintenance window: pause claim/release,
      Foreman, release-please, and other human/API label writers for the whole
      run. `--report-unregistered` is read-only, but its counts are a snapshot;
      run it again immediately before `--prune`.

      For fixed-family sources, these mappings are authoritative:
      `agent:claude-code` → `claim:claude`, `agent:codex` → `claim:gpt`,
      `agent:gemini-cli` → `claim:gemini`, `agent:kimi-k2` → `claim:kimi`, `agent:qwen-code` →
      `claim:qwen`, `suggest:codex` → `suggest:gpt`, and `claim:codex` →
      `claim:gpt`. Pass one repeatable `--migrate OLD=NEW` per exact live
      source, together with `--prune`; for example,
      `./scripts/setup-github-labels.sh --repo <owner/repo> --prune
      --migrate agent:gemini-cli=claim:gemini`. `--migrate` does not match a
      prefix, so each live model-level source needs its own mapping. The
      `OLD=NEW` form contains exactly one `=`; a label name containing `=` must
      be relabeled per record instead of passed to bulk migration. Move only
      the family segment for fixed mappings and preserve the recorded model
      suffix, e.g. `suggest:codex:sol` → `suggest:gpt:sol` and
      `claim:codex:sol` → `claim:gpt:sol`; model-level labels refine rather
      than replace their family-level label, and the command retains or adds
      both associations. If a recognized model-level
      destination is absent, the command creates it after confirmation by
      copying metadata from the live family label; missing family labels stop
      maintenance and require setup first.

      Use this association-migration path, not `gh label edit` or a hand-written
      create-then-delete sequence: the command validates a live registry
      destination or creates a recognized on-demand model destination as
      described above, attempts the association move for each matching issue,
      PR, and discussion found in its paginated snapshots, then permits
      `--prune` only when a fresh snapshot
      shows the source has zero associations. Enumerate
      model-level names explicitly with `gh label list --repo <owner/repo>
      --limit 1000 --json name --jq '.[].name' | grep -E
      '^(suggest|claim):(codex|copilot):'`; for each source, inspect all-state
      `gh issue list --label <old> --state all --limit 1000` **and**
      `gh pr list --label <old> --state all --limit 1000`. An exactly-full
      manual result is capped; increase the limit and rerun before writes. The
      maintenance path itself uses `gh api --paginate` and refuses an
      indeterminate read.

      Copilot is a broker, not a fixed family: `mai` is only the picker default
      and is never a guessed destination. Do **not** pass
      `agent:github-copilot*`, `suggest:copilot*`, or `claim:copilot*` to bulk
      `--migrate` — the command rejects broker-derived sources because one
      destination cannot represent mixed runtime records. For
      `suggest:copilot`, there is no claim/session record: re-express each
      issue/PR's planning intent as `suggest:<actual-family>` or drop the old
      association; do not rename it to `suggest:mai`. For `claim:copilot`,
      inspect each issue/PR's claim/session record and relabel that record to
      `claim:<actual-family>`; use `claim:mai` only when the record confirms
      MAI. Apply the same per-record distinction to
      `suggest:copilot:<model>`/`claim:copilot:<model>` and preserve a model
      suffix only after the actual family is known. Include Discussions in that
      per-record inventory: the read-only report gives their association count,
      and the Discussions UI or GraphQL API identifies the records to relabel.
      If a live claim's record is
      missing, settle it with its owner or leave the label untouched rather
      than guess. Add and verify the per-record destination before removing the
      old association; after every record is handled, a fresh zero-association
      snapshot may permit guarded `--prune` to attempt retiring the source.

      Before moving any in-flight `claim:*`/legacy `agent:*` marker, settle the
      claim or amend its durable record in the same sitting: its release path
      names the exact label it will remove, and moving only the issue/PR
      association strands the replacement marker. Interactive runs confirm on
      the TTY; automation must state destructive intent again with separate
      `--yes` (piped stdin is refused).

      The command verifies each migration around source removal, then takes one
      complete, bounded post-migration association snapshot before the deletion
      batch and fails closed on read/verification errors, but GitHub has no transaction or
      compare-and-swap that binds the final read to the following edit/DELETE.
      A concurrent writer can still change labels after that read and before
      the request, and the command cannot undo a successful concurrent
      mutation. If writers were not paused or any verification drifts, treat
      the operation as incomplete, reconcile live associations, and rerun in a
      new quiet window; do not infer association preservation from a successful
      exit alone; this is a guarded best-effort operation at that API boundary.
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
      with `CLAUDE_CODE_OAUTH_TOKEN` and `AGENT_DECK_TELEGRAM_KEY`, plus
      `GH_TOKEN` for the bot profile and `TS_AUTHKEY` for the dev one — the dev
      profile carries no `GH_TOKEN` and runs `gh auth login` instead.
      `init-env.sh` enforces the per-profile
      allow-list; on Coder the values come from workspace parameters. See
      [guides/devcontainers.md](guides/devcontainers.md)

## 5. Docs & meta

- [ ] Fill in the `TODO:` markers in README.md and docs/ (architecture diagram first)
- [ ] Confirm README badges render (Actions URLs are correct once CI runs)
- [ ] Initial release when ready: `task release:init` (v0.1.0) — releases stay manual
- [ ] Stay current with harmon-init: periodically run `copier update --trust` to pull
      template improvements (a three-way merge — your own edits are preserved). The
      standardize-repo skill (`update` mode) automates this and verifies the result.
