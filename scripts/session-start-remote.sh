#!/usr/bin/env bash
# Prepare web checkouts on startup and resume, including cached resumes.
# Local sessions and devcontainers use their own lifecycle.
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

if ! ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "==> WARNING: SessionStart remote preparation: could not locate the checkout; run task setup:remote."
    exit 0
fi

# Leave time to report a failure before the hook's 120-second timeout.
if ! command -v timeout >/dev/null 2>&1; then
    echo "==> WARNING: SessionStart remote preparation: preparation skipped because timeout is unavailable; run task setup:remote."
    exit 0
fi

if output="$(timeout --kill-after=5s 90s task --dir "$ROOT" setup:remote)"; then
    printf '%s\n' "$output" >&2
    summary="setup:remote completed."
    while IFS= read -r line; do
        case "$line" in
        '==> setup:remote completed with warnings:'*) summary="${line#==> }" ;;
        esac
    done <<<"$output"
    echo "==> SessionStart remote preparation: ${summary}"
else
    printf '%s\n' "$output" >&2
    echo "==> WARNING: SessionStart remote preparation: setup:remote failed; run task setup:remote again."
fi
# Preparation failures must never prevent a session from starting.
exit 0
