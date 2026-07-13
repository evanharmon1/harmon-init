#!/usr/bin/env bash
# claude.sh — Foreman backend adapter for Claude Code (headless print mode).
#
# Contract (see scripts/foreman/backend.py):
#   claude.sh run                  dispatch with $FOREMAN_PROMPT_FILE
#   claude.sh resume <session-id>  resume a prior session with a new prompt
#   claude.sh capabilities         print capability tokens ("resume cost")
#
# Env in:  FOREMAN_PROMPT_FILE FOREMAN_RESULT_FILE FOREMAN_SESSION_FILE
#          FOREMAN_LOG_FILE FOREMAN_PERMISSION_MODE FOREMAN_BILLING
#          FOREMAN_MAX_TURNS FOREMAN_READONLY FOREMAN_ANTHROPIC_API_KEY
# Out:     SESSION_REF=<id> appended to $FOREMAN_SESSION_FILE from the FIRST
#          stream event (killed agents emit no final event, and resuming dead
#          agents is exactly when the ref matters), COST_USD=<x> when known.
#
# Timeouts are enforced by foreman (backend.py), not here.
set -euo pipefail

fail() {
    echo "claude.sh: $*" >&2
    exit 1
}

cmd="${1:-run}"
resume_ref=""
case "$cmd" in
capabilities)
    echo "resume cost"
    exit 0
    ;;
run) ;;
resume)
    resume_ref="${2:-}"
    [ -n "$resume_ref" ] || fail "resume requires a session ref"
    ;;
*) fail "unknown command: $cmd" ;;
esac

: "${FOREMAN_PROMPT_FILE:?}" "${FOREMAN_RESULT_FILE:?}" "${FOREMAN_SESSION_FILE:?}" "${FOREMAN_LOG_FILE:?}"
command -v claude >/dev/null 2>&1 || fail "claude CLI not found on PATH"

# Billing isolation (spec A11): in api mode the key is exported ONLY into this
# adapter process. The container-wide ANTHROPIC_API_KEY strip (init-env.sh,
# shell-aliases.sh) stays intact for interactive sessions.
if [ "${FOREMAN_BILLING:-subscription}" = "api" ]; then
    [ -n "${FOREMAN_ANTHROPIC_API_KEY:-}" ] || fail "billing=api needs FOREMAN_ANTHROPIC_API_KEY"
    export ANTHROPIC_API_KEY="$FOREMAN_ANTHROPIC_API_KEY"
    unset CLAUDE_CODE_OAUTH_TOKEN
fi

# Read-only analysis mode (preflight): plain-text final output on stdout
# (foreman captures it), no file edits, no shell.
if [ "${FOREMAN_READONLY:-0}" = "1" ]; then
    exec claude -p --permission-mode default \
        --disallowedTools Edit Write NotebookEdit Bash \
        <"$FOREMAN_PROMPT_FILE"
fi

args=(-p --output-format stream-json --verbose)
args+=(--permission-mode "${FOREMAN_PERMISSION_MODE:-acceptEdits}")
# The result contract lives OUTSIDE the worktree; grant only that directory.
args+=(--add-dir "$(dirname "$FOREMAN_RESULT_FILE")")
if [ "${FOREMAN_MAX_TURNS:-0}" != "0" ]; then
    args+=(--max-turns "$FOREMAN_MAX_TURNS")
fi
if [ -n "$resume_ref" ]; then
    args+=(--resume "$resume_ref")
fi

# Stream to the log; capture SESSION_REF from the first event carrying a
# session_id and COST_USD from the result event. pipefail carries claude's
# exit code out of the pipeline (bash 3.2 compatible).
claude "${args[@]}" <"$FOREMAN_PROMPT_FILE" | {
    session_captured=0
    while IFS= read -r line; do
        printf '%s\n' "$line" >>"$FOREMAN_LOG_FILE"
        if [ "$session_captured" -eq 0 ]; then
            sid=$(printf '%s' "$line" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            if [ -n "$sid" ]; then
                echo "SESSION_REF=$sid" >>"$FOREMAN_SESSION_FILE"
                session_captured=1
            fi
        fi
        cost=$(printf '%s' "$line" | sed -n 's/.*"total_cost_usd"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p')
        if [ -n "$cost" ]; then
            echo "COST_USD=$cost" >>"$FOREMAN_SESSION_FILE"
        fi
    done
}
