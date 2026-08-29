# Name decision records by date instead of sequence number

Date: 2026-08-29

## Status

Accepted

Amends the naming clause of
[ADR 0001](0001-record-architecture-decisions.md) ("Numbered sequentially and
zero-padded" becomes the date form below). The rest of 0001 — one ADR per
file, the Status/Context/Decision/Consequences shape, supersede-don't-edit —
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
is the day the decision was accepted. This amends
[ADR 0001](0001-record-architecture-decisions.md)'s naming clause.

- Records already numbered — `0001` through `0008` in this repo, including
  whichever number PR #1114's Dev flow v2 record lands as — keep their
  existing names. Both the `NNNN-` and `YYYY-MM-DD-` forms are valid; nothing
  is renamed.
- `template/docs/decisions/README.md` and the template's copy of
  `0001-record-architecture-decisions.md` carry the same convention into
  every generated repo (harmon-init#1112).

## Consequences

- Filing a new ADR needs no "what's the next number" lookup, and two branches
  adding records in parallel never collide.
- Filenames sort chronologically, and the name itself tells a reader when the
  decision was made before they open the file.
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

**Not:** keeping sequential numbers and documenting a coordination rule
instead (e.g. "check open PRs before picking a number"). That trades one
coordination step for another, still requires a lookup, and the number still
tells the reader nothing the date doesn't already say better.
