# Remove the process-termination hard rule

- **Status:** Accepted
- **Date:** 2026-10-28
- **Related:** [#1827](https://github.com/evanharmon1/harmon-init/issues/1827)

## Context

The [2026-09-02 hook-removal decision](2026-09-02-remove-guard-process-kill-hook.md)
deleted the parser-based enforcement hook but retained a general requirement
for explicit approval before process termination in `AGENTS.md` and
`docs/conventions.md`.

During the omator milestone-19 orchestration run on 2026-10-25/26, nine routine
self-owned lane teardowns went back to the maintainer for approval after the
lanes' PRs had merged. On 2026-10-26, the maintainer said those approval requests
were unwanted and requested removal of the general rule itself.

## Decision

Remove that hard-rule bullet from the root and template `AGENTS.md` files and
the restating bullet from both conventions files. This amends the earlier
decision's retention of the prose rule; the enforcement hook is already gone.

## Not

- **A narrower replacement rule.** The maintainer requested removal of the
  general rule, rather than another approval classifier for routine teardown.
- **Restoring the hook.** Its parser stalled unattended workers, as the earlier
  decision records; restoring it would reintroduce that cost.

## Consequences

The shipped agent guidance no longer requires separate approval for every
process termination. This is an intentional guardrail removal requested by the
maintainer. Every other Hard Rule remains unchanged. Consumers receive the
updated guidance on their next `copier update`.
