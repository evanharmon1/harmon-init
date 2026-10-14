#!/usr/bin/env bash
# Start /web-setup with the bot token, away from any checkout's settings/hooks.
{ set +xa; } 2>/dev/null
set -euo pipefail

if [ -z "${WEB_SETUP_TOKEN_REF:-}" ]; then
    echo "Usage: WEB_SETUP_TOKEN_REF='op://<vault>/<item>/<field>' task setup:web-identity" >&2
    exit 1
fi

unset token
if ! token="$("${OP_BIN:-op}" read "$WEB_SETUP_TOKEN_REF" 2>/dev/null)"; then
    echo "ERROR: could not read WEB_SETUP_TOKEN_REF; Claude was not started." >&2
    exit 1
fi
if [ -z "$token" ]; then
    echo "ERROR: WEB_SETUP_TOKEN_REF returned an empty token; Claude was not started." >&2
    exit 1
fi

if ! login="$(GH_TOKEN="$token" "${GH_BIN:-gh}" api user --jq .login 2>/dev/null)"; then
    echo "ERROR: token login lookup failed (received '${login:-<none>}'); Claude was not started." >&2
    exit 1
fi
expected_login="${WEB_SETUP_EXPECTED_LOGIN:-evanharmon1-bot}"
if [ "$login" != "$expected_login" ]; then
    echo "ERROR: token belongs to '$login', expected '$expected_login'; Claude was not started." >&2
    exit 1
fi

setup_dir="$(mkdir -p "$HOME/.cache" && mktemp -d "$HOME/.cache/web-identity.XXXXXX")"
[ -n "$setup_dir" ] || exit 1
trap 'cd / && rm -rf -- "$setup_dir"' EXIT
cd "$setup_dir"

cat <<'GUIDANCE'
Run /web-setup, then continue past the missing-workflow-scope warning.
Expect: Connected as evanharmon1-bot
If it reports anything else, disconnect GitHub at https://claude.ai/customize/connectors
and run task setup:web-identity again before starting any web session.
GUIDANCE
GH_TOKEN="$token" "${CLAUDE_BIN:-claude}"
