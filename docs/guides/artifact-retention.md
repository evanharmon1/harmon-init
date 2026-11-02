# Workflow artifact retention

Keep ordinary diagnostic reports for **7 days**. A report with a documented
operational need may use **7–14 days**. Use a positive literal `retention-days`
value on every Actions artifact upload; `0` and omission inherit external defaults.
Keep shorter handoffs short. GitHub's repository/organization maximum still caps
the requested lifetime.

## Inventory and policy

This inventory covers the root dogfood and Copier workflow producers, including
uploads hidden inside actions. Re-inventory when an action or workflow changes:
search `upload-artifact`, `uploadArtifact`, `uploadArtifacts`, and `artifact`, then
follow local composites, reusable workflows and third-party action contracts.
A search for explicit upload steps alone misses Lighthouse.

| Surface | Output | Lifetime / policy |
| --- | --- | --- |
| Root `publish-harmon-devcontainer.yml` | Candidate bundle transferred between jobs | **1 day**, deliberately short same-run handoff; preserved unchanged |
| Node template `security-audit-fix.yml` | Candidate audit fix transferred to the trusted PR writer | **3 days**, allows delayed job inspection/retry without long storage; preserved unchanged |
| Astro template `build.yml`, Lighthouse | `.lighthouseci/` reports, manifest, assertions and partial diagnostics | **7 days**, explicit upload including the hidden directory |
| Node/web template `build.yml`, E2E | `playwright-report/` when produced | **7 days**, includes reports from failing tests |
| Root `build.yml` | No web E2E/Lighthouse jobs | No report uploader; the root is a non-web template project |
| Root/template release workflows | Release-please metadata and optional direct Cloudflare deployment | No Actions release-staging artifact upload is currently configured |

The root and template versions of shared behavior must stay in step. Web-only
jobs have no root job twin. The dedicated root `test:artifact-retention` guard
renders Astro, web-app and non-web consumers and checks explicit upload retention,
Lighthouse's internal-upload opt-out, failure-path guards and aggregate verdicts.
It is a root maintenance test rather than a test shipped to consumer repositories.

### Other output boundaries

The local setup composites install tools/dependencies and use dependency caches;
they do not upload diagnostic artifacts. The classification reusable workflow
writes issue classification, not workflow artifacts. Checkout, language/tool setup,
GitHub token creation, GitHub Script comments, and scheduled maintenance/skills
sync workflows have no configured Actions artifact producer. Claude workflows
publish their GitHub comments/PRs through the pinned Claude action; they have no
configured report upload. Recheck action internals when changing these pins.

`actions/cache`, setup-node/uv/pnpm caches, Buildx caches and images in GHCR are
separate storage surfaces. The devcontainer workflows invoke `devcontainers/ci`
and Docker setup/login actions, not `docker/build-push-action`'s build-record
artifact uploader. Their image/cache behavior is unchanged. CodeQL analysis uploads
SARIF to code scanning, rather than an `upload-artifact` report. Lychee writes local
link results; Cloudflare Wrangler publishes Worker versions/deployments.
Terraform plans stay in their existing run-specific local path rather than being
uploaded as diagnostics. Never introduce plan or secret-bearing uploads to satisfy
an artifact checklist.

### Lighthouse and failed runs

