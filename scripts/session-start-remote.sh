#!/usr/bin/env bash
# Prepare web checkouts on every SessionStart, including cached resumes.
# Local sessions and devcontainers use their own lifecycle.
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

if ! ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "==> WARNING: SessionStart remote preparation could not locate the checkout." >&2
    exit 0
fi

if task --dir "$ROOT" setup:remote; then
    echo "==> SessionStart remote preparation: setup:remote completed."
else
    echo "==> WARNING: SessionStart remote preparation: setup:remote failed; run task setup:remote again." >&2
fi
# Preparation failures must never prevent a session from starting.
exit 0
