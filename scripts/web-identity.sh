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

if ! response="$(GH_TOKEN="$token" "${GH_BIN:-gh}" api --hostname github.com --include user 2>/dev/null)"; then
    echo "ERROR: GitHub.com token lookup failed; Claude was not started." >&2
    exit 1
fi
status="$(printf '%s\n' "$response" | awk 'NR == 1 { print $2; exit }')"
if [ "$status" != 200 ]; then
    echo "ERROR: GitHub.com returned HTTP '${status:-<none>}', expected 200; Claude was not started." >&2
    exit 1
fi
if ! scopes="$(printf '%s\n' "$response" | awk '
    /^\r?$/ { exit }
    tolower($0) ~ /^x-oauth-scopes:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        sub(/\r$/, "")
        print
        found = 1
        exit
    }
    END { if (!found) exit 1 }
')"; then
    echo "ERROR: X-OAuth-Scopes is missing; a classic token is required; Claude was not started." >&2
    exit 1
fi
scope_list="${scopes//[[:space:]]/}"
case ",$scope_list," in
*,repo,*) ;;
*)
    echo "ERROR: scopes '$scopes' lack repo; Claude was not started." >&2
    exit 1
    ;;
esac
case ",$scope_list," in
*,workflow,*)
    echo "ERROR: scopes '$scopes' include workflow; Claude was not started." >&2
    exit 1
    ;;
esac
if ! login="$(printf '%s\n' "$response" | awk 'body { print } /^\r?$/ { body = 1 }' |
    jq -er '.login | select(type == "string")' 2>/dev/null)"; then
    echo "ERROR: GitHub.com response has no valid login; Claude was not started." >&2
    exit 1
fi
if [ "$login" != evanharmon1-bot ]; then
    echo "ERROR: token belongs to '$login', expected 'evanharmon1-bot'; Claude was not started." >&2
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
