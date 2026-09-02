# Specs

Task-scoped specifications — the **source of truth for WHAT to build**. A spec
captures the intent, requirements, and acceptance criteria for a feature or
change before it is built, in a form a contributor or AI agent can implement
against. (Specs cover *what* and *why*; `docs/architecture/` covers *how*, and
`docs/decisions/` records *why a choice was made*.)

## Relationship to `openspec/`

[`openspec/`](../openspec/) (see [docs/decisions/2026-09-01-adopt-openspec.md](../docs/decisions/2026-09-01-adopt-openspec.md))
now owns change proposals and capability specs for developing this
repository itself — `openspec/changes/<name>/` is the spec of record for an
in-flight change, and archiving one updates `openspec/specs/`. This
directory keeps its other two jobs: `issue-strategy.md`, and the Claude
Design handoff bundles below; it is not otherwise superseded by OpenSpec.

## How to write a spec

1. Copy the [spec template](_template.md) to a task-scoped file, e.g.
   `specs/user-login.md`.
2. Fill in the problem, goal, requirements, and **Given / When / Then**
   acceptance criteria.
3. Keep one spec per feature/change; link it from the implementing PR, and
   update or supersede it as the work evolves.

## Design handoff bundles

Claude Design exports (the `implement-design` skill's input) are unpacked into
**subdirectories** here — `specs/handoff-<feature>/`. They are vendored,
temporary reference material: ignored by git and every linter (`specs/*/` in
the ignore configs) and **deleted at sign-off**, never committed. Top-level
`specs/*.md` spec files stay tracked and linted as usual.