The [pinned Lighthouse action](https://github.com/treosh/lighthouse-ci-action/blob/3e7e23fb74242897f95c0ba9cabad3d0227b9b18/action.yml)
has no retention input. Its
[artifact helper](https://github.com/treosh/lighthouse-ci-action/blob/3e7e23fb74242897f95c0ba9cabad3d0227b9b18/src/utils/artifacts.js)
uploads without retention options. Set `uploadArtifacts: false` and use the
explicit bounded upload instead. Keep the same action/config, assertions,
`temporaryPublicStorage`, outputs and comment integration. Temporary public
Lighthouse storage supplies existing report links; it is a separate service with
its own lifetime, not a substitute for the retained Actions diagnostics.

Both report upload steps use `!cancelled()` and require files. Playwright also
requires the detected config. These guards run after a failed test/audit when
available reports exist; a failure before any report is produced uploads nothing.
Lighthouse uses the known `.lighthouseci/` directory because an early failure can
prevent its output variables from being set. Include hidden files explicitly.

Tests and Lighthouse error-level assertions remain blocking. Upload errors also
fail the job and remain visible; a successful report upload cannot turn an earlier
failed step into success. The aggregate still requires the E2E and Lighthouse job
results. Do not add `continue-on-error`, relax assertions, remove dependencies, or
delete reports to work around storage failures. Existing successful-audit comment
publishing continues; early audit failures may lack outputs/comments, with any
available diagnostics retained by the separate upload.

### Release artifacts

Published GitHub Release assets are durable release deliverables, outside this
report-expiration policy. Do not delete or expire them as disposable reports.
There is no release-staging Actions uploader to change today. If one is added,
set **14 days** explicitly for temporary staging, or document a shorter required
handoff lifetime, and publish durable deliverables to the release. Do not add a
staging artifact just to create a retention setting.

## Future retention versus current quota

Shorter retention affects new artifacts. It does not retroactively shorten existing
objects or establish that a full quota has recovered. GitHub documents
[retention applicability](https://docs.github.com/en/organizations/managing-organization-settings/configuring-the-retention-period-for-github-actions-artifacts-and-logs-in-your-organization)
and [artifact expiry and irreversible deletion](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/remove-workflow-artifacts).

Use a separate recovery task if capacity is already exhausted:

1. Inventory existing artifacts per affected repository using the paginated
   `GET /repos/OWNER/REPO/actions/artifacts` API. Record ID, name, size, creation
   time, `expires_at`, expired state and owning run. Include action-managed
   uploads; assess the affected owner's usage, not just one run.
2. Identify diagnostics and release evidence still needed before proposing any
   cleanup. Record what must be preserved/downloaded and who owns the decision.
3. Obtain separate approval for named artifact/run deletion or any billing/settings
   change. This PR authorizes no cleanup and performs none; deletion is irreversible.
4. After capacity is available, run fresh CI and inspect uploaded artifacts, their
   actual expiry dates and downloads. Record upload failures separately from test
   or assertion failures. Do not promise immediate storage-accounting recovery.

The motivating failures were the
[docs Lighthouse upload](https://github.com/ponderousdev/ponderous-docs/actions/runs/41207737058/job/124556505019)
and [site Playwright upload](https://github.com/ponderousdev/ponderous-site/actions/runs/41200352968/job/124536974968).
The latter followed 349 passed tests and 51 skips and requested 30-day retention;
those observations describe those runs, not current quota availability.

## Adoption after the upstream merge

This upstream PR delivers workflow changes, tests and this checklist. Actual
cross-repository rollout is follow-up after the merge. Prefer `copier update` to
a released tag containing the fix, with repository-aware review of local changes;
a separately reviewed adoption PR may apply the merged workflow change sooner.
Do not cut a release or edit the four consumer checkouts as part of this lane.

| Repository | Apply and preserve | Verification and evidence |
| --- | --- | --- |
| [ponderous-site](https://github.com/ponderousdev/ponderous-site) | Replace the local **30-day** Playwright upload with the bounded upstream step without losing reports; apply Lighthouse opt-out plus explicit upload. Preserve browser matrix, runner routing and E2E guards. | Run E2E/Lighthouse and download reports; verify failure diagnostics and failed aggregate verdicts; check new expiry dates. |
| [lawnomator-site](https://github.com/ponderousdev/lawnomator-site) | Apply Lighthouse handling; inventory both PR E2E and scheduled full-browser/report paths. Preserve Chrome/browser customizations and gating. | Verify applicable PR/scheduled reports, cancellation/config guards and assertion failures; record absent producers as not applicable. |
| [ponderous-docs](https://github.com/ponderousdev/ponderous-docs) | Apply Lighthouse handling while retaining its repository-specific Chrome setup and assertion config. | Recheck the cited failed upload, then a fresh report download/expiry and error-level assertion failure. |
| [ponderous-infra](https://github.com/ponderousdev/ponderous-infra) | Inventory every workflow and invoked action before applying relevant changes. Its inspected build has no web report uploader. Preserve infrastructure gates and sensitive-plan handling. | Record absent report producers as not applicable; validate relevant artifacts and infrastructure checks without inventing a web job or uploading plans. |

For each adoption record repository, upstream merge/release, adoption PR and head,
each producer/lifetime, verification run, artifact expiry/download evidence, and
remaining customizations. Capture hands-on checks as follow-ups. Keep current-quota
recovery separate from the adoption PR and its verification status.

The bounded web report preservation also addresses the surface described in
[issue 1008](https://github.com/evanharmon1/harmon-init/issues/1008); this upstream
lane does not edit or close that related issue.
