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

- `build.yml` — on push/PR to `main`: lint, security, then the aggregate **`verify`** job.
  Its `pull_request:` trigger carries **no** `types:` filter, so it fires on
  draft `opened`/`synchronize` too. That is load-bearing, not incidental: PRs
  are drafts for their whole automated life (AGENTS.md, "Dev Loop"), and the
  readiness gate that promotes one reads these check results. Narrowing the
  trigger, or gating a job on `github.event.pull_request.draft`, would leave the
  gate with nothing to read until after the handoff it is supposed to authorize.
- `claude-plan` / `claude-implement` / `claude-review` — **mention-only**: an
  explicit `@claude plan` / `@claude implement` / `@claude review` comment or
  review from a sender on the `claude_authorized_members` allowlist. There is no
  label trigger and no open/assign trigger; the retired `claude-plan`,
  `claude-implement`, and `claude-review` labels are gone, because a label or an
  assignment carries no actor the allowlist can check on every path. Each run
  applies `claim:claude` to the target once the sender gate passes and removes it
  in an `always()` cleanup step, so a run that fails or is cancelled leaves no
  stale claim. `claude-implement` opens a **draft** PR as its normal deliverable
  and never promotes it: it cannot complete the readiness gate, so the handoff
  belongs to a shepherd session.
- The `build.yml` security job runs gitleaks + dependency audit + Semgrep CE
  (this repo has no CodeQL workflow — no first-party CodeQL-supported
  language). Generated repos with `use_codeql=true` add `codeql.yml`, and
  their security job runs Semgrep CE only when the repository is private
  without the paid CodeQL opt-in.
- Generated repositories may explicitly opt into `snyk-scheduled.yml` at a
  weekly or daily cadence. It has only schedule/manual triggers, runs Snyk SAST
  and SCA as advisory second-opinion scans, and is never a required PR check.
- `devcontainer-build.yml` — prebuilds the devcontainer images to GHCR on `.devcontainer/**` changes.
- `publish-harmon-devcontainer.yml` — **root-only**: validates and publishes the
  shared amd64/arm64 toolchain image, then maintains its reviewed pin PR.
- `claim-release.yml` — on `issues closed` and on `pull_request closed` **unmerged**,
  releases the claim markers a session left on an issue. It holds `issues: write`
  and parses attacker-writable comment bodies, so it always checks out the
  **default branch** and never a PR head. It only wires events to
  `release-claim.sh` in the vendored `track-work` skill, and no-ops with a
  notice when that script is absent. The template gates it on
  `claim_release_available` — `use_skills_sync` alone, deliberately **not** on
  the `universal` category that carries the script, because categories are
  edited in `.skills-sync.yaml` without updating any copier answer and a
  narrower gate would never re-render for a repo that added them (#622).
- `release.yml` — release-please maintains the rolling release PR.
- `close-milestone-on-release.yml` — closes the milestone matching the tag on release publish.
- `sync-harmon-devkit.yml` — **root-only**: turns a published harmon-devkit
  release into a verified pin-and-sync PR (see below).

## Root-only vs template-shipped workflows

Most root workflows are the rendered form of a `template/` twin and must be
edited in lockstep (AGENTS.md, "Dogfood parity"). A few are **root-only**: they
exist because harmon-init sits inside harmon-platform, and a generated repo has
no such edge. `close-milestone-on-release.yml`, `sync-harmon-devkit.yml`, and
`publish-harmon-devcontainer.yml` are root-only; they have no `template/`
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

## Authentication

CI workflows authenticate as the **`evanharmon1-ci` GitHub App** (short-lived
tokens minted at runtime), not a PAT — see [security.md](security.md).
Third-party actions are pinned by commit SHA and bumped by Renovate.

## Releases

release-please opens a rolling release PR from conventional commits; merging it
cuts the tag, GitHub release, and CHANGELOG. Nothing auto-releases on a normal
merge.

TODO: document deployment targets/environments here once they exist; the deploy
how-to lives at [../guides/deploying.md](../guides/deploying.md).

## Runners

Jobs use `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`, so the
`CI_RUNS_ON` repository variable can move CI to different runners without a
commit.

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
