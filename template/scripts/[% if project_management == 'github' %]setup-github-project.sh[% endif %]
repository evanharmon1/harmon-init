#!/usr/bin/env bash
# setup-github-project.sh — idempotently create and sync a GitHub Project V2 for a
# repo owner (an organization OR a personal user account): the board, its
# Status pipeline (docs/project-management.md), and the Size project NUMBER
# field — the numeric estimate stays a project field for BOTH owner types,
# because only project number fields sum in view group headers (issue-field
# columns can group/filter/sort, not sum). The other metadata on an ORGANIZATION
# are org-level ISSUE fields (Priority/Effort are GitHub built-ins, left at
# their defaults; setup-github-issue-fields.sh adds Product + Agent); on a
# personal account (no org issue fields) this script creates
# Priority/Product/Agent as project fields too.
#
# Safe to re-run and safe to run from every repo the owner controls: it looks the
# project up by title, so the first run creates it and later runs just reconcile
# fields. It never deletes options or fields, so your later customizations survive.
#
# Usage:   setup-github-project.sh --owner <org-or-user-login> --title "<Project Title>"
# Needs:   gh authed with the 'project' scope (gh auth refresh -s project) + jq.
#
# NOTE: this hits the live GitHub API, so it is not exercised by `task
# test:template` (which never touches GitHub) — it is guarded by shellcheck +
# shfmt only. Test it against a scratch project when changing it.
set -euo pipefail

owner=""
title=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --owner)
        owner="${2:-}"
        shift 2
        ;;
    --title)
        title="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$owner" ] || [ -z "$title" ]; then
    echo "Usage: $0 --owner <org-or-user-login> --title \"<Project Title>\"" >&2
    exit 2
fi

for tool in gh jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

# Full Status pipeline (docs/project-management.md), in board order. GitHub's API
# cannot create the visual groups, so these render as a flat, ordered list.
status_pipeline='[
  {"name":"Inbox","color":"GRAY","description":"Newly landed, unsorted"},
  {"name":"Icebox","color":"GRAY","description":"Real, but not now"},
  {"name":"Next","color":"PINK","description":"Will pull in soon"},
  {"name":"Todo","color":"BLUE","description":"Committed, not started"},
  {"name":"Shaping","color":"BLUE","description":"Problem/approach being defined"},
  {"name":"Ready","color":"BLUE","description":"Shaped, ready to pick up"},
  {"name":"Agent Queue","color":"BLUE","description":"Queued for an AI agent"},
  {"name":"In Progress","color":"YELLOW","description":"Actively being worked"},
  {"name":"Verifying","color":"ORANGE","description":"CI/checks running"},
  {"name":"In Review","color":"GREEN","description":"Under human review"},
  {"name":"Ready to Merge","color":"GREEN","description":"Approved, awaiting merge"},
  {"name":"Done","color":"PURPLE","description":"Merged/shipped"},
  {"name":"Deployed","color":"PURPLE","description":"Deployed"},
  {"name":"Accepted","color":"PURPLE","description":"Smoke/QA/manual check passed"}
]'

# jq filter: a JSON array of {name,color,description} -> a GraphQL options
# fragment. Names/descriptions are JSON-escaped; color is emitted as a bare enum.
opts_to_graphql='[.[] | "{name:" + (.name|@json) + ",color:" + .color + ",description:" + (.description|@json) + "}"] | join(",")'

# ── Resolve the owner (org or user), then find the project by title ──
# repositoryOwner + a ProjectV2Owner fragment is one code path for both User and
# Organization owners (both implement the interface).
echo "==> Resolving owner '$owner'"
owner_data=$(gh api graphql -f query='query($l:String!){repositoryOwner(login:$l){__typename id}}' \
    -f l="$owner")
owner_type=$(printf '%s' "$owner_data" | jq -r '.data.repositoryOwner.__typename')
owner_id=$(printf '%s' "$owner_data" | jq -r '.data.repositoryOwner.id')
if [ -z "$owner_id" ] || [ "$owner_id" = "null" ]; then
    echo "Could not resolve owner '$owner' — check the login and that you have the 'project' scope." >&2
    exit 1
