# Gemini Code Review Style Guide

Shared defaults from `docs/review-guidelines.md`; edit that file, then run
`task render:review-guidelines`. Read its repository-specific invariants too.

## Review guidelines

<!-- BEGIN RENDERED REVIEW GUIDELINES -->
### Review priorities

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

### Severity scale

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

Only P0 and P1 gate the local loops; P2s are reported in full and carried into
the pull request description, never withheld for being non-gating; P3s are
reported as P3s. Use these four labels and no others. **A label is a
hypothesis; the adjudicated severity is the verdict**, whichever reviewer
produced it — the reader verifies each finding against the code, fixes what is
confirmed, and records the evidence for what is declined. A finding badged off
this scale, or not badged at all, is adjudicated as at least a P2, never
dropped for being unrecognized.

### Standardize profile

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
<!-- END RENDERED REVIEW GUIDELINES -->

## Gemini-specific guidance

- Give actionable suggestions with a concrete trigger and consequence; use
  markdown code suggestions when helpful.
- Never suggest committing credentials, waiving verification gates, bypassing
  CI checks, or auto-merging.
- Use the shared P0–P3 badges in findings; Gemini's native severity filter is
  configured separately in `config.yaml` and is not a priority mapping.
