# Review guidelines

What every reviewer of this repository is told, in one place: the local
second-model finder (`task challenge` / `task review`, via
`scripts/codex-review.sh`) and, as they adopt it, the reviewers that run on the
pull request. `.devflow.toml`'s `[review_guidelines]` table names this file,
and the finder reads both the table and the file from the review's **base
revision** — the merge base for a branch review, `HEAD` for `--uncommitted` —
never from the working tree, so a change can never rewrite the instructions
that review it. How the file is resolved, and the inline `text` and `*_focus`
alternatives, are in the [Dev flow guide](guides/devflow.md#review-guidelines).
Edit the last section freely; the shared sections are the template's and the
severity scale is gated (see below).

<!-- BEGIN SHARED REVIEW GUIDELINES -->
## Review priorities

Weigh, in this order:

1. **Correctness and contracts.** Does the change do what it claims, on every
   path a reader can reach — including the ones it did not add tests for? Does
   it keep every existing contract: exit codes, file formats, documented
   behaviour, and repository-specific invariants?
2. **Trust boundaries and data.** Authorization bypasses, inputs trusted where
   they should be verified, data-loss or corruption paths, unsafe rollback or
   migration behaviour, secrets reaching logs or arguments.
3. **Failure modes.** Empty state, partial failure, timeouts and retries, races
   and ordering, degraded dependencies — what happens when a step the happy
   path assumes does not hold.
4. **Hidden coupling.** Twins and copies that must move together, assumptions
   another file relies on, tests that pass for the wrong reason.
5. **Fit.** Consistency with this repository's conventions and documentation,
   adequate test coverage (regression tests for anything fixed), documentation
   the change should have updated, and needless complexity where a simpler
   design would do.

Avoid:

- **Style nits.** Formatting and naming are the linters' job; report a name
  only when it will mislead a reader.
- **Speculation.** Tie every finding to concrete files and lines, and to a
  trigger you can support from the code. If the change looks safe, say so
  directly rather than inventing a finding.
- **Repeated findings.** Do not re-raise a finding already answered in-thread;
  read the reply and only revisit it with new evidence.
- **Restating the diff.** Describe the defect and its consequence, not what the
  change does.
- **Scope creep.** Review the change in front of you; pre-existing defects it
  does not touch are observations (P3) unless the change makes them reachable.

## Severity scale

Label every finding with a priority, as its first token. Use this scale:

```text
  P0 — a defect that breaks correctness, security, or data integrity in
       ordinary use, or that breaks an existing contract. Merge-blocking.
  P1 — a real defect or materially wrong design decision with a plausible
       trigger. Merge-blocking unless argued down with evidence.
  P2 — worth knowing, but not merge-blocking: hardening, edge cases behind
       unlikely preconditions, maintainability, non-critical test gaps.
  P3 — cosmetic or purely informational: a naming or wording choice that
       will mislead a reader, an observation with no defect behind it.
       Never gating. The no-style-nits rule above still binds — P3 is the
       floor for findings worth stating, not a licence to report nits.
```

**Calibration.** Check a P1 against these before applying it. They draw the
line; they never license inflating a finding to be heard or softening one
because it does not gate.

- **P2, not P1:** a race or ordering bug that needs two rare events together
  and moves no money or data. State the trigger and why it is rare.
- **P2, not P1:** behaviour in code the change touches that already exists at
  the merge base and that the change does not widen. Say "pre-existing at
  base" in the finding. In code it does not touch, Scope creep above applies.
- **P2 or P3, not P1:** documentation wording, or doc/code drift, that would
  not lead an operator to a wrong action.
- **P1 stays P1:** a defect the change introduces or widens that moves money
  twice or in the wrong direction, crosses a tenant boundary, loses data, or
  leaves drift that would lead an operator to a wrong action — a value that
  breaks a configuration, an unverified safety claim an operator would rely on.

Only P0 and P1 gate the local loops; P2s are reported in full and carried into
the pull request description, never withheld for being non-gating; P3s are
reported as P3s. Use these four labels and no others. **A label is a
hypothesis; the adjudicated severity is the verdict**, whichever reviewer
produced it — the reader verifies each finding against the code, fixes what is
confirmed, and records the evidence for what is declined. A finding badged off
this scale, or not badged at all, is adjudicated as at least a P2, never
dropped for being unrecognized.

## Standardize profile

When the PR description has a `## Review scope` section naming the
`standardize` profile, apply this profile; otherwise the default guidance applies.

Run a STANDARDIZE-APPLICATION review. Judge whether the requested harmon-init
release was applied appropriately to this repository: repository customizations
are preserved, conflicts and `.rej` files are resolved, answers are correct for
this repository, intentional divergences stay intentional, renames are handled,
repo-only tasks and workflows remain wired, version pins agree, and the
repository's actual stack and deployment edge cases still work.

Treat template content as given when reviewing its application. The default
disposition for a finding about template content is **filed upstream**: this
sets where the fix is made, never the finding's severity. A confirmed P0 or P1
that affects this repository still blocks the lane. It needs a repository-local
override, a release choice that avoids the defect, or escalation; file the
template defect upstream as well. Do not downgrade a finding because its fix is
upstream.

<!-- END SHARED REVIEW GUIDELINES -->

The severity scale above is the single normative statement.
`scripts/codex-review.sh`, when enabled, sends the same definitions;
`task test:codex-review` checks they match. Change the scale here and mirror
it there in the same commit. The calibration examples are not part of that
copy: they reach the finder through this file. The adjudication protocol,
loop caps and findings record follow the enabled review policy in `AGENTS.md`.

## Known limits

Accepted gaps in how reviewers read these guidelines, each with its reason and
what a maintainer does about it. The last three apply only where the Claude
review workflow is enabled.

- **A pull request can edit the shared sections and their rendered copies
  together.** Reviewers that load agent instruction files or a styleguide read
  those copies from the pull request head, and the drift guard compares head
  with head. Accepted: the rest of those files is head-resident too, the local
  finder and the Claude review read this file at the base revision, and the
  edit is in the diff a human reviews before merge. Review any change to the
  shared sections, or to their copies, as a change to review policy.
- **The pull request that adds this file cannot get a completed Claude
  review.** Its base has no copy to read, so the review reports itself
  incomplete and never posts a completion marker. Accepted: it happens once per
  repository, and a bootstrap that read the file from the pull request would
  reopen the first limit. Rely on the other reviewers for that pull request.
- **The Claude review and the local finder can read different base commits.**
  The Claude review reads at the base commit GitHub records for the pull
  request (`base.sha`); the local finder reads at the merge base. Accepted: for
  a pull request into the default branch both commits are on that protected
  branch, so neither is under the pull request's control, and at worst the two
  read adjacent versions of the same rules. No action is needed.
- **The Claude review needs a runner that can start containers.** Its GitHub
  tools run in a container. Accepted: GitHub-hosted runners support it. Confirm
  container support before pointing the review at an isolated runner pool.

## Repository-specific invariants

Rules every change to this repository must keep that a reviewer could not infer
from the diff alone. Keep each one to a single sentence a reviewer can check,
and name the gate that enforces it where one exists; a reviewer treats a
violation here as at least a P1.

- _None recorded yet. Add this repository's own invariants here._
