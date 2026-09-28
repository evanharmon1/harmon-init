#!/usr/bin/env bash
# Shared, read-only GitHub REST helpers for session scripts.
#
# These helpers deliberately avoid gh subcommands backed by GraphQL and gh
# api --paginate. Claude Code's repository proxy permits repos/{owner}/{repo}
# REST reads, but rejects GraphQL, search, and the numeric repository links gh
# follows after the first --paginate page.

# gh_rest_repo [REMOTE] — print owner/repository from GH_REPO or a git remote.
gh_rest_repo() {
    local remote="${1:-}" url path owner name

    if [ -n "${GH_REPO:-}" ]; then
        printf '%s\n' "${GH_REPO}"
        return 0
    fi
    if [ -z "${remote}" ]; then
        if git remote 2>/dev/null | grep -qx origin; then
            remote=origin
        else
            remote="$(git remote 2>/dev/null | sed -n '1p')"
        fi
    fi
    [ -n "${remote}" ] || return 1
    url="$(git remote get-url "${remote}" 2>/dev/null)" || return 1
    url="${url%.git}"
    case "${url}" in
    *://*)
        path="${url#*://}"
        path="${path#*@}"
        path="${path#*/}"
        ;;
    *:*) path="${url#*:}" ;;
    *) return 1 ;;
    esac
    path="${path#/}"
    name="${path##*/}"
    path="${path%/*}"
    owner="${path##*/}"
    case "${owner}/${name}" in
    */ | /* | *[!A-Za-z0-9_.-/]*) return 1 ;;
    esac
    printf '%s/%s\n' "${owner}" "${name}"
}

# gh_rest_urlencode VALUE — encode one query value without external language
# runtimes beyond jq, which every caller already requires for JSON handling.
gh_rest_urlencode() {
    jq -rn --arg value "$1" '$value | @uri'
}

# gh_rest_api ENDPOINT [gh-api options...] — one bounded REST read. Callers may
# set GH_REST_TIMEOUT; stock macOS uses gtimeout when coreutils provides it.
gh_rest_api() {
    local endpoint="$1" timeout_bin=""
    shift
    if [ -z "${GH_REST_TIMEOUT:-}" ]; then
        gh api "${endpoint}" "$@"
        return
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout_bin=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_bin=gtimeout
    fi
    if [ -n "${timeout_bin}" ]; then
        "${timeout_bin}" -k 1 "${GH_REST_TIMEOUT}" gh api "${endpoint}" "$@" </dev/null
    else
        gh api "${endpoint}" "$@" </dev/null
    fi
}

# gh_rest_paginate_array ENDPOINT [MAX_ITEMS] [gh-api options...] — emit one
# JSON array document per explicit page. Consumers combine them with `jq -s
# add`. MAX_ITEMS=0 (the default) means every page. The endpoint may already
# contain a query string; per_page/page are always supplied explicitly.
gh_rest_paginate_array() {
    local endpoint="$1" max_items="${2:-0}" page=1 page_size=100 total=0
    local separator payload count
    shift 2 || true
    case "${max_items}" in '' | *[!0-9]*) return 2 ;; esac
    case "${endpoint}" in *\?*) separator='&' ;; *) separator='?' ;; esac

    while :; do
        if [ "${max_items}" -gt 0 ] && [ "$((max_items - total))" -lt "${page_size}" ]; then
            page_size=$((max_items - total))
        fi
        [ "${page_size}" -gt 0 ] || return 0
        payload="$(gh_rest_api "${endpoint}${separator}per_page=${page_size}&page=${page}" "$@")" || return
        jq -e 'type == "array"' >/dev/null 2>&1 <<<"${payload}" || return 3
        count="$(jq 'length' <<<"${payload}")" || return 3
        printf '%s\n' "${payload}"
        total=$((total + count))
        [ "${count}" -lt "${page_size}" ] && return 0
        [ "${max_items}" -gt 0 ] && [ "${total}" -ge "${max_items}" ] && return 0
        page=$((page + 1))
    done
}

# gh_rest_paginate_key ENDPOINT KEY [gh-api options...] — for paginated REST
# previews that wrap their array in an object (for example `issue_fields`).
gh_rest_paginate_key() {
    local endpoint="$1" key="$2" page=1 page_size=100 separator payload count
    shift 2
    case "${endpoint}" in *\?*) separator='&' ;; *) separator='?' ;; esac
    while :; do
        payload="$(gh_rest_api "${endpoint}${separator}per_page=${page_size}&page=${page}" "$@")" || return
        jq -e --arg key "${key}" '.[$key] | type == "array"' >/dev/null 2>&1 <<<"${payload}" || return 3
        count="$(jq --arg key "${key}" '.[$key] | length' <<<"${payload}")" || return 3
        jq --arg key "${key}" '.[$key]' <<<"${payload}"
        [ "${count}" -lt "${page_size}" ] && return 0
        page=$((page + 1))
    done
}
