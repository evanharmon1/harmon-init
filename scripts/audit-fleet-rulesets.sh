#!/usr/bin/env bash
# audit-fleet-rulesets.sh — read-only, fleet-wide view of what each repository
# requires before a merge, against what its own checked-in ruleset expects.
#
# usage: audit-fleet-rulesets.sh [--json] [OWNER | OWNER/REPO]...
#
# With no operand it scans FLEET_AUDIT_OWNERS (default: the platform owners).
# An OWNER expands to its active repositories (non-fork, non-archived); an
# OWNER/REPO is audited as named. Per repository it reports:
#
#   managed   .copier-answers.yml on the default branch (yes/no/unknown)
#   ruleset   exactly one live Repository ruleset with the checked-in name
#             (present/absent/unknown; two or more is unknown)
#   expected  required contexts in the repository's OWN checked-in ruleset
#   required  required contexts in the live ruleset
#   missing / extra   expected-not-required / required-not-expected
#   policy    audit-ruleset.sh's full-policy verdict on the same two documents
#   status    gated | drift | ungated | unmanaged | unknown
#
# Every GitHub call is a GET through scripts/lib/gh-rest.sh; nothing is written
# and no credential is printed. A read that fails is `unknown`, never a pass.
#
# Exit: 0 every repository gated or unmanaged; 1 any drift/ungated; 2 any
# unknown (or a usage error / no repository found).
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd -P)"
# shellcheck source=scripts/lib/gh-rest.sh
. "$root/scripts/lib/gh-rest.sh"

readonly ruleset_path=".github/Branch Protection Ruleset - Protect Main.json"
readonly default_ruleset_name="Protect Main"
readonly default_owners="evanharmon1 harmonops ponderousdev sommerlawn"
# The fleet lives on the default GitHub host whatever this checkout's origin is.
export GH_REST_HOST="${GH_REST_HOST-}"

format=table
targets=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --json) format=json ;;
    -h | --help)
        sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    -*)
        echo "audit-fleet-rulesets: unknown option: $1" >&2
        exit 2
        ;;
    *) targets+=("$1") ;;
    esac
    shift
done
if [ "${#targets[@]}" -eq 0 ]; then
    for owner in ${FLEET_AUDIT_OWNERS:-$default_owners}; do targets+=("$owner"); done
fi
command -v jq >/dev/null 2>&1 || {
    echo "audit-fleet-rulesets: jq is required" >&2
    exit 2
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/harmon-init-fleet-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
records="$tmp_dir/records.jsonl"
: >"$records"

# get ENDPOINT OUT [gh-api options...] — one GET into OUT. Returns 0 on
# success, 4 on HTTP 404 (genuinely absent), 1 on any other failure; the
# reason for a failure is left in $tmp_dir/err.
get() {
    local endpoint="$1" out="$2"
    shift 2
    if gh_rest_api "$endpoint" "$@" >"$out" 2>"$tmp_dir/err"; then
        return 0
    fi
    grep -q 'HTTP 404' "$tmp_dir/err" && return 4
    return 1
}

# fail_reason — one line naming why the last get failed, credential-free.
fail_reason() {
    local line
    line="$(grep -o 'HTTP [0-9][0-9][0-9]' "$tmp_dir/err" | head -n 1 || true)"
    printf '%s\n' "${line:-request failed}"
}

# list_repos OWNER — print "full_name<TAB>default_branch" for each active
# repository the owner owns. Returns 1 when the owner cannot be listed.
me=""
list_repos() {
    local owner="$1" kind endpoint
    get "users/$owner" "$tmp_dir/owner.json" || return 1
    kind="$(jq -r '.type // empty' "$tmp_dir/owner.json")"
    case "$kind" in
    Organization) endpoint="orgs/$owner/repos?type=all" ;;
    User)
        if [ -z "$me" ] && get user "$tmp_dir/me.json"; then
            me="$(jq -r '.login // empty' "$tmp_dir/me.json")"
        fi
        if [ -n "$me" ] && [ "$me" = "$owner" ]; then
            endpoint="user/repos?affiliation=owner&visibility=all"
        else
            endpoint="users/$owner/repos?type=owner"
        fi
        ;;
    *) return 1 ;;
    esac
    gh_rest_paginate_array "$endpoint" 0 >"$tmp_dir/pages.json" 2>"$tmp_dir/err" || return 1
    jq -s -r --arg owner "$owner" 'add // [] | .[]
        | select(.fork == false and .archived == false and .owner.login == $owner)
        | "\(.full_name)\t\(.default_branch)"' "$tmp_dir/pages.json" | sort
}

