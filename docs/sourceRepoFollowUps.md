# Follow-ups for harmon-infra and sommerlawn-web

Issues noticed while porting conventions into harmon-init v3. The plan is to
fix these by applying the updated template to each repo (harmon-init is the
source of truth going forward), not by hand-editing them ad hoc.

## Both repos

1. **AI doc symlink direction** — `CLAUDE.md` is the real file with
   `AGENTS.md`/`GEMINI.md` symlinks. New standard flips this: `AGENTS.md` is
   canonical, `CLAUDE.md`/`GEMINI.md` symlink to it. (Remember to flip the
   prettier/lefthook symlink excludes accordingly.)
2. **docs layout drift** — `docs/runbooks/` vs the standard `runbook/`;
   `docs/specs/` should move to root `specs/`; missing `design/`, `guides/`,
   `index.md`, `testing.md`, `glossary.md`, `roadmap.md`, `onboarding.md`;
   `tests/` belongs at repo root.
3. **gitleaks pins divergent and un-annotated** — infra workflows pin 8.24.3,
   sommerlawn 8.21.2, neither with a `# renovate:` annotation. The template
   now annotates them (`GITLEAKS_VERSION` + renovate regex manager).
4. **go-task pin divergence** — `arduino/setup-task` version 3.51.1 (infra)
   vs 3.49.x (sommerlawn).

## harmon-infra

1. **Auto-release on main push** — `release.yml` runs `task release:patch` on
   every merge. New standard: releases are manual only; delete the workflow.
2. **Brewfile is legacy-bloated** — deprecated `exa`, large commented
   graveyard, missing gitleaks/yamllint/actionlint.
3. **Branch ruleset stale** — required checks reference old job names
   (`secrets`, `validate`, `build-homepage`) instead of `verify` + `security`,
   and there's no merge_queue rule.
4. **Ambiguous `verify` contexts** — both `validate.yml` and
   `devcontainer-build.yml` define a job named `verify`; either can satisfy
   the required check. The template renames the devcontainer one to
   `devcontainer-verify`.
5. **CHECKLIST.md is stale** (mentions pre-commit/cookiecutter).
6. **validate.yml reinstalls lint tools inline every run** — candidates for
    the prebuilt devcontainer image or a composite action.

## sommerlawn-web

1. **Duplicate claude workflows** — `claude-review-max.yml` /
    `claude-implement-max.yml` duplicate the base workflows; consolidate.
2. **Missing codeql.yml** (infra has one).
3. **Naming inconsistency** — workspace/bunch files say `sommer-lawn` while
    the repo slug is `sommerlawn-web`; regenerating from the template
    normalizes this.
4. **lint-hygiene portability** — infra's `scripts/lint-hygiene.sh` uses
    `mapfile` and `grep -P` (Linux-only); the template version is portable to
    macOS bash 3.2 and has a path-independent self-skip.
