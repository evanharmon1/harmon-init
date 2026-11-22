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
#   status    gated (contexts equal AND policy clean) | drift | ungated |
#             unmanaged | unknown; other_rulesets and listing are informational
#   listing   which repositories the owner scan could see: token-visible (an
#             Organization, or the token's own account: what the token can
#             read, never proven complete), public-only (another personal
#             account), unknown, or named (an OWNER/REPO operand)
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
owners="$tmp_dir/owners.jsonl"
: >"$records"
: >"$owners"

# ── The one read path ─────────────────────────────────────────────────────────
# Invariant: every GitHub read goes through fetch/fetch_pages and every value
# taken from a response goes through decode. Their only outcomes are success,
# HTTP 404 (4: absence, which callers accept only once readability is proven)
# and failure (1: unknown). `why` holds a credential-free reason.
why=""

# fetch ENDPOINT OUT CHECK [gh-api options...] — one GET into OUT, then CHECK
# (a jq predicate; empty for none) must hold on what came back.
fetch() {
    local endpoint="$1" out="$2" check="$3"
    shift 3
    if ! gh_rest_api "$endpoint" "$@" >"$out" 2>"$tmp_dir/err"; then
        if grep -q 'HTTP 404' "$tmp_dir/err"; then
            why="HTTP 404"
            return 4
        fi
        why="$(grep -o 'HTTP [0-9][0-9][0-9]' "$tmp_dir/err" | head -n 1 || true)"
        why="${why:-request failed}"
        return 1
    fi
    if [ -n "$check" ] && ! jq -e "$check" "$out" >/dev/null 2>&1; then
        why="malformed response"
        return 1
    fi
    return 0
}

# fetch_pages ENDPOINT OUT CHECK — every page of a list endpoint, combined into
# one JSON array in OUT; CHECK must hold on that array.
fetch_pages() {
    local endpoint="$1" out="$2" check="$3"
    if ! gh_rest_paginate_array "$endpoint" 0 >"$tmp_dir/pages" 2>"$tmp_dir/err"; then
        why="$(grep -o 'HTTP [0-9][0-9][0-9]' "$tmp_dir/err" | head -n 1 || true)"
        why="${why:-request failed}"
        return 1
    fi
    if ! jq -s 'add // []' "$tmp_dir/pages" >"$out" 2>/dev/null ||
        ! jq -e "type == \"array\" and ($check)" "$out" >/dev/null 2>&1; then
        why="malformed response"
        return 1
    fi
    return 0
}

# decode FILE FILTER [jq options...] — print FILTER's raw output on FILE.
decode() {
    local file="$1" filter="$2"
    shift 2
    if jq -r "$@" "$filter" "$file" 2>/dev/null; then
        return 0
    fi
    why="malformed response"
    return 1
}

uri() { jq -rn --arg v "$1" '$v | @uri'; }
note() { reason="${reason:+$reason; }$1"; }
record() { jq -nc "$@" >>"$records"; }
unknown_record() { # unknown_record REPO REASON [LISTING]
    record --arg repo "$1" --arg reason "$2" --arg listing "${3:-named}" \
        '{repo: $repo, listing: $listing, default_branch: null, managed: "unknown",
          ruleset: "unknown", enforcement: null, expected: null, required: null,
          other_rulesets: null, missing: null, extra: null, policy: "n/a",
          status: "unknown", reason: $reason}'
}

# The decode checks. Each validates every field the filters below consume, so
# a malformed entry is unknown rather than filtered out or read as absent.
readonly owner_check='(.login | type) == "string" and (.type | type) == "string"'
readonly repos_check='all(.[]; (.full_name | type) == "string" and (.default_branch | type) == "string"
    and (.owner.login | type) == "string" and (.fork | type) == "boolean" and (.archived | type) == "boolean")'
readonly rulesets_check='all(.[]; (.name | type) == "string" and (.source_type | type) == "string")'
readonly ruleset_check='type == "object" and (.name | type) == "string" and (.rules | type) == "array"
    and all(.rules[]; (.type | type) == "string")
    and all(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks
        | if type == "array" then .[] else null end; (.context | type) == "string")'
# contexts — sorted unique required contexts of one ruleset document.
readonly contexts='[.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[].context] | unique'

