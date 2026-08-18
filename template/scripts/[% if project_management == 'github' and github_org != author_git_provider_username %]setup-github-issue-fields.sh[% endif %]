#!/usr/bin/env bash
# setup-github-issue-fields.sh — idempotently add the org ISSUE FIELDS that are
# NOT GitHub built-ins: Product. GitHub already ships Priority, Effort, Start
# date, and Target date as built-in issue fields, and we never recreate or
# modify those (leave them at their defaults).
#
# There is deliberately no Domain or Layer issue field (#875): they used to
# mirror the `domain:`/`layer:` label families in setup-github-labels.sh with
# nothing syncing an issue's field value to its label, and only the label
# surface is readable without project scope, writable with plain repo scope,
# and available on personal repos — so it is the one that stays (see
# docs/project-management.md, "Label or field?").
#
# NB: the numeric, summable estimate is NOT an issue field — it is the Size
# project NUMBER field (setup-github-project.sh), because only project number
# fields sum in view group headers. The built-in single-select Effort issue
# field stays as GitHub ships it (a coarse gut-check, not the estimate).
#
# Issue fields are org-level, durable metadata: the value lives on the *issue*
# (not a project item), is the same across every project the issue belongs to,
# and shows in the issue timeline — unlike Project (V2) fields. `Status`
# deliberately stays a Project field (it's the board pipeline the built-in +
# project-automation workflows drive), so it is NOT created here.
#
# Issue fields are an ORG-level feature (no per-user equivalent), so this is
# org-only. Needs gh authed with the 'admin:org' scope + jq.
#
# Usage: setup-github-issue-fields.sh --org <org-login>
#
# NOTE: issue fields are in GitHub PUBLIC PREVIEW — the API is subject to change,
# and this hits the live API so it is not exercised by `task test:template`
# (guarded by shellcheck + shfmt only). Test it against a scratch org, and pin
# api_version below if the endpoint moves.
set -euo pipefail

org=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --org)
        org="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$org" ]; then
    echo "Usage: $0 --org <org-login>" >&2
    exit 2
fi

for tool in gh jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
# Task buffers stdout in grouped mode. Keep legacy progress and the visual
# outcome on one live stream so their chronology cannot be reversed.
exec 1>&2
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "$script_dir/lib/output.sh"

action_banner setup "GitHub issue fields" "Durable organization metadata"
kv "Organization" "$org"

# Preview REST API version for issue fields; bump if GitHub moves the endpoint.
api_version="2026-03-10"

# There is deliberately no Agent field: advisory agent routing is the
# `suggest:*` label family plus the `Status: Agent Queue` lane, and the live
# claim is a `claim:*` label (docs/project-management.md, ADR 0005 D4).

# refresh_fields — (re-)read the org's issue fields into existing_json. Returns
# non-zero when the read or the parse fails, leaving any previous snapshot in
# place so a caller can refuse to act rather than act on stale data.
#
# Normalizing: the list endpoint returns a bare array; tolerate an
# {"issue_fields":[...]} wrapper too, and `--paginate`'s multiple concatenated
# documents — `jq -s` slurps every document, so the pages become one array.
refresh_fields() {
    _raw=$(gh api "orgs/$org/issue-fields" -H "X-GitHub-Api-Version: $api_version" --paginate 2>/dev/null || true)
    [ -n "$_raw" ] || return 1
    _json=$(printf '%s' "$_raw" |
        jq -s '[ .[] | if type == "object" then (.issue_fields // []) else . end | .[] ]' 2>/dev/null || true)
    [ -n "$_json" ] || return 1
    existing_json="$_json"
}

echo "==> Reading existing issue fields for '$org'"
if ! refresh_fields; then
    echo "Could not read issue fields for '$org' — is it an org, do you have 'admin:org', is the" >&2
    echo "issue-fields preview enabled, and did the response parse?" >&2
    exit 1
fi

# field_json NAME — the whole field object, or empty when there is no such field.
field_json() { printf '%s' "$existing_json" | jq -c --arg n "$1" '[ .[] | select(.name==$n) ] | first // empty'; }
field_present() { [ -n "$(field_json "$1")" ]; }
field_type() { printf '%s' "$existing_json" | jq -r --arg n "$1" '[ .[] | select(.name==$n) ] | first | .data_type // ""'; }

# A field name generic enough that an adopting org may already have one — of
# the wrong data type. GitHub cannot change an issue field's data type in
# place, so the intended field is simply unavailable until it is renamed or
# deleted. Warn (loudly, and again in the summary) rather than exit non-zero:
# this script only ever creates, and one pre-existing field the org owns is
# not a reason to abort.
incompatible=""

# create_field NAME DATA_TYPE DESCRIPTION
create_field() {
    name="$1"
    dtype="$2"
    desc="$3"
    if field_present "$name"; then
        etype="$(field_type "$name")"
        if [ -n "$etype" ] && [ "$etype" != "$dtype" ]; then
            echo "    WARNING: issue field '$name' already exists as '$etype', not '$dtype'" >&2
            incompatible="${incompatible}${incompatible:+, }${name} (is '$etype', wanted '$dtype')"
        else
            echo "    Issue field '$name' already exists — leaving it as-is"
        fi
        return 0
    fi
    echo "    Creating $dtype issue field '$name'"
    body=$(jq -cn --arg n "$name" --arg d "$desc" --arg t "$dtype" \
        '{name:$n,description:$d,data_type:$t}')
    printf '%s' "$body" |
        gh api --method POST "orgs/$org/issue-fields" \
            -H "X-GitHub-Api-Version: $api_version" --input - >/dev/null
}

create_field "Product" "text" "Which product/area it belongs to"

if [ -n "$incompatible" ]; then
    checkline unknown "Done, WITH WARNINGS" "issue fields have incompatible existing types"
    echo "    These fields already exist with a different data type: $incompatible" >&2
    echo "    GitHub cannot change an issue field's data type in place. Rename or delete each one in the org's" >&2
    echo "    issue-field settings and re-run this script to get the intended options." >&2
    output_summary "Issue field provisioning"
    output_warning "GitHub issue fields need attention; resolve the warnings above and re-run"
else
    checkline ok "Issue fields" "Product (Priority/Effort/dates are GitHub built-ins)"
    output_summary "Issue field provisioning"
    output_done "GitHub issue fields are ready on $org"
fi
