# Herdr — workspaces, panes, agents, and multi-harness orchestration

Herdr is the agent-session runtime in this repo's devcontainers and on your
laptop: a terminal workspace manager that recognizes the coding agent running
in each pane, tracks its state, and exposes the whole thing through the
`herdr` CLI. This guide is how to *use* it for real work — the mental model,
the everyday workflows, how it pairs with the repo's worktree tooling, running
several agents (and several harnesses) at once, and the lifecycle and cleanup
that keep the sidebar meaningful. Installation, the devcontainer volumes, and
attaching from a laptop are in [devcontainers.md](devcontainers.md) § Persistent
agent sessions; the decision rule for worktrees is [worktrees.md](worktrees.md).

The installed binary is the authority for syntax: `herdr --help`, then a
command group without a subcommand (`herdr agent`, `herdr pane`, …) prints its
commands. Agents inside Herdr have a vendored skill for this (`herdr --skill`);
what follows is the human's map of the same ground.

## The five nouns and how they relate

| Noun | What it is | ID shape | Created by |
| --- | --- | --- | --- |
| **Workspace** | A project root: a directory (or a worktree) plus its tabs | `w1` | `herdr workspace create --cwd PATH` or `herdr worktree create/open` |
| **Tab** | A layout page inside a workspace | `w1:t1` | `herdr tab create --workspace w1` |
| **Pane** | One terminal (shell) inside a tab | `w1:p1` | `herdr pane split --pane ID --direction right` or `down` |
| **Agent** | The coding agent Herdr recognizes *occupying* a pane | pane ID or a unique name | `herdr agent start NAME --kind KIND --pane ID` |
| **Session** | A whole Herdr server (the `default` one, or `herdr --session NAME`) | name | `herdr` / `herdr --session NAME` |

The relationships that matter:

- **A pane exists whether or not it hosts an agent.** `pane run` drives an
  ordinary shell; `agent start` requires an *available* shell pane (at its
  prompt, nothing in the foreground) and never creates layout itself.
- **An agent is a full, independent process in its pane** — a real `claude`,
  `codex`, `agy`, `opencode`, … session with its own context, auth, and
  permissions. Its lifetime is the pane's: close the pane and it dies.
- **A name follows the pane's current occupant** and is cleared when that
  agent exits. Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among
  live agents; agent commands accept a name or the hosting pane ID, never a
  terminal ID or a bare kind.
- **Two kinds of workspace.** `workspace create` makes a plain
  directory-rooted workspace — no git involvement. `worktree create` makes a
  git worktree *and* a workspace rooted at it, and records the binding; one
  worktree ↔ one workspace. Creating a workspace never creates a worktree;
  creating a worktree always creates a workspace.
- **Caller context.** Herdr injects `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`,
  `HERDR_PANE_ID` into every managed pane (and `HERDR_ENV=1`). Prefer
  `--current` or an explicit ID; an omitted target may resolve to the
  UI-focused pane, which can be someone else's.

## Agent lifecycle states

Herdr classifies a pane's agent by watching its terminal:

- `working` — producing output / running tools.
- `blocked` — Herdr recognized an approval or question UI; it needs input.
- `idle` — ready for input, and its tab has been *seen* in the focused UI.
- `done` — the same underlying idle state after unseen background work
  finished. Focusing the tab or targeting the pane/agent with a focus command
  marks it seen; CLI reads do not. `done` is therefore the sidebar's
  "to-review" queue.
- `unknown` — an agent is present but Herdr cannot classify it confidently.
  It does **not** mean finished.

`herdr agent explain <target>` shows which detection rule fired and on what
evidence — the first thing to run when a state looks wrong.

## Everyday workflows

**One agent, one repo (the default).** Open or attach with `herdr`, create a
workspace for the repo if it is not there, start the agent in the root pane
(or just run `claude` in the shell — Herdr recognizes it either way). Use
tabs for parallel *contexts* (a second agent on a different task, a shell for
logs), panes within a tab for things you want side by side.

