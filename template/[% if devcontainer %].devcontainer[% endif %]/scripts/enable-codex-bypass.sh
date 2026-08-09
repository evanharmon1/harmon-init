#!/usr/bin/env bash
set -euo pipefail

# BOT PROFILE ONLY. Docker is the isolation boundary, so remove Codex's nested
# sandbox and interactive approval prompts. The human profile deliberately
# keeps the managed workspace-write/on-request baseline.
managed="${CODEX_MANAGED_CONFIG:-/etc/codex/managed_config.toml}"

command -v yq >/dev/null 2>&1 || {
    echo "==> yq not found; cannot enable Codex bot mode" >&2
    exit 0
}
[ -f "$managed" ] || {
    echo "==> ${managed} not found; skipping Codex bot mode" >&2
    exit 0
}

if [ "$(yq '.sandbox_mode' "$managed")" = "danger-full-access" ] &&
    [ "$(yq '.approval_policy' "$managed")" = "never" ]; then
    exit 0
fi

tmp="$(mktemp)"
if yq -o toml \
    '.sandbox_mode = "danger-full-access" | .approval_policy = "never"' \
    "$managed" >"$tmp"; then
    if [ -w "$managed" ]; then
        install -m 0644 "$tmp" "$managed"
    else
        sudo install -m 0644 "$tmp" "$managed"
    fi
    echo "==> Codex: danger-full-access/never enabled (bot profile)"
else
    echo "==> WARNING: failed to enable Codex bot mode; leaving managed config unchanged" >&2
fi
rm -f "$tmp"
