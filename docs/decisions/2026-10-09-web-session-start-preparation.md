# Prepare web checkouts from a repository SessionStart hook

Date: 2026-10-09

## Status

Accepted — maintainer decision of 2026-10-09 for
[#1548](https://github.com/evanharmon1/harmon-init/issues/1548).
Live cached-session verification remains a human follow-up.

## Context

Claude Code on the web uses one environment for all repositories. Its setup
script provisions the machine and builds a snapshot cached for about seven days
(platform docs, 2026-09-29). Observed 2026-10-06: the checkout exists before that
script runs. Observed 2026-10-07: a cached start resumes a checkout and fetches
it forward, rather than cloning it again. Those observations make preparation
in setup possible, but do not make the environment script the right owner of
one repository's hooks, lockfiles or sibling list.

A snapshot can retain old hooks and sibling clones. Bootstrap skips a sibling
already present, so repeating it alone does not expose newer upstream revisions.
Preparation needs to use the current checkout's configuration on every start.
The [web guide](../guides/claude-code-web.md#when-per-checkout-preparation-runs)
retains the observed evidence separately from this decision.

## Decision

1. The environment setup script remains repository-independent: the machine
   bootstrap only. Its recipe does not change.
2. The repository's `.claude/settings.json` installs a `SessionStart` hook that
   calls `scripts/session-start-remote.sh`. Only `CLAUDE_CODE_REMOTE=true` runs
   `task setup:remote`; local sessions and devcontainers do nothing. The wrapper
   warns and exits 0 on preparation failure, preserving session start, and
   prints a one-line completion or failure summary.
3. `task setup:remote` installs current lefthook shims, installs frozen
   dependencies where lockfiles exist, bootstraps missing siblings and fetches
   existing siblings into the checkout's parent directory. The shared fetch
   script accepts that directory, defaulting to `/workspaces` for devcontainers.
   Fetch updates remote-tracking refs and prunes deleted refs; it never pulls,
   checks out or resets. A sibling's working revision and local changes remain
   intact. Fetch failures warn and continue without failing preparation.
4. Repository hooks run only in single-repository web sessions (platform docs,
   2026-09-29). `AGENTS.md` retains the fallback: if preparation did not run,
   including in a multi-repository session or a platform without the hook, run
   `task setup:remote` once before work.

## Cost and failure

Measured in this devcontainer on 2026-10-09: cold `task setup:remote` with three
sibling clones took 7.7 s; a warm run with siblings present took well under 1 s.
Harmon-init has no pnpm/uv lockfile. Consumers with lockfiles pay their install
cost on cold starts; these local measurements do not predict all web sessions.
Preparation runs after machine setup and does not consume its five-minute cache
budget (the observed bootstrap took 48–86 s).

Missing tools are reported as skipped. Clone and fetch failures are warnings;
other preparation failures produce a non-zero task result, which the hook wraps
in a warning and exit 0. The summary tells the session to retry manually when
needed. The task's step summary and installed lefthook shims show what ran;
remote-tracking refs show which sibling revisions are available. A fetch makes
new revisions available without moving the checked-out revision.

## Alternatives

- **Prepare in the environment setup script.** It can see a checkout, but serves
  every repository and only runs when the cache rebuilds. Preparing whichever
  checkout happened to build the snapshot leaves later sessions dependent on
  stale configuration and siblings, and a failing setup step can fail start.
- **Keep only the AGENTS.md instruction.** It works across platforms and remains
  the fallback, but relies on each session remembering it. The repository hook
  provides automatic preparation where the platform supports it.

## Verification

The existing setup-remote fixture suite proves fetch-forward without moving HEAD
or local work, warning-only fetch failure, remote-only hook execution and exit 0
on preparation failure. Root/template twins ship the same behavior. The
bootstrap recipe guard still tests the unchanged machine-only recipe.
A live session from a cached snapshot must still confirm hooks and expected
sibling remote refs without a manual `task setup:remote` run.
