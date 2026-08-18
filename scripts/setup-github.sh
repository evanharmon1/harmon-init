#!/usr/bin/env bash
# Apply the repository-level GitHub settings that are safe to reconcile.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "${script_dir}/lib/output.sh"

repo=""
bot_collaborator=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        repo="${2:-}"
        shift 2
        ;;
    --bot-collaborator)
        bot_collaborator="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "Usage: $0 --repo <owner/repo> [--bot-collaborator <login>]" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Required tool not found: gh" >&2
    exit 1
fi

fail_step() {
    local rc="$1" label="$2" detail="$3"
    checkline no "$label" "$detail (exit $rc)"
}

section_header "GitHub repository setup"
kv "Repository" "$repo"

if output_run "Enabling Dependabot alerts" \
    gh api "repos/$repo/vulnerability-alerts" --method PUT; then
    checkline ok "Dependabot alerts" "enabled"
else
    rc=$?
    fail_step "$rc" "Dependabot alerts" "GitHub API request failed"
    exit "$rc"
fi

if repo_private="$(gh api "repos/$repo" --jq '.private')"; then
    :
else
    rc=$?
    fail_step "$rc" "Repository visibility" "could not determine public/private state"
    exit "$rc"
fi
case "$repo_private" in
true | false) ;;
*)
    fail_step 1 "Repository visibility" "unexpected '.private' value: ${repo_private:-<empty>}"
    exit 1
    ;;
esac

if [ "$repo_private" = false ]; then
    if output_run "Enabling private vulnerability reporting" \
        gh api "repos/$repo/private-vulnerability-reporting" --method PUT; then
        checkline ok "Private vulnerability reporting" "enabled"
    else
        rc=$?
        fail_step "$rc" "Private vulnerability reporting" "GitHub API request failed"
        exit "$rc"
    fi
else
    checkline na "Private vulnerability reporting" "skipped — private repository; feature is public-repo-only"
fi

if [ -n "$bot_collaborator" ]; then
    if output_run "Adding bot collaborator" \
        gh api "repos/$repo/collaborators/$bot_collaborator" --method PUT -f permission=push; then
        checkline ok "Bot collaborator" "$bot_collaborator has push access"
    else
        rc=$?
        fail_step "$rc" "Bot collaborator" "could not grant push access to $bot_collaborator"
        exit "$rc"
    fi
fi

output_done "GitHub repository settings are ready for $repo"
