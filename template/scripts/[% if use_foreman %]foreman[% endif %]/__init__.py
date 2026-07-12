"""Foreman — deterministic supervisor for milestone-driven agent dispatch.

Reads a milestone's (or single issue's) dependency graph from GitHub,
dispatches ready units to isolated headless agents in git worktrees, verifies
their output with the repo's own CI gate, opens PRs, and shepherds those PRs
to mergeable. Every merge is a human decision — foreman never merges.

State of record is GitHub + git, re-derived every tick; foreman stores no
local state files (worktrees and logs are disposable operational artifacts).

Spec: https://github.com/evanharmon1/harmon-init/issues/258
Docs: docs/architecture/foreman.md
"""

__version__ = "0.1.0"
