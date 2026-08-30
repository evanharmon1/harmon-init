# Name decision records by date instead of sequence number

Date: 2026-08-29

## Status

Accepted

Amends two clauses of [the seed record](2026-06-19-record-architecture-decisions.md)
(formerly `0001-record-architecture-decisions.md`): the naming rule
("Numbered sequentially and zero-padded" becomes the date form below) and
the status vocabulary (`Rejected` is added, so a `Proposed` record that is
turned down can say so without renaming). The rest of the seed — one ADR
per file, the Context/Decision/Consequences shape, supersede-don't-edit —
stands unchanged.

## Context

Filing the Dev flow v2 decision records (harmon-devkit milestone "Dev flow
v2", 2026-08-28) surfaced the cost of sequential numbering: an agent filing a
new ADR must first look up the last number in use, and two branches that each
add a record race for the same next number. That race is not hypothetical —
PR #1114 and this repo's own
[0008-versioned-devflow-compatibility-contract.md](0008-versioned-devflow-compatibility-contract.md)
collided on `0008-` exactly this way. The number itself carries no
information a reader can use before opening the file.

## Decision

New decision records are named `YYYY-MM-DD-<kebab-title>.md`, where the date
is the day the record was filed. The name is fixed at creation and never
changes with status: a record filed as `Proposed` keeps its filing date when
it is accepted or rejected (`Rejected` joins the status vocabulary), and the `Status` line
carries the outcome, so no review ever waits on a rename. This amends
[the seed record](2026-06-19-record-architecture-decisions.md)'s naming clause.

- Records already numbered when this was filed keep their existing names,
  as does any numbered record still in flight on a branch at that time (PR
  #1114's Dev flow v2 record, for one). Both the `NNNN-` and `YYYY-MM-DD-`
  forms are valid; nothing is renamed except the template-managed seed,
  which the next bullet covers.
- The seed record is **template-managed and follows the rule itself**: it
  is rendered as `<decisions_seed_date>-record-architecture-decisions.md`,
  where `decisions_seed_date` is a Copier answer defaulting to the scaffold
  date and recorded once, so `copier update` keeps improving the seed's
  content without ever renaming it. A repository scaffolded under the
  numbered convention is re-titled by its next update (the answer defaults
  to that update's date, or the maintainer records an earlier one) — the
  seed's date is a reasonable marker, not a precise historical claim, and
  harmon-init's own copy uses the date its seed was first committed. The
  README links to the seed by that name.

## Consequences

- Filing a new ADR needs no "what's the next number" lookup, and two branches
  adding records in parallel never collide on a number; only the same title
  filed on the same day shares a path, which is a duplicate decision to
  reconcile, not a numbering race.
- Among date-named records, filenames sort chronologically, and the name
  itself tells a reader when the question was raised before they open the
  file; the `Date:` line inside repeats the filing date and `Status` records
  the outcome. Across both forms the directory order is not a chronology —
  every `NNNN-` name sorts before every `YYYY-` name — so sort by the
  recorded `Date:` when the grandfathered records matter.
- A repo's `docs/decisions/` mixes both filename forms indefinitely; a reader
  or tool must treat both as valid ADRs rather than assuming one prefix
  shape.
- The `standardize-repo` skill's decision-record audit rules (harmon-devkit)
  need a follow-up to accept the date form too — filed as harmon-devkit#667
  rather than fixed here, since the skill is vendored, not owned by this
  repo.

**Not:** renumbering or renaming existing records to the new form. Every
inbound link — from other ADRs, `docs/conventions.md`, `specs/`, PR
descriptions, and outside the repo — targets the current filename; renaming
is a broken-link cost for a purely cosmetic gain, since old records are
already dated in their own `Date:` field.

**Not:** dating the file by acceptance. A `Proposed` record has no
acceptance date while it is under review, so an acceptance-dated name would
have to be guessed and then renamed — invalidating the review's links —
exactly the churn this decision removes. The filing date is known the moment
the file exists.

**Not:** keeping sequential numbers and documenting a coordination rule
instead (e.g. "check open PRs before picking a number"). That trades one
coordination step for another, still requires a lookup, and the number still
tells the reader nothing the date doesn't already say better.
