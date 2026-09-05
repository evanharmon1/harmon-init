# Research

Research notes: time-boxed spikes that evaluate options against a stated
rubric and end in a recommendation. A note is **evidence for a decision**,
not the decision — the decision itself lands as an ADR in
[../decisions/](../decisions/) or as an OpenSpec change proposal under
[`../../openspec/changes/`](../../openspec/changes/), and this note is what
they cite. Unlike an ADR a note is not append-only: re-run the spike and
revise it when the field moves, and date every claim so a reader can tell
what was true when.

Conventions:

- One note per spike, kebab-case, named for the question rather than the
  answer (`remote-implementer-environments.md`, not `use-sprites.md`).
- Open with the status, the date the sources were read, and the issue that
  asked the question.
- Every capability claim carries a primary-source URL; anything that could
  not be verified against one is marked **unverified** rather than dropped
  or guessed.
- End with a recommendation and the follow-up issues to file, each in the
  repository that owns the work.

- [remote-implementer-environments.md](remote-implementer-environments.md)
  — where implementer agent lanes should run so that lane count is bounded
  by budget and review bandwidth rather than laptop RAM (harmon-init#1120):
  Claude Code cloud, Codex cloud, Coder, remote dev containers, Fly.io
  Sprites and Fly Machines, and the wider sandbox field, scored on one
  rubric.