fi

echo "==> Looking for a project titled '$title'"
project_id=""
project_number=""
cursor=""
while true; do
    if [ -n "$cursor" ]; then
        page=$(gh api graphql -f query='query($l:String!,$c:String){repositoryOwner(login:$l){... on ProjectV2Owner{projectsV2(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{id number title}}}}}' \
            -f l="$owner" -f c="$cursor")
    else
        page=$(gh api graphql -f query='query($l:String!){repositoryOwner(login:$l){... on ProjectV2Owner{projectsV2(first:100){pageInfo{hasNextPage endCursor} nodes{id number title}}}}}' \
            -f l="$owner")
    fi
    match=$(printf '%s' "$page" |
        jq -r --arg t "$title" '.data.repositoryOwner.projectsV2.nodes[] | select(.title==$t) | (.id + "\t" + (.number|tostring))' |
        head -n1)
    if [ -n "$match" ]; then
        project_id=$(printf '%s' "$match" | cut -f1)
        project_number=$(printf '%s' "$match" | cut -f2)
        break
    fi
    has_next=$(printf '%s' "$page" | jq -r '.data.repositoryOwner.projectsV2.pageInfo.hasNextPage')
    [ "$has_next" = "true" ] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.repositoryOwner.projectsV2.pageInfo.endCursor')
done

created=0
if [ -n "$project_id" ]; then
    echo "    Found existing project #$project_number"
else
    echo "    Not found — creating '$title'"
    resp=$(gh api graphql -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number}}}' \
        -f o="$owner_id" -f t="$title")
    project_id=$(printf '%s' "$resp" | jq -r '.data.createProjectV2.projectV2.id')
    project_number=$(printf '%s' "$resp" | jq -r '.data.createProjectV2.projectV2.number')
    created=1
    echo "    Created project #$project_number"
fi

# For an organization, record the project id in the ORG_PROJECT_ID org variable
# that project-automation.yml + the claude-* workflows read (preferred over a
# title lookup). Personal accounts have no org-level variable scope, and their
# status automation is a separate follow-up, so skip it there.
if [ "$owner_type" = "Organization" ]; then
    echo "==> Recording project id in the ORG_PROJECT_ID org variable"
    if ! gh variable set ORG_PROJECT_ID --org "$owner" --visibility all --body "$project_id"; then
        echo "WARNING: could not set the ORG_PROJECT_ID org variable (needs org admin)." >&2
        echo "         Set it by hand: gh variable set ORG_PROJECT_ID --org \"$owner\" --body \"$project_id\"" >&2
    fi
else
    echo "==> Owner is a user account — skipping ORG_PROJECT_ID (no user-level variable scope; personal status automation is a separate follow-up)"
fi

# ── Snapshot current fields (one read; reused for existence checks) ──
fields_json=$(gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{fields(first:50){nodes{... on ProjectV2FieldCommon{id name} ... on ProjectV2SingleSelectField{options{name color description}}}}}}}' \
    -f p="$project_id")

field_id() {
    printf '%s' "$fields_json" |
        jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name==$n) | .id' | head -n1
}

# ── Status field: full pipeline on a new project; preserve + append on an
#    existing one so items already assigned to an option are never orphaned ──
status_field_id=$(field_id "Status")
if [ -z "$status_field_id" ]; then
    echo "==> Creating the Status field with the full pipeline"
    frag=$(printf '%s' "$status_pipeline" | jq -r "$opts_to_graphql")
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:SINGLE_SELECT,name:\"Status\",singleSelectOptions:[$frag]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}" \
        >/dev/null
