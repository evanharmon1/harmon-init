#!/usr/bin/env bash
# Shared, read-only GitHub REST helpers for session scripts.
#
# These helpers deliberately avoid gh subcommands backed by GraphQL and gh
# api --paginate. Claude Code's repository proxy permits repos/{owner}/{repo}
# REST reads, but rejects GraphQL, search, and the numeric repository links gh
# follows after the first --paginate page.
#
# Every walk is bounded twice: by the caller's MAX_ITEMS, and by
# GH_REST_MAX_PAGES (default 10), a whole-operation page ceiling that stops the
# loop and returns 4 once exceeded — so no caller can reintroduce an unbounded
# whole-repository walk by passing MAX_ITEMS=0. Raise it deliberately, per
# call, when an operation genuinely needs more than 1000 items.
#
# Host handling: gh_rest_api derives the GitHub host once per call
# (gh_rest_host) and passes --hostname to gh for any host other than
# github.com, so an Enterprise remote or a host-qualified GH_REPO is read from
# the host it names. Export GH_REST_HOST to short-circuit the derivation (an
# empty value means "no --hostname").

# gh_rest_repo [REMOTE] — print OWNER/REPO from GH_REPO or a git remote.
# GH_REPO may carry gh's documented [HOST/]OWNER/REPO form; the host segment is
# dropped here (gh_rest_host recovers it) so endpoints stay repos/OWNER/REPO.
gh_rest_repo() {
    local remote="${1:-}" url path owner name

    if [ -n "${GH_REPO:-}" ]; then
        path="${GH_REPO}"
        case "${path}" in */*/*) path="${path#*/}" ;; esac
        printf '%s\n' "${path}"
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
    # The hyphen is LAST in the class deliberately: `.-/` is the RANGE
    # 0x2E-0x2F, which admits `/` and rejects every hyphenated owner or name —
    # this repository's own included (challenge r3).
    case "${owner}/${name}" in
    */ | /* | *[!A-Za-z0-9_./-]*) return 1 ;;
    esac
    printf '%s/%s\n' "${owner}" "${name}"
}

# gh_rest_host [REMOTE] — print the GitHub host the repository lives on: the
# HOST/ prefix of GH_REPO when present, else GH_HOST (gh's own override, which
# gh_target_host in gh-scopes.sh honours the same way), else the host of the
# remote URL (https://HOST/..., ssh://git@HOST/..., git@HOST:...), else nothing.
# Always exits 0: an empty result means "let gh pick", never an error.
gh_rest_host() {
    local remote="${1:-}" url="" host=""

    case "${GH_REPO:-}" in
    */*/*)
        printf '%s\n' "${GH_REPO%%/*}"
        return 0
        ;;
    esac
    if [ -n "${GH_HOST:-}" ]; then
        printf '%s\n' "${GH_HOST}"
        return 0
    fi
    if [ -z "${remote}" ]; then
        if git remote 2>/dev/null | grep -qx origin; then
            remote=origin
        else
            remote="$(git remote 2>/dev/null | sed -n '1p')" || remote=""
        fi
    fi
    [ -n "${remote}" ] || return 0
    url="$(git remote get-url "${remote}" 2>/dev/null)" || return 0
    case "${url}" in
    *://*)                 # scheme://[user@]host[:port]/path
        host="${url#*://}" # drop the scheme
        host="${host%%/*}" # drop the path
        host="${host##*@}" # drop any userinfo
        host="${host%%:*}" # drop any port
        ;;
    *@*:*) # scp-like: user@host:owner/repo
        host="${url#*@}"
        host="${host%%:*}"
        ;;
    esac
    case "${host}" in
    '' | *[!A-Za-z0-9.-]*) return 0 ;;
    esac
    printf '%s\n' "${host}"
}

# gh_rest_api ENDPOINT [gh-api options...] — one bounded REST read. Callers may
# set GH_REST_TIMEOUT; stock macOS uses gtimeout when coreutils provides it.
# The host is derived once per call (see the header) and passed as --hostname
# whenever it is neither empty nor github.com.
gh_rest_api() {
    local endpoint="$1" timeout_bin="" host
    shift
    host="${GH_REST_HOST-$(gh_rest_host)}"
    case "${host}" in
    '' | github.com) ;;
    *) set -- "$@" --hostname "${host}" ;;
    esac
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

# gh_rest_max_pages — the validated GH_REST_MAX_PAGES ceiling (default 10).
# Prints the value; returns 2 when the export is not a positive integer. Zero
# is rejected on purpose: "no ceiling" is the unbounded walk this guards against.
gh_rest_max_pages() {
    local max_pages="${GH_REST_MAX_PAGES:-10}"
    case "${max_pages}" in '' | *[!0-9]* | 0*) return 2 ;; esac
    printf '%s\n' "${max_pages}"
}

# gh_rest_paginate_array ENDPOINT MAX_ITEMS [gh-api options...] — emit one JSON
# array document per explicit page. Consumers combine them with `jq -s add`.
# MAX_ITEMS is REQUIRED (returns 2 when missing or non-numeric — it is never
# guessed from an option that happens to follow the endpoint); 0 means "every
# page", still under the GH_REST_MAX_PAGES ceiling (returns 4 when a further
# page would exceed it). The endpoint may already contain a query string;
# per_page/page are always supplied explicitly.
gh_rest_paginate_array() {
    [ "$#" -ge 2 ] || return 2
    local endpoint="$1" max_items="$2" page=1 page_size=100 total=0
    local separator payload count max_pages
    shift 2
    case "${max_items}" in '' | *[!0-9]*) return 2 ;; esac
    max_pages="$(gh_rest_max_pages)" || return 2
    case "${endpoint}" in *\?*) separator='&' ;; *) separator='?' ;; esac

    while :; do
        if [ "${max_items}" -gt 0 ] && [ "$((max_items - total))" -lt "${page_size}" ]; then
            page_size=$((max_items - total))
        fi
        [ "${page_size}" -gt 0 ] || return 0
        [ "${page}" -le "${max_pages}" ] || return 4
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
# Bounded by the same GH_REST_MAX_PAGES ceiling (returns 4 when exceeded).
gh_rest_paginate_key() {
    local endpoint="$1" key="$2" page=1 page_size=100 separator payload count max_pages
    shift 2
    max_pages="$(gh_rest_max_pages)" || return 2
    case "${endpoint}" in *\?*) separator='&' ;; *) separator='?' ;; esac
    while :; do
        [ "${page}" -le "${max_pages}" ] || return 4
        payload="$(gh_rest_api "${endpoint}${separator}per_page=${page_size}&page=${page}" "$@")" || return
        jq -e --arg key "${key}" '.[$key] | type == "array"' >/dev/null 2>&1 <<<"${payload}" || return 3
        count="$(jq --arg key "${key}" '.[$key] | length' <<<"${payload}")" || return 3
        jq --arg key "${key}" '.[$key]' <<<"${payload}"
        [ "${count}" -lt "${page_size}" ] && return 0
        page=$((page + 1))
    done
}