# list_repos OWNER — record the owner's listing in $owners and print
# "full_name<TAB>default_branch<TAB>listing" for each active repository.
# Returns 1 (listing unknown) when anything about the listing is unproven.
me="" me_state=unread
list_repos() {
    # No read proves a listing complete (private repositories the token cannot
    # see are absent without trace), so the scope claimed is what it saw.
    local owner="$1" login kind endpoint listing=token-visible
    fetch "users/$owner" "$tmp_dir/owner.json" "$owner_check" || return 1
    login="$(decode "$tmp_dir/owner.json" '.login // empty')" && [ -n "$login" ] || return 1
    kind="$(decode "$tmp_dir/owner.json" '.type // empty')" || return 1
    case "$kind" in
    Organization) endpoint="orgs/$login/repos?type=all" ;;
    User)
        if [ "$me_state" = unread ]; then
            me_state=unknown
            if fetch user "$tmp_dir/me.json" '(.login | type) == "string"' &&
                me="$(decode "$tmp_dir/me.json" '.login // empty')" && [ -n "$me" ]; then
                me_state=known
            fi
        fi
        if [ "$me_state" != known ]; then
            why="identity read failed"
            return 1
        fi
        if [ "$me" = "$login" ]; then
            endpoint="user/repos?affiliation=owner&visibility=all"
        else
            # A personal account other than the token's lists public
            # repositories only; the listing says so.
            endpoint="users/$login/repos?type=owner"
            listing=public-only
        fi
        ;;
    *)
        why="unknown owner type"
        return 1
        ;;
    esac
    fetch_pages "$endpoint" "$tmp_dir/repos.json" "$repos_check" || return 1
    jq -nc --arg owner "$login" --arg kind "$kind" --arg listing "$listing" \
        '{owner: $owner, kind: $kind, listing: $listing}' >>"$owners"
    decode "$tmp_dir/repos.json" '.[]
        | select(.fork == false and .archived == false and .owner.login == $owner)
        | "\(.full_name)\t\(.default_branch)\t\($listing)"' --arg owner "$login" --arg listing "$listing" |
        sort
}

audit_repo() {
    local repo="$1" branch="$2" listing="$3" ref managed expected=null expected_state
    local required=null ruleset enforcement="" policy="n/a" reason="" name="$default_ruleset_name"
    local rc count id others="[]" readable="" probe_why=""
    local encoded="${ruleset_path// /%20}"
    ref="$(uri "$branch")"

    # proven_absent — a file read just returned 404. Absence is reported only
    # when proven: a contents read of the same ref succeeds (once per
    # repository). Sought only for a claimed absence, so its outcome always
    # lands in the field that claims it; otherwise that field is unknown.
    proven_absent() {
        if [ -z "$readable" ]; then
            readable=no
            if fetch "repos/$repo/contents?ref=$ref" "$tmp_dir/root.json" 'type == "array"'; then
                readable=yes
            else
                probe_why="404 not proven absent: contents of $branch unreadable ($why)"
            fi
        fi
        [ "$readable" = yes ] && return 0
        why="$probe_why"
        return 1
    }

    rc=0
    fetch "repos/$repo/contents/.copier-answers.yml?ref=$ref" "$tmp_dir/answers" '.type == "file"' || rc=$?
    if [ "$rc" -eq 0 ]; then
        managed=yes
    elif [ "$rc" -eq 4 ] && proven_absent; then
        managed=no
    else
        managed=unknown && note "copier answers: $why"
    fi

    rc=0
    fetch "repos/$repo/contents/$encoded?ref=$ref" "$tmp_dir/file.json" "$ruleset_check" \
        -H 'Accept: application/vnd.github.raw+json' || rc=$?
    if [ "$rc" -eq 0 ] && expected="$(decode "$tmp_dir/file.json" "$contexts" -c)" &&
        name="$(decode "$tmp_dir/file.json" '.name')"; then
        expected_state=present
    elif [ "$rc" -eq 4 ] && proven_absent; then
        expected_state=absent
    else
        expected=null expected_state=unknown name="$default_ruleset_name"
        note "checked-in ruleset: $why"
    fi

    if ! fetch_pages "repos/$repo/rulesets?includes_parents=false" "$tmp_dir/list.json" "$rulesets_check"; then
        ruleset=unknown && note "rulesets: $why"
    elif ! others="$(decode "$tmp_dir/list.json" '[.[] | select(.name != $name) | .name] | unique' -c --arg name "$name")" ||
        ! count="$(decode "$tmp_dir/list.json" '[.[] | select(.name == $name and .source_type == "Repository")] | length' --arg name "$name")"; then
        others="[]" ruleset=unknown && note "rulesets: $why"
    else
        case "$count" in
        0) ruleset=absent ;;
        1)
            if id="$(decode "$tmp_dir/list.json" '.[] | select(.name == $name and .source_type == "Repository") | .id | numbers' -e --arg name "$name")" &&
                fetch "repos/$repo/rulesets/$id" "$tmp_dir/live.json" "$ruleset_check and (.enforcement | type) == \"string\"" &&
                required="$(decode "$tmp_dir/live.json" "$contexts" -c)" &&
                enforcement="$(decode "$tmp_dir/live.json" '.enforcement')"; then
                ruleset=present
            else
                ruleset=unknown required=null enforcement="" && note "ruleset ${id:-?}: $why"
            fi
            ;;
        *) ruleset=unknown && note "$count rulesets named $name" ;;
        esac
    fi

    # Full-policy verdict from audit-ruleset.sh's own lookup and normalization,
    # fed the documents already fetched (no second set of API calls). It counts
    # only when the exit status and its verdict line agree: under `set -e` an
    # internal failure also exits 1, which must not read as drift.
    if [ "$expected_state" = present ] && [ "$ruleset" = present ]; then
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
        else
            note "full-policy comparison failed"
        fi
    fi

    record --arg repo "$repo" --arg listing "$listing" --arg branch "$branch" --arg managed "$managed" \
        --arg ruleset "$ruleset" --arg name "$name" --arg enforcement "$enforcement" --arg policy "$policy" \
        --arg reason "$reason" --arg expected_state "$expected_state" \
        --argjson expected "$expected" --argjson required "$required" --argjson others "$others" '
        ($expected // []) as $e | ($required // []) as $r
        | {repo: $repo, listing: $listing, default_branch: $branch, managed: $managed, ruleset: $ruleset,
           enforcement: (if $enforcement == "" then null else $enforcement end),
           expected: $expected, required: $required, other_rulesets: $others,
           missing: (if $expected == null or $required == null then null else $e - $r end),
           extra: (if $expected == null or $required == null then null else $r - $e end),
           policy: $policy}
        # Every computed field reaches the status except other_rulesets and the
        # owner listing, which are informational. Any unknown field makes the
        # record unknown, and gated needs the full-policy comparison clean too:
        # equal contexts on a ruleset whose conditions miss the default branch,
        # or with extra bypass actors, do not gate merges.
        | .status = (
            if [$managed, $ruleset, $expected_state, $policy] | index("unknown") then "unknown"
            elif $expected_state == "absent" and $managed == "yes" then "unknown"
            elif $expected_state == "absent" then "unmanaged"
            elif $ruleset == "absent" or ($r | length) == 0 or .enforcement != "active" then "ungated"
            elif (.missing | length) > 0 or (.extra | length) > 0 then "drift"
            elif $policy == "drift" then "drift"
            elif $policy == "clean" then "gated"
            else "unknown" end)
        | .reason = (if $reason != "" then $reason
            elif .status == "unknown" then "managed repository has no checked-in ruleset"
            elif .status == "ungated" and $ruleset == "absent" then "no live ruleset named \($name)"
                + (if ($others | length) > 0 then " (other rulesets: \($others | join(", ")))" else "" end)
            elif .status == "ungated" and ($r | length) == 0 then "live ruleset requires no status check"
            elif .status == "ungated" then "live ruleset enforcement is \(.enforcement // "unset")"
            elif .status == "drift" and (.missing | length) == 0 and (.extra | length) == 0 then
                "full policy differs from the checked-in ruleset (task audit:ruleset in that repository shows the diff)"
            else null end)'
}

