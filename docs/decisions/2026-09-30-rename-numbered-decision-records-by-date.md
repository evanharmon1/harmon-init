# Rename numbered decision records by date

Date: 2026-09-30

## Status

Accepted — maintainer decision of 2026-09-30, recorded on
harmon-init#1446: date-named records are a harmon-platform-wide standard.
Amends [2026-08-29-name-decision-records-by-date.md](2026-08-29-name-decision-records-by-date.md)
wherever that record keeps numbered names or treats the two filename forms as
permanently mixed — its grandfathering, its mixed-directory and cross-form
ordering consequences, and its rejection of renaming; the date-naming rule
itself and the seed-record mechanism stand.

## Context

The 2026-08-29 naming record adopted date names for new records only, leaving
`docs/decisions/` mixed; the maintainer has since made the date form the
standard across harmon-platform.

## Decision

Every record is named `YYYY-MM-DD-<kebab-title>.md`, dated by its own `Date:`
line; existing numbered records are renamed with `git mv` so history follows,
and in-repo references move in the same change; the template-shipped
`0008-versioned-devflow-compatibility-contract.md` is renamed too, so generated
repos transition on their next `copier update`; other harmon-platform
repositories rename their own records under their own issues.

## Consequences

- Links to the old paths on a branch (`blob/main/…/0005-…`) stop resolving,
  because GitHub does not redirect a renamed file; links pinned to a commit SHA
  keep working.
- A generated repo that edited its copy of the shipped `0008` record must
  re-apply that edit to the renamed file in its update PR, since Copier sees
  the rename as a delete plus an add; that is handled in the downstream update
  PR under the rolling-update policy (AGENTS.md "Critical Copier Gotchas").
- Records filed on the same day share a date prefix, so prose names such a
  record by date and title (for example "ADR 2026-08-29 (Dev flow v2)").
- Links from other harmon-platform repositories into these records break the same
  way; harmon-devkit's are tracked in harmon-devkit#1254. A reference this
  repository makes to another repository's record by number, such as
  harmonops/harmon-infra's ADR-0006 in the template's Terraform workflow, stays
  correct only until that repository renames its own records.
- The `standardize-repo` audit must now report a remaining numbered record as
  drift and recommend renaming it, which widens the follow-up the 2026-08-29
  naming record states as accepting the date form too (harmon-devkit#667).

**Not:** redirect stubs at the old paths — offered to the maintainer on
2026-09-30 and not chosen.
