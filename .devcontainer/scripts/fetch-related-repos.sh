#!/usr/bin/env bash
set -euo pipefail

# Freshen already-cloned related repos in the target directory on devcontainer START
# (post-start-common.sh), so siblings track their remotes without a manual
# fetch. Reads the same config as bootstrap-related-repos.sh:
# .devcontainer/related-repos.txt.
#
# STRICTLY NON-DESTRUCTIVE: runs `git fetch` only (updates remote-tracking refs
# and prunes deleted ones). It NEVER pulls, merges, checks out, or resets — so
# uncommitted changes, local commits, and the checked-out branch are left
# exactly as they are. Repos not yet cloned are skipped (bootstrap-related-repos.sh
# clones missing ones at create, start, and scope grant). Failures log a warning
# and continue; this never blocks start.

# Prevent VS Code's JS debug bootloader from breaking child Node processes.
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../related-repos.txt"
# setup:remote passes the checkout's parent; existing devcontainer callers keep
# /workspaces as their default.
WORKSPACES_DIR="${1:-/workspaces}"

[ -f "$CONFIG_FILE" ] || exit 0
[ -d "$WORKSPACES_DIR" ] || exit 0

fetched=0
skipped=0
failed=0
unrelated=0

# Compare repository identities, not transport spellings. Local paths/file URLs
# are also supported (the bootstrap's base override uses them in offline tests).
repo_identity() {
    local url="${1%/}" authority path
    url="${url%.git}"
    case "$url" in
    file://*) printf '%s\n' "${url#file://}" ;;
    *://*)
        authority="${url#*://}"
        path="${authority#*/}"
        authority="${authority%%/*}"
        authority="${authority##*@}"
        case "$url" in
        ssh://*) authority="${authority%:22}" ;;
        https://*) authority="${authority%:443}" ;;
        esac
        printf '%s/%s\n' "$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')" "$path"
        ;;
    /* | ./* | ../*) printf '%s\n' "$url" ;;
    *:*) repo_identity "ssh://${url%%:*}/${url#*:}" ;;
    *) printf '%s\n' "$url" ;;
    esac
}

# Shorthand owner/repo entries use the same host/base as bootstrap.
if [ -n "${RELATED_REPOS_GIT_BASE_URL:-}" ]; then
    GIT_BASE_URL="${RELATED_REPOS_GIT_BASE_URL%/}/"
elif [ -n "${GH_HOST:-}" ]; then
    GIT_BASE_URL="https://${GH_HOST}/"
else
    checkout_origin="$(git -C "${SCRIPT_DIR}/.." config --get remote.origin.url 2>/dev/null || true)"
    checkout_identity="$(repo_identity "$checkout_origin")"
    case "$checkout_origin" in
    http://* | https://* | ssh://* | git@*) GIT_BASE_URL="https://${checkout_identity%%/*}/" ;;
    *) GIT_BASE_URL="https://github.com/" ;;
    esac
fi

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip inline comments, then trim leading/trailing whitespace.
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue

    # Derive the target basename, mirroring bootstrap-related-repos.sh: drop an
    # optional plain @branch suffix (but keep ssh git@host:... intact), then
    # strip the path, any ssh "host:" prefix, and a trailing .git.
    target_spec="$line"
    if [[ "$line" == *"@"* ]]; then
        suffix="${line##*@}"
        if [[ "$suffix" != *.* && "$suffix" != *:* && "$suffix" != */* ]]; then
            target_spec="${line%@*}"
        fi
    fi
    basename_raw="${target_spec##*/}"
    basename_raw="${basename_raw##*:}"
    basename="${basename_raw%.git}"
    [ -z "$basename" ] && continue

    dir="${WORKSPACES_DIR}/${basename}"

    # Only fetch repos that are already cloned; bootstrap handles the rest.
    if [ ! -d "$dir" ] || ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        skipped=$((skipped + 1))
        continue
    fi

    expected_url="$target_spec"
    case "$target_spec" in
    *://* | *:* | /* | ./* | ../*) ;;
    *) expected_url="${GIT_BASE_URL}${target_spec}" ;;
    esac
    origin_url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
    if [ -z "$origin_url" ] || [ "$(repo_identity "$origin_url")" != "$(repo_identity "$expected_url")" ]; then
        echo "==> WARNING: skipping ${basename}: origin does not match the related-repos entry." >&2
        unrelated=$((unrelated + 1))
        continue
    fi

    # Empty refmap prevents configured fetch mappings from adding destinations.
    # Disable tag pruning/following and submodule recursion as well: this fetch
    # owns only origin's remote-tracking branch refs, even in a mirror clone.
    if git -C "$dir" fetch --prune --no-prune-tags --no-tags --recurse-submodules=no \
        --refmap= --quiet origin '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null; then
        fetched=$((fetched + 1))
    else
        echo "==> WARNING: fetch failed for ${basename}; continuing." >&2
        failed=$((failed + 1))
    fi
done <"$CONFIG_FILE"

total=$((fetched + skipped + failed + unrelated))
if [ "$total" -gt 0 ]; then
    echo "==> Related-repo fetch: ${fetched} fetched, ${skipped} not-yet-cloned, ${failed} failed, ${unrelated} identity mismatches"
fi

# Always exit 0 — never block container start.
exit 0
