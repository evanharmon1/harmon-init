# Remove the guard-process-kill hook

- **Status:** Accepted
- **Date:** 2026-09-02
- **Related:** #1106, #1118, #1122, #1123, #1137

## Status

Accepted.

## Context

`guard-process-kill.sh` was a Claude Code / Codex / Antigravity `PreToolUse`
hook that re-parsed every Bash command to ask before anything that could
terminate a process. It backstopped the hard rule in `AGENTS.md` ("never
terminate a process without explicit user approval").

Answering "could this shell text terminate a process?" without running the
shell is not a finite problem. Each review round (#1106, #1118, #1122, and
the residuals in #1123) found the next quoting or executor corner and grew
the parser; by 2026-09-01 it was roughly 600 lines of Python inside a shell
script, and one day of unattended work in the #1137 program surfaced five
more false positives (a path containing `kill`, nested quotes inside
`$(...)`, an escaped backtick, `timeout`, and a `)` inside a comment). A
fix branch that closed those shapes still had residuals of its own, and a
single prompt is enough to stall an unattended worker silently. The hook
had no recorded save.

## Decision

Delete the hook and every registration of it: the four byte-identical
copies (root and template, `.claude/hooks/` and
`.devcontainer/config/claude-hooks/`), the Claude project settings entry,
the managed-settings entry, the Antigravity `hooks.json` entry, and the
hook's test sections. The hard rule stays in `AGENTS.md` and in
`docs/conventions.md`, binding the agent directly.

Not: keep hardening the parser. Convergence would require a bash parser,
and every round had been converging on a bigger classifier rather than on a
policy. Not: keep the hook only in the human devcontainer profile. That
would keep four twins and a test suite alive for a control whose measured
cost was prompts and whose measured benefit was zero; if a real accidental
termination ever happens, that incident is the place to reconsider.

## Consequences

Agents in every profile can run `timeout`, `grep kill`, paths containing
`kill`, and quoted substitutions without a permission prompt. Nothing
mechanical stops an agent from killing a process; the rule in `AGENTS.md`
and the `permissions.ask` backstops for merges are the remaining controls.
Issue #1123 closes as not planned. Consumers pick the removal up on their next
`copier update`, which deletes the hook copies and drops the settings
entries; a consumer that had added its own reference to the hook path must
remove it.
