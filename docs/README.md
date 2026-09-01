# Harmon Init Documentation

Copier project template that scaffolds repos with pre-configured DevOps tooling, CI/CD, linting, security checks, git hooks, and task runners

This is the **hub** — read it when you're unsure where something belongs. It
**routes; it does not hold facts.** Every doc has a _type_ and lives in a
_bucket_.

## The four buckets

| Bucket | Answers | Holds |
|---|---|---|
| [product/](product/) | **Why does it exist / who is it for?** | business & problem-space knowledge — the non-code, non-how layer |
| [architecture/](architecture/) | **How is it built / secured / governed / tested?** | the durable narrative of how the system _is_; home for subject hubs |
| [decisions/](decisions/) | **Why was this choice made?** | append-only, backward-looking records — they stop agents from "helpfully" undoing deliberate choices |
| [guides/](guides/) + [runbooks/](runbooks/) | **How do I do X?** | procedures — `guides/` are calm (read in advance), `runbooks/` are crisis (read under pressure) |

## Doc types

- **Hub** — every `README.md`. Routes to where facts live; never duplicates them.
- **Typed** — holds one kind of content (a vision, an ADR, a guide…).
- **Flat lookup** (root) — [conventions.md](conventions.md), [glossary.md](glossary.md), [copier-options.md](copier-options.md): grep them, don't read them.
- **Procedural, run-once** — [CHECKLIST.md](CHECKLIST.md): tick through once when the repo is created, then ignore.

## Where things are

| Area | Where |
|---|---|
| Conventions (enforced rules) | [conventions.md](conventions.md) |
| Glossary (term → definition) | [glossary.md](glossary.md) |
| Copier inputs (questions, hidden answers, fleet answers) | [copier-options.md](copier-options.md) |
| Product — vision, roadmap, domain | [product/](product/) |
| Architecture (subject hubs) | [architecture/](architecture/) — ci-cd, security, branch-protection, tests |
| Decisions (ADRs) | [decisions/](decisions/) |
| Guides (calm how-tos) | [guides/](guides/) — onboarding, deploying, troubleshooting, devcontainers, devflow |
| Runbooks (crisis procedures) | [runbooks/](runbooks/) |
| Project management (GitHub Projects) | [project-management.md](project-management.md) |
| Post-generation setup | [CHECKLIST.md](CHECKLIST.md) |

Design intent is at [`../DESIGN.md`](../DESIGN.md); specs (WHAT to build) in
[`../specs/`](../specs/) and tests in [`../tests/`](../tests/) — all at the repo root.