else
    if [ "$created" = "1" ]; then
        echo "==> Setting Status to the full pipeline (new project)"
        desired="$status_pipeline"
    else
        echo "==> Syncing Status (keeping existing options, appending any missing)"
        existing=$(printf '%s' "$fields_json" |
            jq -c '[.data.node.fields.nodes[] | select(.name=="Status") | .options[] | {name, color: (.color // "GRAY" | ascii_upcase), description: (.description // "")}]')
        desired=$(jq -cn --argjson ex "$existing" --argjson pl "$status_pipeline" \
            '$ex + [ $pl[] | select( .name as $n | ([ $ex[].name ] | index($n)) == null ) ]')
    fi
    frag=$(printf '%s' "$desired" | jq -r "$opts_to_graphql")
    gh api graphql -f f="$status_field_id" \
        -f query="mutation(\$f:ID!){updateProjectV2Field(input:{fieldId:\$f,singleSelectOptions:[$frag]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}" \
        >/dev/null
fi

# ── Custom fields: create-if-missing; existing fields are left untouched ──
create_single_select() {
    name="$1"
    options_json="$2"
    if [ -n "$(field_id "$name")" ]; then
        echo "    Field '$name' already exists — leaving it as-is"
        return 0
    fi
    echo "    Creating single-select field '$name'"
    frag=$(printf '%s' "$options_json" | jq -r "$opts_to_graphql")
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:SINGLE_SELECT,name:\"$name\",singleSelectOptions:[$frag]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}" \
        >/dev/null
}

create_text() {
    name="$1"
    if [ -n "$(field_id "$name")" ]; then
        echo "    Field '$name' already exists — leaving it as-is"
        return 0
    fi
    echo "    Creating text field '$name'"
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:TEXT,name:\"$name\"}){projectV2Field{... on ProjectV2FieldCommon{id}}}}" \
        >/dev/null
}

create_number() {
    name="$1"
    if [ -n "$(field_id "$name")" ]; then
        echo "    Field '$name' already exists — leaving it as-is"
        return 0
    fi
    echo "    Creating number field '$name'"
    gh api graphql -f p="$project_id" \
        -f query="mutation(\$p:ID!){createProjectV2Field(input:{projectId:\$p,dataType:NUMBER,name:\"$name\"}){projectV2Field{... on ProjectV2FieldCommon{id}}}}" \
        >/dev/null
}

# Size: a project NUMBER field for BOTH owner types — estimation points on the
# Fibonacci ladder (1/2/3/5/8/13/21; the ladder is a convention, the field takes
# free numeric entry). Project views can group/filter/sort by org ISSUE-field
# columns, but group-header SUMS only work for project NUMBER fields — and the
# per-group sum is Size's whole job (docs/project-management.md, Planning view).
# GitHub's built-in Effort ISSUE field (single-select) is left at its default;
# Size is the numeric, summable estimate.
echo "==> Size project field (number — views sum it per group)"
create_number "Size"

# Other metadata: on an ORGANIZATION these are org-level ISSUE fields (durable —
# the value is on the issue, shared across every project; see
# docs/project-management.md). Priority is a GitHub built-in;
# setup-github-issue-fields.sh adds Product + Agent. A personal account has no org
# issue fields, so fall back to creating them as project fields here.
if [ "$owner_type" = "Organization" ]; then
    echo "==> Other metadata are org issue fields (Priority/Effort built-ins, left at their defaults; run setup-github-issue-fields.sh for Product/Agent)"
    echo "==> Done — project #$project_number: $title"
    exit 0
fi

echo "==> Custom project fields (personal account; starters — re-runs won't clobber them)"
create_single_select "Priority" '[
  {"name":"Urgent","color":"RED","description":""},
  {"name":"High","color":"ORANGE","description":""},
  {"name":"Medium","color":"YELLOW","description":""},
  {"name":"Low","color":"GRAY","description":""}
]'
create_text "Product"
create_single_select "Agent" '[
  {"name":"Claude Code","color":"ORANGE","description":""},
  {"name":"Codex","color":"BLUE","description":""},
  {"name":"Gemini CLI","color":"PURPLE","description":""},
  {"name":"Qwen Code","color":"GREEN","description":""},
  {"name":"DeepSeek","color":"RED","description":""},
  {"name":"Kimi K2","color":"YELLOW","description":""},
  {"name":"GLM","color":"PINK","description":""},
  {"name":"GitHub Copilot","color":"GRAY","description":""}
]'

echo "==> Done — project #$project_number: $title"