for target in "${targets[@]}"; do
    case "$target" in
    */*/* | /* | */)
        echo "audit-fleet-rulesets: not OWNER or OWNER/REPO: $target" >&2
        exit 2
        ;;
    */*)
        if fetch "repos/$target" "$tmp_dir/repo.json" \
            '(.full_name | type) == "string" and (.default_branch | type) == "string"'; then
            audit_repo "$(decode "$tmp_dir/repo.json" '.full_name')" \
                "$(decode "$tmp_dir/repo.json" '.default_branch')" named
        else
            unknown_record "$target" "repository: $why"
        fi
        ;;
    *)
        if list_repos "$target" >"$tmp_dir/repos.tsv"; then
            while IFS="$(printf '\t')" read -r repo branch listing; do
                [ -n "$repo" ] && audit_repo "$repo" "$branch" "$listing"
            done <"$tmp_dir/repos.tsv"
        else
            jq -nc --arg owner "$target" '{owner: $owner, kind: null, listing: "unknown"}' >>"$owners"
            unknown_record "$target/*" "owner listing: $why" unknown
        fi
        ;;
    esac
done

[ -s "$records" ] || {
    echo "audit-fleet-rulesets: no repository found" >&2
    exit 2
}

report="$(jq -n --slurpfile repos "$records" --slurpfile owners "$owners" \
    '{owners: $owners, repositories: $repos,
      summary: ($repos | group_by(.status) | map({key: .[0].status, value: length}) | from_entries)}')"

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
    jq -r '.owners[] | "owner \(.owner): \(.kind // "unknown") listing \(.listing)"
        + (if .listing == "public-only" then " (public repositories only: the token is not this account)"
           elif .listing == "token-visible" then " (repositories this token can read; not proven complete)" else "" end)' <<<"$report"
    jq -r '.summary | to_entries | map("\(.key)=\(.value)") | "summary: " + join(" ")' <<<"$report"
fi

if jq -e '(.summary.unknown // 0) > 0' >/dev/null <<<"$report"; then
    exit 2
fi
if jq -e '(.summary.drift // 0) + (.summary.ungated // 0) > 0' >/dev/null <<<"$report"; then
    exit 1
fi
exit 0
