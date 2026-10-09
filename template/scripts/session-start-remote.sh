#!/usr/bin/env bash
# Prepare web checkouts on startup and resume, including cached resumes.
# Local sessions and devcontainers use their own lifecycle.
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

if ! ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "==> WARNING: SessionStart remote preparation could not locate the checkout." >&2
    exit 0
fi

# Leave time to report a failure before the hook's 120-second timeout.
prepare() {
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=5s 90s task --dir "$ROOT" setup:remote
    else
        echo "==> NOTE: timeout is unavailable; SessionStart preparation runs unbounded." >&2
        task --dir "$ROOT" setup:remote
    fi
}

if prepare; then
    echo "==> SessionStart remote preparation: setup:remote completed."
else
    echo "==> WARNING: SessionStart remote preparation: setup:remote failed; run task setup:remote again." >&2
fi
# Preparation failures must never prevent a session from starting.
exit 0
