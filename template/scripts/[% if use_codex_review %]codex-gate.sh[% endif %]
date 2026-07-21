#!/usr/bin/env bash
# codex-gate.sh — enable/disable/inspect the automatic Claude → Codex
# "stop-gate" review for THIS repo on THIS machine.
#
# The gate ships with the `codex@openai-codex` Claude Code plugin: a Stop hook
# that, when a Claude turn finishes, has Codex review the turn (read-only) and
# blocks Claude from stopping (BLOCK: <reason>) until material issues are
# addressed. The hook is always registered while the plugin is installed;
# whether it acts is a per-workspace `stopReviewGate` flag in the plugin's
# data dir. This script flips that same flag through the plugin's own
# companion runtime — identical state to running
# `/codex:setup --enable-review-gate` inside Claude Code — so the toggle is
# scriptable (task codex:gate:enable / codex:gate:disable / codex:gate:status).
#
# Usage: codex-gate.sh <enable|disable|status>
#
# Notes:
#   - The flag is per-user, per-machine, per-workspace path — never committed.
#     A git worktree is a different workspace path with its own flag.
#   - Upstream is fail-open by design: with the gate on but Codex missing or
#     unauthenticated, the hook logs guidance and lets Claude stop.
#   - Claude Code caps consecutive stop-hook continuations, so an enabled gate
#     cannot loop forever; the AGENTS.md 3-iteration policy still applies.
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-}"
case "$ACTION" in
enable | disable | status) ;;
*)
    echo "usage: $0 <enable|disable|status>" >&2
    exit 2
    ;;
esac

if ! command -v node >/dev/null 2>&1; then
    echo "node is required (the gate toggle drives the Claude Code codex plugin's Node runtime)." >&2
    exit 1
fi

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
manifest="${claude_dir}/plugins/installed_plugins.json"

plugin_root=""
if [ -f "$manifest" ]; then
    plugin_root="$(node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const entries = (manifest.plugins || {})["codex@openai-codex"] || [];
if (entries.length > 0 && entries[0].installPath) process.stdout.write(entries[0].installPath);
' "$manifest" 2>/dev/null || true)"
fi
if [ -z "$plugin_root" ] || [ ! -f "${plugin_root}/scripts/codex-companion.mjs" ]; then
    # Fallback: newest cached copy (lexical sort — fine for a fallback).
    for d in "${claude_dir}"/plugins/cache/openai-codex/codex/*/; do
        if [ -f "${d}scripts/codex-companion.mjs" ]; then
            plugin_root="${d%/}"
        fi
    done
fi
if [ -z "$plugin_root" ] || [ ! -f "${plugin_root}/scripts/codex-companion.mjs" ]; then
    cat >&2 <<'EOF'
The codex Claude Code plugin is not installed for this user.
Install it inside Claude Code:
  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
(This repo's .claude/settings.json also offers it automatically when you
trust the folder in Claude Code.) See docs/guides/codex-review.md.
EOF
    exit 1
fi

# Write the SAME per-workspace state the Claude Code hook reads: outside
# Claude Code the companion falls back to a temp dir, so pin CLAUDE_PLUGIN_DATA
# to the plugin's real data dir (~/.claude/plugins/data/<plugin>-<marketplace>).
export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-${claude_dir}/plugins/data/codex-openai-codex}"

case "$ACTION" in
enable) exec node "${plugin_root}/scripts/codex-companion.mjs" setup --enable-review-gate ;;
disable) exec node "${plugin_root}/scripts/codex-companion.mjs" setup --disable-review-gate ;;
status) exec node "${plugin_root}/scripts/codex-companion.mjs" setup ;;
esac
