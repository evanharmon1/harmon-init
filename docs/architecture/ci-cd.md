# CI/CD

How continuous integration and delivery are wired in Harmon Init. Every
job delegates to `task` targets, so local hooks, CI, and humans run identical
commands (the Taskfile is the single source of truth).

## Quality gate

The pipeline runs `check → build → validate → test → security` (see
[../conventions.md](../conventions.md)). `build.yml` runs these as parallel jobs
plus an aggregate **`verify`** job; branch protection requires `verify` +
`security` to pass before a PR can merge to `main`.

## Workflows

- `build.yml` — on push/PR to `main`: lint, security, template-test, then the
  aggregate **`verify`** job. Its `pull_request:` trigger is
  `[opened, synchronize, reopened]` — **no `draft` filter**, so it fires on
  draft PRs too. That is load-bearing, not incidental: PRs are drafts for their
  whole automated life (AGENTS.md, "Dev Loop"), and the readiness gate that
  promotes one reads these check results. Gating a job on
  `github.event.pull_request.draft` would leave the gate with nothing to read
  until after the handoff it is supposed to authorize.
  **`edited` is deliberately absent** (#1328): it fires on a title/body edit,
  and the readiness gate *requires* body edits to tick `## Deferred findings`
  — so carrying it here made settling a finding restart lint, security and all
  seven template-test profiles, putting condition 1 (checks concluded) back to
  pending at the last step before promotion. `edited` also covers a
  base-**branch** change; losing that re-run is accepted, because retargeting a
  PR is rare and `strict_required_status_checks_policy` forces an up-to-date
  head before merge, which arrives as a `synchronize`.
  **One list, not two** (#962, #1461): the `lint` job runs `check`, then a
  single `task test:suite` step — the Taskfile's aggregate of every `test:*`
  target `task verify` runs — so a guard added to `verify` is in CI by
  construction instead of by someone remembering to list it in the workflow
  too. The accepted cost is one Actions step for the whole suite rather than a
  named step per test. Outside the suite, each with its reason beside it in
  the workflow: `test:template` (it runs as the `template-test` matrix, one
  profile per leg), `verify:skills` (network), `test:devcontainer:permissions`
  (a `ci`-only unit check), and the `audit:*` step (not a `test:*` target).
  `task test:verify-ci-parity` — in the suite, in both layers, and also its own
  `lint` step so deleting the suite step cannot silence it — fails if
  `build.yml`'s `lint` job stops calling `test:suite`, if `verify` stops running
  it, or if `verify` lists a `test:*` target directly (`test:template` aside,
  where the `template-test` job exists); `scripts/test-template.sh` asserts the
  same for every rendered profile.
- `closing-keywords.yml` — the metadata-only gate that refuses a same-repo
  `Closes #N` while `#N` has unchecked task-list items. It lives in its own
  workflow precisely so it can keep `pull_request.edited`: it reads the PR
  title and body, so a body edit genuinely changes its input. `closing-keywords`
  is a required status check in its own right, keyed by the job id — keep that
  id stable. `task guard:closing-keywords` is the local pre-flight
  (`scripts/guard-closing-keywords.sh`).
- `claude-plan` / `claude-implement` / `claude-review` — **mention-only**: an
  explicit `@claude` mention naming `plan`, `implement`, or `review` in a
  comment or review from a sender on the `claude_authorized_members` allowlist. There is no
  label trigger and no open/assign trigger; the retired `claude-plan`,
  `claude-implement`, and `claude-review` labels are gone, because a label or an
  assignment carries no actor the allowlist can check on every path. Each run
  applies `claim:claude` to the target once the sender gate passes and removes it
  in an `always()` cleanup step, which covers the failure, step-timeout and
  cancellation paths. It is not a guarantee: a release whose DELETE fails leaves
  the marker in place and turns the job **red** on purpose (a masked failure
  would be permanent, since the next run reads the surviving claim and refuses),
  and runner loss, a force-cancel, or the job cap firing can strand the label
  with no cleanup at all. A stranded `claim:claude` blocks further mentions on
  that target until someone removes it by hand. `claude-implement` opens a **draft** PR as its normal deliverable
  and never promotes it: it cannot complete the readiness gate, so the handoff
  belongs to a shepherd session.
- The `build.yml` security job runs gitleaks + dependency audit + Semgrep CE
  (this repo has no CodeQL workflow — no first-party CodeQL-supported
  language). Generated repos with `use_codeql=true` add `codeql.yml`, and
  their security job runs Semgrep CE only when the repository is private
  without the paid CodeQL opt-in.
- `snyk-scheduled.yml` — this repo's **weekly** (Sunday 06:23 UTC) Snyk Code +
  Open Source second-opinion scans. It has only schedule/manual triggers,
  consumes no PR checks, and is not part of branch protection. Generated
  repositories opt into the same workflow explicitly via `snyk_scan_schedule`
  (`weekly` or `daily`). See [security.md](security.md) for quota guidance.
- `devcontainer-build.yml` — prebuilds the devcontainer images to GHCR and
  aggregates into the **required** `devcontainer-verify` status check. Like
  `verify` and `terraform-verify`, it carries **no workflow-level `paths:`
  filter** — a filtered workflow never reports on an unrelated PR, and a
  required check that never reports blocks the merge forever — so a
  `devcontainer-changes` job decides internally whether the expensive `build`
  and `devcontainer-assert-bot` jobs need to run, and a docs-only PR gets a
  passing `devcontainer-verify` without either one building. Its
  `devcontainer-assert-bot` job starts a real bot container
  (`scripts/devcontainer-smoke.sh`, sharing the build job's registry cache)
  and runs `bot-autonomy.sh verify` inside it via `docker exec`, so the
  fail-closed, non-interactive policy every installed harness is supposed to
  run under (see [security.md](security.md)) is checked against the built
  image, not just its source files. This container-assertion step is a
  **CI-only** check, deliberately absent from the local `task ci` mirror:
  `scripts/devcontainer-smoke.sh` has no graceful skip (it falls back to `npx
  @devcontainers/cli` rather than a no-op when the CLI is absent, fails hard
  without a reachable Docker daemon, and refuses outright from a linked git
  worktree — a real gap for this repository's own `task worktree:new`-based
  workflow). `task test:devcontainer:root` remains the separate, manually
  invoked local equivalent. #1137's fail-closed guarantee is independently
  satisfied by `apply`/`verify` failing container creation or start directly,
  regardless of any CI signal; this job is a second, PR-visible one on top,
  now a required one. A fork pull request touching `.devcontainer/**` still
  passes `devcontainer-verify` vacuously (every repository-controlled job is
  skipped at the fork trust boundary). `merge_group` builds run in a
  dedicated `build-merge-group` job whose own `permissions:` grant no
  `packages` scope at all, bounding what unreviewed devcontainer content
  can do (the actual enforcement is `require_code_owner_review`, which
  covers this workflow file too — see branch-protection.md), and jobs that
  run on `merge_group` are pinned to a GitHub-hosted runner regardless of
  `CI_RUNS_ON`. `devcontainer-assert-bot` stands down entirely there
  instead, because its registry cache cannot go credential-free per event —
  see [branch-protection.md](branch-protection.md) for the fork-PR trusted-rerun
  runbook and the merge_group carve-out.
- `publish-harmon-devcontainer.yml` — **root-only**: validates and publishes the
  shared amd64/arm64 toolchain image, then maintains its reviewed pin PR.
- `claim-release.yml` — on `issues closed`, on `pull_request closed` **unmerged**,
  and on `pull_request` **merged into the default branch** (releasing the
  branch-bound claim of a partial `Refs` PR whose issue correctly stays open,
  via `scripts/claim-release-merged.sh`),
  releases the claim markers a session left on an issue. It holds `issues: write`
  and parses attacker-writable comment bodies, so it always checks out the
  **default branch** and never a PR head. It only wires events to
  `release-claim.sh` in the vendored `track-work` skill, and no-ops with a
  notice when that script is absent. The template gates it on
  `claim_release_available` — `use_skills_sync` alone, deliberately **not** on
  the `universal` category that carries the script, because categories are
  edited in `.skills-sync.yaml` without updating any copier answer and a
  narrower gate would never re-render for a repo that added them (#622).
- `classification-reconcile.yml` / `classification-event.yml` — keep each open
  issue's derived Tier and `needs-triage` current: a schedule plus a per-issue
  job for human edits (see [Issue classification reconciler](#issue-classification-reconciler)).
- `release.yml` — release-please maintains the rolling release PR.
- `close-milestone-on-release.yml` — closes the milestone matching the tag on release publish.
- `sync-harmon-devkit.yml` — **root-only**: turns a published harmon-devkit
  release into a verified pin-and-sync PR (see below).
- `remote-bootstrap.yml` — **root-only**: proves
  `images/devcontainer/bootstrap-remote.sh` on a stock `ubuntu:24.04` container.
  One job, because the offline half belongs everywhere. The pin contract
  (`task test:bootstrap-remote`) runs unconditionally, inside `test:suite`,
  in `build.yml`'s `lint` job and in `verify`, so a change to any input it reads — the install scripts,
  the pins, or the allowlist tables in
  [remote-environments.md](remote-environments.md) it derives its host sets
  from — is checked on every pull request rather than behind a path filter that
  had to be re-derived by hand whenever the guard grew an input. `bootstrap`
  runs the thing: it seeds the two traps a real remote VM
  has (a Python `yq` at `/usr/bin/yq`, a POSIX locale), installs the core and
  agents tiers against a five-minute budget recorded in the job summary, runs
  the bootstrap a second time and requires **zero new installs** and a
  **byte-identical manifest** (no pinned version moved) — apt upgrades are
  reported in the job summary, not gated, because the apt packages are
  unpinned and converge on the archive by design —
  asserts that the agent posture landed (both managed destinations
  byte-identical to `.devcontainer/config/agent/`, and
  `HARMON_BOOTSTRAP_POSTURE_GAPS=0` on the first run),
  asserts that `op`, Homebrew and Tailscale are absent, and then runs
  `task check` in the checkout using only what the bootstrap installed. Its
  container job is fork-gated like the image publisher's, for the same reason:
  it executes checked-out shell as root. The job runs on the runner's native
  architecture, so `vars.CI_RUNS_ON` is what decides whether arm64 is
  exercised. See [remote-environments.md](remote-environments.md).

## Issue classification reconciler

Two workflows keep each open issue's derived Tier (`tier:<value>`) and
`needs-triage` current. They implement the "Reconcile drift" half of
[ADR 2026-09-30](../decisions/2026-09-30-classify-issues-by-impact-risk-complexity-and-derive-the-tier.md)
D4 and D6, as amended by
[ADR 2026-10-01](../decisions/2026-10-01-store-the-tier-as-a-label-on-every-owner-type.md),
under which the Tier is a label on every owner type. The logic lives in
`scripts/classification-reconcile.mjs`, and `task test:classification-reconcile`
tests it hermetically. Both workflows are generated when
`project_management == 'github'`.

- **`classification-reconcile.yml`** walks open issues, reads Impact, Risk and
  Complexity in both storage shapes, and writes the Tier and `needs-triage`.
  Impact, Risk and Complexity are organization issue fields (a field wins over
  a same-axis label) or `impact:*`/`risk:*`/`complexity:*` labels. It derives
  the Tier with the policy reader's `deriveTier` over the repository's own
  `.devflow.toml` `[tier.matrix]` and never re-implements the matrix. Its
  triggers are `schedule`, `workflow_dispatch` (optionally a dry run), and
  `workflow_call`.
- **`classification-event.yml`** re-derives one issue when a human changes an
  input in the GitHub UI. It triggers on `issues` `opened, labeled, unlabeled,
  typed, untyped` and calls the reconcile workflow for that issue.

**Ownership.** This workflow pair is the only automated writer of the Tier
besides the skills (triage, track-work, breakdown), which set the Tier and
`needs-triage` in the same write that sets Risk or Complexity. The reconciler
writes only `tier:<value>` and `needs-triage`, under `GITHUB_TOKEN` with
`issues: write`. It never writes over an issue carrying `tier:pinned` (it
still maintains `needs-triage` there). It never writes `tier:pinned`,
`priority:*`, `priority-ai:*`, `rigor:*`, `strategy:*` or `claim:*`.

The reconciler reports these cases and leaves the Tier, and the offending
input, as it is. `needs-triage` is still maintained unless an item says
otherwise:

- A pinned issue with two or more tier values (it never picks one), or with
  none.
- An unpinned Tier whose Risk or Complexity is missing (`cache-unverifiable`).
  Derive-on-read ignores that label anyway.
- A leftover `tier:adaptive`. The label is left for its migration (#1447);
  the derived Tier is still written beside it.
- A conflicted axis (two values, or two Type-bearing work-type labels
  without a native Type), or a retired or unknown value. A work-type label is
  Type-bearing when it is non-retired and its registry writers (its own, else
  its family's) include a human or agent writer; one written only by a tool,
  such as Renovate's `dependencies`, is never a Type. That axis
  does not count toward "triaged", so `needs-triage` stays. Recognized values
  come from the repository's `label-registry.json`; when that file is
  unreadable, every axis is unverifiable: `needs-triage` is left as it is and
  no Tier is written.
- An issue whose labels or field values span more than one page. It is
  skipped entirely, `needs-triage` included, rather than decided on a partial
  read.
- A repository whose reader cannot derive. Either the reader has no
  `deriveTier`, which is every repository whose vendored `dev-flow-support`
  predates [harmon-devkit#1248](https://github.com/evanharmon1/harmon-devkit/issues/1248), or the reader throws on the policy. Such a
  repository still gets `needs-triage` maintained, and the job never fails on
  an old reader.

**Event filter and the pin race.** Every `issues` event creates a run, but a
job whose `if` is false is skipped before a runner is assigned, and a skipped
job bills nothing. The event job starts only when all three hold:

- the sender is not a `Bot`;
- the sender is not listed in **`CLASSIFICATION_AGENT_LOGINS`**, a repository
  or organization variable holding a JSON array of agent logins (unset reads
  as an empty list);
- the event changed an input: an issue was opened, typed or untyped, or a
  `risk:`, `complexity:`, `impact:`, `area:`, `layer:`, `domain:` or
  work-type label was added or removed.

`tier:*` (including `tier:pinned`) and `needs-triage` are never inputs. A
human pins with two UI edits in either order (set the Tier label, add
`tier:pinned`), so a Tier or pin edit never starts a job and cannot be
overwritten mid-pin.

The remaining windows are narrow:

- A pin made while a job is already writing. Every Tier write is preceded by
  a read, made after the previous write, that shows no `tier:pinned`. On a pin
  the job stops its remaining Tier writes and reports the issue
  (`pin-appeared`). GitHub's label API has no compare-and-swap, so one round
  trip between that read and its write is the irreducible residual.
  `needs-triage` writes are not guarded, since it is maintained on pinned
  issues too.
- A scheduled run landing between the two pin edits. With the pin added first,
  it sees two tier values and reports them. With the Tier set first, it
  re-derives once, and the human's pin then restores the intended value.

After its Tier writes the job re-reads the issue once. Unpinned, the issue
must carry exactly one rung, the Tier derived from its inputs on that read.
A failed delete or a concurrent run's write breaks that, so one bounded repair
pass runs under the same pin guard; an issue still not exclusive after it is
reported (`tier-not-exclusive`) and fails the run. So does a guard or verify
read that spans more than one page (`pin-guard-indeterminate`), since it can
rule out neither a pin nor a second rung, and so does an API error the repair
does not heal, or any API error outside the Tier writes. A Tier write error
the repair heals is reported (`write-failed`) but is not a failure, and nor is
a pin that stops the Tier writes. Either way the walk moves on to the next
issue, and the run exits 1 after the whole list.

Every write, Tier or `needs-triage`, is decided from the most recent read of
the issue: `needs-triage` from the verify read when Tier writes happened,
otherwise from the read taken just before writing. The same one round trip
between that read and its write is the irreducible residual.

Label writes made with `GITHUB_TOKEN` start no workflow runs, so the
reconciler's own writes never re-trigger the event workflow. `edited` is
deliberately absent. `field_added`/`field_removed` are absent until actionlint
recognizes them ([harmon-init#1485](https://github.com/evanharmon1/harmon-init/issues/1485)),
so an organization repository's field edits are repaired by the schedule, not
instantly.

**Caller wiring.** `GITHUB_TOKEN` is repository-scoped, so each repository
runs the reconcile on its own schedule and walks only its own issues. The
schedule is **monthly** on an organization repository and **daily** on a
personal-account one, rendered from the owner type. An organization that
wants a daily organization-wide walk adds a caller in `<org>/.github` (opt-in;
[harmon-init#1463](https://github.com/evanharmon1/harmon-init/issues/1463)). That caller
mints an installation token from the CI GitHub App that already exists
(`actions/create-github-app-token` over `CI_APP_CLIENT_ID` /
`CI_APP_PRIVATE_KEY`, the same App `claude-*.yml` and `release.yml` use, with
Issues: write and Contents: read on the target repositories). It then calls
`classification-reconcile.yml` with that token as the `CLASSIFICATION_TOKEN`
secret, `use-token: true`, and the organization's repository list as the
`repositories` input. Without them, a walk covers only the calling
repository.

A repository is only ever judged by its own registry and its own policy. The
calling repository uses its checkout. Every other repository in the list has
its `label-registry.json` and `.devflow.toml` read from its default branch
through the contents API, which is why the token needs Contents: read there.
A registry it cannot read makes every axis unverifiable there (no
`needs-triage` change), and a policy or matrix it cannot read makes the Tier
not derivable there (no Tier write); each is reported once per repository.
The reader code is always the caller's: it is the function, not the policy.

The workflow reads the token as
`inputs.use-token && secrets.CLASSIFICATION_TOKEN || github.token`, and
`use-token` is declared only under `workflow_call`. On `schedule` and
`workflow_dispatch` the input is empty, so those runs use `GITHUB_TOKEN`
whatever secrets the repository or organization holds. The supported wide
walk is the `<org>/.github` caller minting a one-hour App installation token
per run; a stored, long-lived `CLASSIFICATION_TOKEN` secret is discouraged
(no PAT, no stored secret).

**Minutes model.** The organizations are on the Team plan with a shared pool,
and most of their repositories are private. A job bills at least one full
minute, and GitHub emits one `labeled` event per label. Expected monthly cost:

| Source | Estimate |
|---|---|
| Monthly schedule (15 private organization repositories × 1 run × 1 min) | ≈ 15 min |
| Event jobs: agents writing under a human login and human UI edits (a burst of label events on one issue collapses to at most two jobs through the per-issue concurrency group) | ≈ 100–150 min |
| **Organizations, total (shared Team pool)** | **≈ 115–165 min** |
| Personal-account repositories, daily: 3 private ≈ 90 min of the personal account's own quota; public repositories run free | ≈ 90 min |

Agent sessions that write under the maintainer's own login look human to the
filter, which is the main event cost. Agents with a login of their own belong
in `CLASSIFICATION_AGENT_LOGINS`. An opt-in daily organization caller would
add about 30 min/month per organization.
## Root-only vs template-shipped workflows

Most root workflows are the rendered form of a `template/` twin and must be
edited in lockstep (AGENTS.md, "Dogfood parity"). A few are **root-only**: they
exist because harmon-init sits inside harmon-platform, and a generated repo has
no such edge. `close-milestone-on-release.yml`, `sync-harmon-devkit.yml`,
`publish-harmon-devcontainer.yml`, and `remote-bootstrap.yml` are root-only;
they have no `template/`
counterpart, and the dogfood checks are
twin-driven (they walk `template/`), so root-only files are correctly invisible
to them. Do not add a twin to make them "consistent".

## harmon-devkit skills propagation

harmon-init vendors harmon-devkit's shared agent skills at a released tag
(`.skills-sync.yaml` and its template twin). `sync-harmon-devkit.yml` automates
everything between the two intentional release gates:

```text
human merges harmon-devkit's release PR  ->  stable tag
        | repository_dispatch (harmon-devkit-released)
harmon-init validates the tag, pins it, vendors, verifies, opens/updates ONE PR
        |
human merges the sync PR, then harmon-init's release PR
```

- **Triggers:** the dispatch and a daily reconciliation `schedule`, so a dropped
  dispatch cannot leave the pin stale. One `concurrency` group serializes them.
  There is deliberately **no `workflow_dispatch`** — see "Token scope" below.
- **Trust:** the payload tag is untrusted. `scripts/sync-devkit-release.sh`
  checks its shape in pure shell (no regex a newline can split), then confirms
  the release exists upstream and is neither a draft nor a prerelease, before
  anything is written. It reaches the helper only through the environment.
- **Token scope:** the checkout keeps `persist-credentials: false`; the App
  token authenticates only the individual `git` calls that talk to origin, via
  a process-scoped credential helper, and the sync and verification targets run
  with `GH_TOKEN` scrubbed. A contents:write credential is therefore never
  visible to the copier renders, `npx`, and `uvx` that `task verify` spawns.
  The workflow is not `workflow_dispatch`-able for the same reason: GitHub
  would run the *selected ref's* workflow definition, so an unreviewed branch
  could rewrite the token-minting step itself — a checkout pinned to `main`
  cannot help, because the token exists by then.
- **Base integrity:** the checkout is pinned to `main`, and the run refuses to
  start unless `HEAD` is `main` and `main` matches `origin/main` — so a
  force-push can never publish unrelated local commits under a bot title. An
  origin that cannot be reached aborts rather than being read as "no sync PR is
  in flight".
- **Pin parity:** `task test:skills-pin-parity` (in `verify` and CI) fails when
  the root and template manifests pin different tags. The `verify:skills*` drift
  checks cannot see this — both read only the root manifest — so a pin edited in
  the template twin alone would otherwise ship a stale pin to generated repos
  and surface only when the next sync run aborts. Root-only: a generated repo
  has one manifest and nothing to compare.
- **Fail-closed:** the run aborts before any push if the two pins already
  disagree, if the tag would move the pin *backwards* — measured against the
  newest tag in flight, so a delayed dispatch cannot drag an open sync PR back
  either; only a manual run may downgrade, as the recovery path off a bad
  release — if `task sync:skills` writes a path outside the manifests,
  provenance, and managed skills, or if `task verify:skills:offline`,
  `task security:secrets`, `task verify:skills`, or `task verify` fails.
  gitleaks runs *before* the push, not just on the PR: this step vendors files
  from another repository, and a pushed secret needs rotating whether or not
  the PR ever merges.
- **One rolling PR:** a deterministic `bot/sync-harmon-devkit` branch, rebuilt
  from `main` every run, so a newer release supersedes an open sync PR instead
  of opening a second one. Replaying an event after the PR merged is a no-op;
  replaying it while the PR is open compares trees and leaves the branch alone,
  so the daily schedule never force-pushes an identical commit or re-triggers
  the PR's checks.
- **Recovery:** send the dispatch by hand (it always runs the default branch's
  definition, unlike `workflow_dispatch`) —

  ```bash
  gh api repos/evanharmon1/harmon-init/dispatches \
    -f event_type=harmon-devkit-released \
    -f 'client_payload[tag]=v0.9.0' \
    -f 'client_payload[allow_downgrade]=true'   # only to roll back a bad release
  ```

  — or run it locally with `task sync:devkit-release -- vX.Y.Z`. A sync PR
  closed by hand is re-opened from the pushed branch on the next run.
- **Never merges.** Not the sync PR, not either repository's release PR.

Renovate keeps its approval-gated harmon-devkit rule as a passive stale-pin
signal and manual fallback. Being Dependency Dashboard-gated, it never opens a
pin PR unattended — but that is not mutual exclusion, and nothing enforces one:
the workflow's `concurrency` group serializes only its own runs, and the helper
looks only for `bot/sync-harmon-devkit`. **Approving the dashboard item while
the automation is healthy therefore produces two PRs for the same bump.** The
duplicate is not silently wrong — Renovate cannot vendor the skills, so a
ref-only pin change fails `verify:skills` until a human finishes it — but the
operational rule is to leave the item unapproved unless the automation is
broken and you are deliberately falling back to the manual route.

The harmon-devkit side of the edge (emitting the dispatch on release) lives in
that repository's `release.yml`.

## Shared devcontainer publication

The root-only `images/devcontainer/` producer and
`publish-harmon-devcontainer.yml` own the common Harmon development toolchain.
Pull requests build candidates without registry credentials; trusted `main`
runs publish immutable source tags and validate anonymous pulls before the
least-privilege CI App token is minted for pin propagation. The complete image,
overlay, bootstrap, monotonic-update, and rollback contract is documented in
[devcontainer-image.md](devcontainer-image.md).

The same producer directory also owns the **remote** path: the install scripts
under `images/devcontainer/install/` and the pins in
`images/devcontainer/versions.env` are run both by that Dockerfile and by
`bootstrap-remote.sh` on a cloud VM that cannot pull the image at all. That is
why a change under `images/devcontainer/` triggers `remote-bootstrap.yml` as
well as the publisher. The bootstrap also installs the agent posture from
`.devcontainer/agent/agent-autonomy.sh` and `.devcontainer/config/agent/`, so a
change under either triggers `remote-bootstrap.yml` too — see
[remote-environments.md](remote-environments.md).

## Authentication

CI workflows authenticate as the **`evanharmon1-ci` GitHub App** (short-lived
tokens minted at runtime), not a PAT — see [security.md](security.md).
The classification reconciler is the exception: it runs on the
repository-scoped `GITHUB_TOKEN` with `issues: write` (see
[Issue classification reconciler](#issue-classification-reconciler)), and an
organization-wide walk receives an App installation token from its caller.
Third-party actions are pinned by commit SHA and bumped by Renovate.

## Releases

release-please opens a rolling release PR from conventional commits; merging it
cuts the tag, GitHub release, and CHANGELOG. Nothing auto-releases on a normal
merge.

TODO: document deployment targets/environments here once they exist; the deploy
how-to lives at [../guides/deploying.md](../guides/deploying.md).

## Runners

Jobs use `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`, so the
`CI_RUNS_ON` variable dynamically controls runner placement without requiring a
commit or template re-render.

### Job-private filesystem contract

CI may run on persistent self-hosted runners. Only `$GITHUB_WORKSPACE` and
`$RUNNER_TEMP` are treated as job-private; the runner empties `$RUNNER_TEMP`
for each job, while files elsewhere can survive and affect another job or
repository. Package-manager and tool-cache setup must not write global
configuration (`pnpm`/`npm`/`yarn config`, `~/.npmrc`, or
`~/.config/<tool>`), pass a persistent store override, or construct a
supposedly private store path from `$GITHUB_WORKSPACE/..`. The shared setup
action therefore puts pnpm's store under `${RUNNER_TEMP}/.pnpm-store` through
a job-scoped environment variable.

Global Git identity and `safe.directory` settings are explicit exceptions.
Workflows set only deterministic, non-secret values needed by the current job;
they do not redirect a mutable package cache, and they disappear with a
recreated runner rather than becoming repository state.

### Variable hierarchy and precedence

Runner selection resolves hierarchically via GitHub Actions variables:

1. **Repository variable (`vars.CI_RUNS_ON`)**: An individual repository can set
   `CI_RUNS_ON` (via `task setup:github` or `gh variable set CI_RUNS_ON --repo`).
   In GitHub Actions, repository variables shadow organization variables of the
   same name. This allows a repository to override the organization default (for
   example, to opt into specialized hardware or pin a specific repository to
   `"ubuntu-latest"`).
2. **Organization variable (`vars.CI_RUNS_ON`)**: Organizations across the platform
   (`ponderousdev`, `harmonops`, `sommerlawn`) define an organization-level
   `CI_RUNS_ON` variable scoped via `selected` visibility to audited private
   repositories (such as `["self-hosted","linux","x64","ponderousdev"]` or
   `["self-hosted","linux","x64","harmonops","contraption"]`). All audited member
   repositories inherit this fleet routing unless explicitly overridden at the
   repository level.
3. **Workflow fallback (`"ubuntu-latest"`)**: If neither a repository variable nor
   an organization variable is defined or accessible, the workflow expression
   cleanly falls back to `"ubuntu-latest"` (or the template's render-time default
   `ci_runs_on_default`).

### Reconciliation and lifecycle

`task setup:github` creates the repository-level variable when it is missing and
preserves every existing value on non-public repositories; it never infers
ownership from a JSON shape. An intentional replacement requires
`scripts/setup-github.sh` with `--replace-ci-runs-on`. Public repositories are
the safety exception and are always canonicalized to `"ubuntu-latest"`.

For `harmon-init` itself (as a public root repository), `task setup:github`
explicitly sets `CI_RUNS_ON="ubuntu-latest"` at the repository variable layer.
Its workflow actions dynamically evaluate `${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`,
so runner selection is driven through the variable while retaining the hardcoded
fallback safety net.

### Security boundaries

That convenience is also the risk: it is a runtime change with no diff and no
review. **Do not point a public repository at a persistent self-hosted runner.**
Workflows here already refuse to check out fork-controlled code on the trusted
aggregate job, but that contract bounds one specific job — it does not make a
long-lived runner safe for untrusted contributions generally. A fork PR that can
execute anything on a persistent runner can read its filesystem, its
credentials, and whatever the previous job left behind.

Before setting `CI_RUNS_ON` to a self-hosted value, audit every workflow for
`pull_request_target` and for any step that runs code from the PR head. Keep
untrusted-contribution workflows on GitHub-hosted runners.
