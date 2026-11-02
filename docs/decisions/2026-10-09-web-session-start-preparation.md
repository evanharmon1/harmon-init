# Prepare web checkouts from a repository SessionStart hook

Date: 2026-10-09

## Status

Accepted — maintainer decision of 2026-10-09 for
[#1548](https://github.com/evanharmon1/harmon-init/issues/1548).
Amended 2026-11-02 for
[#1671](https://github.com/evanharmon1/harmon-init/issues/1671): the hook's deadline
bounds waiting, without terminating preparation. Live cached-session and detached
worker verification remain human follow-ups.

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
   calls `scripts/session-start-remote.sh` on `startup|resume`, excluding clear
   and compact. Only `CLAUDE_CODE_REMOTE=true` runs
   `task setup:remote`; local sessions and devcontainers do nothing. The wrapper
   warns and exits 0 on preparation failure, preserving session start, and
   prints a one-line complete, degraded (skipped required steps or warnings),
   or failure summary; completed-run details stay on stderr. The hook timeout is
   120 s. Python 3 starts preparation in a new session with stdin closed and both
   output streams in a persistent log under this checkout's Git directory. The
   worker holds an advisory lock until setup exits; overlapping hook invocations
   observe it instead of starting another setup. Only a disposable waiter has a
   90 s deadline. Expiry never signals preparation: the hook exits 0 with a
   still-running summary naming the PID, log and status file when the worker
   holds the run lock. If the worker ended without a status, a warning names
   the log and asks for `task setup:remote` again. Hooks, related
   repos and dependencies may not be ready; the agent must wait for that status
   before work or a manual setup retry. Without `timeout` or Python 3, the
   wrapper skips preparation, warns to run `task setup:remote` manually and
   exits 0. Direct manual task invocations do not take the hook's lock, so they
   must wait for its worker to finish.
3. `task setup:remote` installs current lefthook shims, bootstraps missing siblings
   and fetches existing siblings into the checkout's parent directory, then
   installs frozen dependencies where lockfiles exist. Slow installs run last,
   prioritizing hook and sibling availability before dependency installation.
   The shared fetch script accepts that directory, defaulting to `/workspaces`
   for devcontainers.
   Fetch identifies the sibling by a remote whose final owner/repository path
   matches the configured entry case-insensitively, with `.git` stripped;
   host, scheme, port and leading path do not define identity. This supports
   rewritten URLs, forks with an upstream remote, and linked worktrees.
   It fetches only that matching remote's branch refs into its own
   `refs/remotes/<remote>/*` namespace with an explicit refspec, ignoring
   configured mirror destinations and tag pruning. A read-only parent prevents cloning but still permits existing
   siblings to be fetched. Fetch updates remote-tracking refs and prunes deleted refs; it never pulls,
   checks out or resets. A sibling's working revision and local changes remain
   intact. Fetch failures warn and continue without failing preparation.
4. Repository hooks run only in single-repository web sessions (platform docs,
   2026-09-29). `AGENTS.md` retains the fallback: if preparation did not run,
   including in a multi-repository session or a platform without the hook, run
   `task setup:remote` once before work.

The hook runs the checkout's Taskfile and its dependency installs at session
start in a web session. Open only checkouts you would run `task setup:remote` on.

## Cost and failure

Ordering tradeoff accepted for [#1576](https://github.com/evanharmon1/harmon-init/issues/1576):
sibling network work remains before dependency installs. A slow or unreachable
sibling can consume the hook's 90 s wait before pnpm or uv runs. The
2026-11-02 amendment preserves that order and lets preparation continue after
the hook returns. Expiry is reported as still running while the worker holds
the run lock, with a durable log and status file rather than a failure. If the
worker ended without a status, the warning names the log and asks for a manual
`task setup:remote` retry. A status of `0` means setup finished; the last
`==> setup:remote completed` line in the named log says whether it finished
cleanly or with warnings. Any other status value means failure. After completion
the agent may retry a failed
`task setup:remote` manually. No new setup termination path is introduced.
Persistent run logs and status files remain available for diagnosis.

Measured in this devcontainer on 2026-10-09: cold `task setup:remote` with three
sibling clones took 7.7 s; a warm run with siblings present took well under 1 s.
Harmon-init has no pnpm/uv lockfile. Consumers with lockfiles pay their install
cost on cold starts; these local measurements do not predict all web sessions.
Preparation runs after machine setup and does not consume its five-minute cache
budget (the observed bootstrap took 48–86 s).

Only skipped required steps degrade the summary: a missing tool for an applicable
step, a missing bootstrap helper, or an unwritable clone parent. Routine
not-applicable skips (no lockfile, hook config, or related-repository list) do not.
Missing tools are reported as skipped. Clone and fetch failures are warnings;
other preparation failures produce a non-zero task result, which the hook wraps
in a warning and exit 0. The stdout summary distinguishes a complete run from one completed with
warnings (skipped required steps or clone/fetch warnings), and tells the session to retry
manually on failure. Detailed step output stays on stderr. The task's step summary and installed lefthook shims show what ran;
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
or local work, unrelated-origin refusal, mirror-refspec branch preservation,
linked-worktree/separate-git-dir fetches, read-only-parent fetching, complete
and degraded summaries, warning-only fetch failure, remote-only hook execution and exit 0
on preparation failure. A short real deadline verifies that setup remains alive,
receives no TERM/INT/HUP, survives overlapping hook invocations without a duplicate
setup, and later writes its completion marker. A mutation restoring termination
must fail that regression. A descendant retaining stdout cannot keep the hook
waiting. Root/template twins ship the same behavior. The
bootstrap recipe guard still tests the unchanged machine-only recipe.
A live session from a cached snapshot must still confirm hooks and expected
sibling remote refs without a manual `task setup:remote` run.
