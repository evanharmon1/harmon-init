#!/usr/bin/env bash
# setup-github-issue-types.sh — idempotently ensure the org's issue types are
# Bug, Feature, Task, Research. Create-if-missing only: it keeps GitHub's default
# Bug/Feature/Task types and never deletes a type, so it is non-destructive; in
# practice it just adds Research.
#
# Issue types are an ORG-level feature (there's no per-user equivalent), so this
# is org-only. Needs gh authed with the 'admin:org' scope + jq.
#
# The types are a loose, downstream-inert categorization; the load-bearing
# vocabulary is the conventional-commit types (Task ⟶ chore, etc.). See the
# mapping in docs/conventions.md.
#
# Usage: setup-github-issue-types.sh --org <org-login>
#
# NOTE: hits the live GitHub API, so it is not exercised by `task test:template`
# (which never touches GitHub) — guarded by shellcheck + shfmt only. Test it
# against a scratch org when changing it.
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

# Desired issue types — mirror the issue forms. Colors are GitHub's issue-type
# palette: gray, blue, green, yellow, orange, red, pink, purple.
desired='[
  {"name":"Bug","color":"red","description":"A defect — something is broken"},
  {"name":"Feature","color":"yellow","description":"A new capability or improvement"},
  {"name":"Task","color":"purple","description":"General work — maintenance, chores, cleanup"},
  {"name":"Research","color":"blue","description":"A question or investigation"}
]'

echo "==> Reading existing issue types for '$org'"
existing=$(gh api "orgs/$org/issue-types" --paginate 2>/dev/null || true)
if [ -z "$existing" ]; then
    echo "Could not read issue types for '$org' — is it an organization, and do you have 'admin:org'?" >&2
    exit 1
fi

type_id() {
    # $1 = issue-type name -> prints its id, or empty
    printf '%s' "$existing" | jq -r --arg n "$1" '.[] | select(.name==$n) | .id' | head -n1
}

# Create any desired type that's still missing. Bug, Feature, and Task ship as
# org defaults, so those are typically left as-is; Research is the one that gets
# created.
printf '%s' "$desired" | jq -c '.[]' | while IFS= read -r t; do
    name=$(printf '%s' "$t" | jq -r '.name')
    if [ -n "$(type_id "$name")" ]; then
        echo "    Issue type '$name' already exists — leaving it as-is"
        continue
    fi
    echo "    Creating issue type '$name'"
    gh api --method POST "orgs/$org/issue-types" \
        -f name="$name" -F is_enabled=true \
        -f color="$(printf '%s' "$t" | jq -r '.color')" \
        -f description="$(printf '%s' "$t" | jq -r '.description')" >/dev/null
done

echo "==> Done — issue types on '$org': Bug, Feature, Task, Research"