# contexts FILE — sorted unique required contexts of one ruleset document.
contexts() {
    jq -c '[.rules[]? | select(.type == "required_status_checks")
        | .parameters.required_status_checks[]?.context] | unique' "$1"
}

record() { jq -nc "$@" >>"$records"; }

audit_repo() {
    local repo="$1" branch="$2" managed expected=null expected_state required=null ruleset
    local enforcement="" policy="n/a" reason="" name="$default_ruleset_name" rc count id
    local others="[]"
    local encoded="${ruleset_path// /%20}"

    rc=0
    get "repos/$repo/contents/.copier-answers.yml?ref=$branch" "$tmp_dir/answers" || rc=$?
    case "$rc" in
    0) managed=yes ;;
    4) managed=no ;;
    *) managed=unknown reason="copier answers: $(fail_reason)" ;;
    esac

    rc=0
    get "repos/$repo/contents/$encoded?ref=$branch" "$tmp_dir/file.json" \
        -H 'Accept: application/vnd.github.raw+json' || rc=$?
    case "$rc" in
    0)
        if expected="$(contexts "$tmp_dir/file.json" 2>/dev/null)" &&
            name="$(jq -er '.name' "$tmp_dir/file.json" 2>/dev/null)"; then
            expected_state=present
        else
            expected=null expected_state=unknown name="$default_ruleset_name"
            reason="${reason:+$reason; }checked-in ruleset is not valid JSON"
        fi
        ;;
    4) expected_state=absent ;;
    *) expected_state=unknown reason="${reason:+$reason; }checked-in ruleset: $(fail_reason)" ;;
    esac

    rc=0
    gh_rest_paginate_array "repos/$repo/rulesets?includes_parents=false" 0 \
        >"$tmp_dir/list-pages.json" 2>"$tmp_dir/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ruleset=unknown reason="${reason:+$reason; }rulesets: $(fail_reason)"
    else
        jq -s 'add // []' "$tmp_dir/list-pages.json" >"$tmp_dir/list.json"
        others="$(jq -c --arg name "$name" '[.[] | select(.name != $name) | .name] | unique' "$tmp_dir/list.json")"
        count="$(jq --arg name "$name" '[.[] | select(.name == $name and .source_type == "Repository")] | length' "$tmp_dir/list.json")"
        case "$count" in
        0) ruleset=absent ;;
        1)
            id="$(jq -r --arg name "$name" '.[] | select(.name == $name and .source_type == "Repository") | .id' "$tmp_dir/list.json")"
            if get "repos/$repo/rulesets/$id" "$tmp_dir/live.json" && required="$(contexts "$tmp_dir/live.json" 2>/dev/null)"; then
                ruleset=present
                enforcement="$(jq -r '.enforcement // empty' "$tmp_dir/live.json")"
            else
                ruleset=unknown required=null reason="${reason:+$reason; }ruleset $id: $(fail_reason)"
            fi
            ;;
        *) ruleset=unknown reason="${reason:+$reason; }$count rulesets named $name" ;;
        esac
    fi

    # Full-policy verdict from audit-ruleset.sh's own lookup and normalization,
    # fed the documents already fetched (no second set of API calls).
    if [ "$expected_state" = present ] && [ "$ruleset" = present ]; then
        # A verdict counts only when the exit status and its own verdict line
        # agree: under `set -e` any internal failure also exits 1, which must
        # not read as drift.
        rc=0
        RULESET_AUDIT_FILE="$tmp_dir/file.json" RULESET_AUDIT_REPO="$repo" \
            RULESET_AUDIT_LIVE_LIST="$tmp_dir/list.json" \
            RULESET_AUDIT_LIVE_DETAIL="$tmp_dir/live.json" \
            "$root/scripts/audit-ruleset.sh" >"$tmp_dir/policy" 2>/dev/null || rc=$?
        policy=unknown
        if [ "$rc" -eq 0 ] && grep -q '^RULESET AUDIT CLEAN: ' "$tmp_dir/policy"; then
            policy=clean
        elif [ "$rc" -eq 1 ] && grep -q '^RULESET AUDIT DRIFT: ' "$tmp_dir/policy"; then
            policy=drift
        fi
    fi

    record --arg repo "$repo" --arg branch "$branch" --arg managed "$managed" \
        --arg ruleset "$ruleset" --arg name "$name" --arg enforcement "$enforcement" --arg policy "$policy" \
        --arg reason "$reason" --arg expected_state "$expected_state" \
        --argjson expected "$expected" --argjson required "$required" --argjson others "$others" '
        ($expected // []) as $e | ($required // []) as $r
        | {repo: $repo, default_branch: $branch, managed: $managed, ruleset: $ruleset,
           enforcement: (if $enforcement == "" then null else $enforcement end),
           expected: $expected, required: $required, other_rulesets: $others,
           missing: (if $expected == null or $required == null then null else $e - $r end),
           extra: (if $expected == null or $required == null then null else $r - $e end),
           policy: $policy}
        | .status = (
            if $managed == "unknown" or $ruleset == "unknown" or $expected_state == "unknown" then "unknown"
            elif $expected_state == "absent" and $managed == "yes" then "unknown"
            elif $expected_state == "absent" then "unmanaged"
            elif $ruleset == "absent" or ($r | length) == 0 or .enforcement != "active" then "ungated"
            elif (.missing | length) > 0 or (.extra | length) > 0 then "drift"
            else "gated" end)
        | .reason = (if $reason != "" then $reason
            elif .status == "unknown" then "managed repository has no checked-in ruleset"
            elif .status == "ungated" and $ruleset == "absent" then "no live ruleset named \($name)"
                + (if ($others | length) > 0 then " (other rulesets: \($others | join(", ")))" else "" end)
            elif .status == "ungated" and ($r | length) == 0 then "live ruleset requires no status check"
            elif .status == "ungated" then "live ruleset enforcement is \(.enforcement // "unset")"
            else null end)'
}

