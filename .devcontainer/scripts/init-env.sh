#!/usr/bin/env bash
set -euo pipefail

# Populate the devcontainer env-file with host-environment secrets.
#
# Variables set in the host env always win — any stale entry in the file
# is replaced with the current value. Variables NOT in the host env are
# left untouched, so 1Password-managed values survive when the user
# doesn't also export them in their shell.
#
# On Coder / Codespaces the host env carries secrets from template
# parameters, so they flow into the env-file on every rebuild.

# Keep devcontainer config up to date on rebuilds.
# Only fast-forward main — don't touch feature branches or dirty trees.
if git rev-parse --is-inside-work-tree &>/dev/null &&
    [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] &&
    git diff --quiet 2>/dev/null; then
    git pull --ff-only origin main 2>/dev/null || true
fi

ENV_FILE="${1:-.devcontainer/devcontainer.env}"
shift || true

# Vars this script knows how to MANAGE. Anything in this list but NOT in the
# per-profile allow-list below is considered forbidden and is unconditionally
# stripped from the env-file on every run. The env-file is actively-managed
# runtime state, NOT user data — TS_AUTHKEY is evicted from the bot profile the
# same way — so this is secret hygiene, not a mutation of user-owned files (the
# values themselves live in 1Password; the env-file is only a projection).
#
# The managed set has three tiers:
#   BASE_MANAGED_VARS    — always-on secrets every profile may carry. These form
#                          the implicit default allow-list (the no-arg fallback).
#   ANTHROPIC_API_KEY    — managed ONLY for eviction; never allow-listed. It
#                          silently overrides CLAUDE_CODE_OAUTH_TOKEN, so it must
#                          never reach the container.
#   OPT_IN_PROVIDER_KEYS — alt-model keys (use_alternative_claude_providers).
#                          Managed for eviction but NEVER in the implicit default:
#                          they reach the env-file only when initializeCommand
#                          explicitly passes them (the rendered allow-lists, when
#                          opted in). That stops a no-arg invocation from
#                          injecting paid opt-in credentials into a default-off
#                          repo, and a revoked opt-in from leaving live paid keys
#                          readable in the bypassPermissions bot's env. The keys
#                          stay safe in 1Password; only the injection stops.
BASE_MANAGED_VARS=(TS_AUTHKEY GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)
OPT_IN_PROVIDER_KEYS=(KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY)
ALL_MANAGED_VARS=("${BASE_MANAGED_VARS[@]}" ANTHROPIC_API_KEY "${OPT_IN_PROVIDER_KEYS[@]}")

# Vars this profile is allowed to populate. Caller passes the allow-list
# as additional args after the env-file path. With no extra args we default to
# the always-on base vars only — ANTHROPIC_API_KEY (never allowed) and the opt-in
# provider keys (only when the caller passes them) are excluded, so the no-arg
# fallback evicts them rather than injecting them.
if [ "$#" -gt 0 ]; then
    ALLOWED_VARS=("$@")
else
    ALLOWED_VARS=("${BASE_MANAGED_VARS[@]}")
fi

contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Restrict ALLOWED_VARS to the intersection with ALL_MANAGED_VARS, and strip
# ANTHROPIC_API_KEY unconditionally. A caller cannot smuggle an unknown var
# into the env-file by passing it as a positional arg.
FILTERED_ALLOWED_VARS=()
for var in "${ALLOWED_VARS[@]}"; do
    [ "$var" = "ANTHROPIC_API_KEY" ] && continue
    if contains "$var" "${ALL_MANAGED_VARS[@]}"; then
        FILTERED_ALLOWED_VARS+=("$var")
    fi
done
ALLOWED_VARS=("${FILTERED_ALLOWED_VARS[@]}")

touch "$ENV_FILE"

# Remove every line setting $1 from $2, portably. GNU `sed -i` is not
# available on macOS (BSD sed needs a suffix arg after -i, so `sed -i expr
# file` silently does nothing useful) — and initializeCommand runs this
# script on the HOST, which is often a Mac.
strip_var() {
    local tmp
    tmp="$(mktemp)"
    grep -v "^${1}=" "$2" >"$tmp" || true
    mv "$tmp" "$2"
}

# Strip any forbidden var (managed by the script but not in this
# profile's allow-list). This guarantees, for example, that the bot
# profile evicts TS_AUTHKEY even if a stale value was written to the
# env-file by an earlier rebuild.
for var in "${ALL_MANAGED_VARS[@]}"; do
    if ! contains "$var" "${ALLOWED_VARS[@]}"; then
        strip_var "$var" "$ENV_FILE"
    fi
done

# For allowed vars, replace any stale entry with the current host value.
# Vars not present in the host env are left untouched, so values
# populated out-of-band (e.g. from 1Password) survive rebuilds.
for var in "${ALLOWED_VARS[@]}"; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        strip_var "$var" "$ENV_FILE"
        echo "${var}=${val}" >>"$ENV_FILE"
    fi
done