**A second pane for a command or a helper agent, keeping your focus:**

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
#   → read .result.pane.pane_id
herdr pane run <id> "task verify"
herdr pane wait-output <id> --match "verify: ok" --timeout 600000
herdr pane read <id> --source recent-unwrapped --lines 120
```

Split a wide pane right and a tall one down; avoid repeated same-direction
splits that leave unusable slivers. `pane run` sends text plus Enter
atomically; `wait-output` matches the current snapshot immediately, so output
that already exists counts.

**Starting and steering an agent in that pane:**

```bash
herdr agent start reviewer --kind codex --pane <id> -- <native args…>
herdr agent prompt reviewer "Review the current diff; report only actionable findings." --wait --timeout 600000
herdr agent read reviewer --source recent-unwrapped --lines 120
```

Native agent arguments go after `--`. `agent prompt --wait` returns at the
first settled `idle`/`done`/`blocked`; `--until STATE` is for state-specific
waits. A prompt sent from a non-working state must produce an observed state
change within about five seconds or Herdr returns `agent_prompt_stalled`
rather than waiting forever. If a wait returns `blocked`, `agent get` /
`agent read` first, then `agent send-keys` (logical keys — `esc`, `ctrl+c`,
`enter`) or `agent attach` to take the pane over yourself.

**Reading long answers.** Many harnesses render on the alternate screen, and
rows that leave it never enter Herdr's scrollback — raising `--lines` cannot
recover them. Ask the agent to write its full answer to a file and reply with
the path, then read the file.

## Worktrees

Herdr's `worktree create` is `git worktree add` plus a workspace, checked out
under `[worktrees] directory` (default `~/.herdr/worktrees/<repo>/<branch>`);
`worktree open` binds an *existing* checkout to a new workspace; `worktree
list` shows worktrees for the repo, including ones Herdr did not create;
`worktree remove --workspace ID [--force]` tears down the workspace — tabs,
panes, sessions — and the checkout together. There is **no post-create
hook**: a fresh tree has no dependencies installed, no local env, and no
hooks proof, which is the failure everyone hits first.

So for repos generated from this template, **the repo creates and Herdr
binds**:

```bash
task worktree:new -- feat-x --branch feat/x
herdr worktree open --path .worktrees/feat-x --label feat-x --no-focus
# …work…
herdr worktree remove --workspace <id>     # panes + sessions
task worktree:rm -- feat-x                 # repo bookkeeping, gitlink prune
```

If you use `herdr worktree create` directly, provision before any agent
starts: `herdr pane run <root-pane> "task install"` and `wait-output` for it,
then `agent start`. Environment variables are the only "setup" Herdr itself
offers — `worktree create`, `tab create`, and `pane split` all take
`--env KEY=VALUE` — which is the right place for gate variables an
orchestrator sets under explicit human authorization (never in the worker's
prompt). When to reach for a worktree at all is [worktrees.md](worktrees.md).

## Fan-out: orchestrating many workers from one session

A Claude Code (or any) session running inside a Herdr pane can act as an
**orchestrator**: it shells out to `herdr` to create panes, start workers,
prompt them, wait, and harvest. The orchestrator is just another agent in
another pane; Herdr has no parent/child concept — the topology is conversational.

**Subagents versus pane workers.** These are different things and the words
matter:

- A **subagent** (Claude Code's `Agent` tool, `.claude/agents/*.md`) runs
  *inside* the parent session's process: its own context window, no terminal,
  one structured return value, dies when done. Only the parent can talk to
  it, and Herdr cannot see it — there is no pane to watch.
- A **pane worker** (a "worker session", "sibling agent", "teammate") is a
  full independent session in its own pane, with its own harness, login, and
  permissions. Herdr sees it, you can click into it, steer it, or take it
  over, and it can outlive or ignore the orchestrator. Results come back as
  terminal text and files, not a typed return.

Use subagents for cheap, fast, structured fan-outs you do not need to watch;
use pane workers when you want visibility, steerability, longer-running work,
or a **different harness** than the orchestrator's.

**The loop** (each step is a `herdr` command the orchestrator runs):

1. **Lay out** — a fresh tab for the fan-out, one pane per unit, each with
   its cwd (a worktree for work that edits the repo; the checkout itself for
   pane jobs): `tab create --workspace … --label … --no-focus`, then
   `pane split … --cwd … --no-focus`; `--env` for any authorized gate variables.
2. **Start** — `agent start <name> --kind <kind> --pane <id> -- <native args>`
   with a distinctive name per unit (`triage-omator`, `prune-site`).
3. **Prompt** — one self-contained brief per worker, ending with a
   **file-based report** at a known path and a **sentinel line** (a unique
   string such as `TRIAGE-WORKER-DONE omator`) printed last. Then
   `agent prompt … --wait --until working` and re-send if the worker stays
   `idle` — delivery can silently miss when the harness is mid-render.
4. **Wait** — `agent wait <name>` per worker (background it; rounds run
   minutes), or `pane wait-output --match <sentinel>` where detection is
   weak. `done`/`idle` means *stopped*, not *succeeded*: the sentinel and
   the report file are the success signals.
5. **Harvest and verify** — `agent read` / read the report files, then
   **verify ground truth yourself** (the diff, the labels on GitHub, the test
   run). Never trust a transcript's claim of success.
6. **Review** — anything `blocked`, `unknown`, or surprising: `agent focus`
   to mark it seen and look, `agent attach` to take over, or prompt it again
   with its context intact (the reason to keep a pane alive).
7. **Retire** — close what you created: `tab close` (which closes its panes
   and kills their processes) or `worktree remove --workspace` for
   worktree-backed units. Never close panes, tabs, or workspaces you did not
   create unless asked; never `herdr server stop` from a live session.
8. **Sweep** — the durable leftovers Herdr does not remove: worktrees
   (`worktree list` + `task worktree:rm`), branches (`task clean:branches`),
   scratch files and sidecars, and anything a worker deliberately detached.
   `herdr notification show` can announce the result.

What is mechanical: closing a tab/pane/workspace terminates everything running
in it (verified — no orphaned agent processes); `worktree remove` removes the
checkout with the workspace. What is on you: steps 5 and 8.

## Multiple harnesses — supported and sanctioned

The orchestration surface is harness-agnostic. `--kind` accepts every agent
Herdr can recognize (`herdr agent` lists them: `claude`, `codex`, `gemini`,
`agy` (Antigravity), `opencode`, `copilot`, `cursor`, `amp`, `droid`, `kimi`,
`qwen`, `kilo`, `cline`, …), and nothing about the loop above changes except
the kind and the native arguments after `--`. A Claude Code orchestrator can
therefore drive Codex, Antigravity, or OpenCode workers — each a separate,
official client running under **its own provider login and subscription**.

That is the permitted shape, and it is worth being precise about why. Each
worker is the vendor's **official CLI**, authenticated as you, driven through
its terminal by a multiplexer that never touches tokens or APIs — the same as
typing into it yourself. What vendors prohibit is using one product's
subscription credentials *inside a different product*: Anthropic's consumer
terms forbid Claude Free/Pro/Max OAuth tokens in any third-party tool or
harness (enforced by token blocking since early 2026); Google and OpenAI keep
similar lines. Running the official `claude`, `codex`, `agy`, or `opencode`
binaries side by side, each on its own plan, is on the right side of every
one of those lines; pointing OpenCode at a Claude subscription is not. The
practical constraint is quota: parallel workers spend each plan's 5-hour and
weekly pools faster, not differently — watch each harness's own usage
indicator, and move genuinely unattended, high-volume work to that vendor's
API billing.

Per-harness notes that shape the launch line:

- **`claude`** — `-- --model <m> --allowedTools '<exact list>'` pre-approves
  the tools the task needs and nothing else, so no permission prompt appears.
  Detection is clean; gate variables belong on the pane (`--env`).
- **`codex`** — `-- -a never -s workspace-write -c sandbox_workspace_write.network_access=true`
  for unattended runs, **plus** a rules file that allows every command the
  task will run: with `-a never`, any command a rule marks as prompt-worthy is
  rejected before a shell spawns (`Rejected("approval required by policy, but
  AskForApproval is set to Never")`) with no stderr, and prefix rules match
  the first token only, so a wrapped invocation and a bare one can behave
  differently. Detection is clean (`osc_title_working`); always confirm
  `working` after a prompt.
- **`agy`, `opencode`, others** — same loop; check detection with
  `agent explain` on first use, and fall back to the file report + sentinel
  where it is `unknown`.

Worker briefs should also say: never set gate or approval variables yourself;
if a script refuses, stop and report. A capable model will otherwise export
the variable to get unstuck.

## Cheat sheet

```bash
herdr workspace list | tab list --workspace W | pane list --workspace W | agent list
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr agent start NAME --kind KIND --pane ID [--timeout MS] -- ARGS…
herdr agent prompt NAME "…" --wait [--until working|blocked] --timeout MS
herdr agent wait NAME [--until STATE] --timeout MS
herdr agent read NAME --source recent-unwrapped --lines 120
herdr agent explain NAME          # why Herdr thinks it is in that state
herdr agent send-keys NAME esc    # logical keys, validated before writing
herdr tab close T                 # closes panes, kills their processes
herdr worktree open --path P --label L --no-focus | herdr worktree remove --workspace W
herdr notification show "title" --body "…"
```
