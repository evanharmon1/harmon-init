#!/usr/bin/env bash
# install-agents.sh — the AGENTS tier.
#
# The Codex CLI only, at the shared image's pin. It is used where an
# environment persists and holds its own Codex login (#1406); ephemeral clouds
# install it and never log in. Every other agent CLI (Claude Code, Copilot, pi,
# opencode, Antigravity, oh-my-pi) stays image-only: they are either
# credential-bearing in a way a shared remote VM must not be, or supplied by
# the remote platform itself.
#
# Installing the CLI is not the same as configuring it: the managed Claude Code
# settings and Codex configuration are #1404's unit, installed through
# install-posture.sh. See docs/architecture/remote-environments.md.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harmon_load_versions

command -v npm >/dev/null 2>&1 ||
    harmon_die "npm is missing — run the core tier before the agents tier"

harmon_npm_global @openai/codex "$CODEX_VERSION" codex

harmon_cleanup_caches
harmon_log "agents tier complete"