listing_failed=0
for target in "${targets[@]}"; do
    case "$target" in
    */*/* | /* | */) echo "audit-fleet-rulesets: not OWNER or OWNER/REPO: $target" >&2 && exit 2 ;;
    */*)
        if get "repos/$target" "$tmp_dir/repo.json"; then
            branch="$(jq -r '.default_branch' "$tmp_dir/repo.json")"
            audit_repo "$(jq -r '.full_name' "$tmp_dir/repo.json")" "$branch"
        else
            record --arg repo "$target" --arg reason "repository: $(fail_reason)" \
                '{repo: $repo, default_branch: null, managed: "unknown", ruleset: "unknown", enforcement: null,
                  expected: null, required: null, other_rulesets: null, missing: null, extra: null, policy: "n/a",
                  status: "unknown", reason: $reason}'
        fi
        ;;
    *)
        if list_repos "$target" >"$tmp_dir/repos.tsv"; then
            while IFS="$(printf '\t')" read -r repo branch; do
                [ -n "$repo" ] && audit_repo "$repo" "$branch"
            done <"$tmp_dir/repos.tsv"
        else
            listing_failed=1
            record --arg repo "$target/*" --arg reason "owner listing: $(fail_reason)" \
                '{repo: $repo, default_branch: null, managed: "unknown", ruleset: "unknown", enforcement: null,
                  expected: null, required: null, other_rulesets: null, missing: null, extra: null, policy: "n/a",
                  status: "unknown", reason: $reason}'
        fi
        ;;
    esac
done

[ -s "$records" ] || {
    echo "audit-fleet-rulesets: no repository found" >&2
    exit 2
}

report="$(jq -s '{repositories: ., summary: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries)}' "$records")"

if [ "$format" = json ]; then
    printf '%s\n' "$report"
else
    printf '%-40s %-8s %-8s %-10s %-7s %-30s %-24s %s\n' \
        REPO MANAGED RULESET STATUS POLICY REQUIRED MISSING EXTRA
    jq -r '.repositories[] | [.repo, .managed, .ruleset, .status, .policy,
        (if .required == null then "-" elif (.required | length) == 0 then "(none)" else .required | join(",") end),
        (if .missing == null then "-" elif (.missing | length) == 0 then "-" else .missing | join(",") end),
        (if .extra == null then "-" elif (.extra | length) == 0 then "-" else .extra | join(",") end),
        (.reason // "")] | @tsv' <<<"$report" |
        while IFS="$(printf '\t')" read -r repo managed ruleset status policy required missing extra reason; do
            printf '%-40s %-8s %-8s %-10s %-7s %-30s %-24s %s\n' \
                "$repo" "$managed" "$ruleset" "$status" "$policy" "$required" "$missing" "$extra"
            [ -z "$reason" ] || printf '  %s\n' "$reason"
        done
    jq -r '.summary | to_entries | map("\(.key)=\(.value)") | "summary: " + join(" ")' <<<"$report"
fi

if [ "$listing_failed" -ne 0 ] || jq -e '.summary.unknown // 0 > 0' >/dev/null <<<"$report"; then
    exit 2
fi
if jq -e '(.summary.drift // 0) + (.summary.ungated // 0) > 0' >/dev/null <<<"$report"; then
    exit 1
fi
exit 0
