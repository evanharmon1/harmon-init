#!/usr/bin/env bash
# claim-release-merged.sh — release the claim attributable to a merged PR.
#
# A PR may complete one work unit while its issue stays open for a later phase
# or a HUMAN criterion.  This script joins GitHub's closing references with
# conservative same-repo #N references in the PR body, then leaves attribution
# to release-claim.sh's --branch check.  It never changes issue completion.
set -euo pipefail

for required in GH_REPO PR_NUMBER MERGED_AT HEAD_REF; do
    [ -n "${!required:-}" ] || {
        echo "$required is required" >&2
        exit 2
    }
done

release_script="${RELEASE_CLAIM_SCRIPT:-./.claude/skills/track-work/assets/release-claim.sh}"
[ -e "$release_script" ] || {
    echo "release-claim script is missing: $release_script" >&2
    exit 2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
issues_file="$tmp/issues"
: >"$issues_file"

# GitHub resolves closing keywords itself.  A same-repo URL is the only kind
# this workflow can safely act on; cross-repository references are ignored.
gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[]
          | select(.url | startswith("https://github.com/" + env.GH_REPO + "/"))
          | .number' >>"$issues_file"

# Treat PR-body text as data.  This deliberately recognizes only standalone
# #N tokens: owner/repo#N and URL fragments have an alphanumeric predecessor
# and are therefore excluded.  The release engine still owns every write
# decision through its timestamp and branch-bound claim-record checks.
body="$(gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json body --jq '.body // ""')"
printf '%s\n' "$body" | awk '
{
    for (i = 1; i <= length($0); i++) {
        if (substr($0, i, 1) != "#") {
            continue
        }
        before = i == 1 ? "" : substr($0, i - 1, 1)
        if (before != "" && before ~ /[[:alnum:]_]/) {
            continue
        }
        j = i + 1
        while (j <= length($0) && substr($0, j, 1) ~ /[0-9]/) {
            j++
        }
        if (j == i + 1) {
            continue
        }
        after = j > length($0) ? "" : substr($0, j, 1)
        if (after != "" && after ~ /[[:alnum:]_]/) {
            continue
        }
        print substr($0, i + 1, j - i - 1)
        i = j - 1
    }
}' >>"$issues_file"

summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
}

write_audit() {
    audit_issue="$1"
    audit_result="$2"
    issue_json="$(gh api "repos/$GH_REPO/issues/$audit_issue")"
    issue_state="$(jq -r '.state // "unknown"' <<<"$issue_json")"
    remaining=0
    if [ "$issue_state" = "open" ]; then
        remaining="$(jq -r '.body // ""' <<<"$issue_json" |
            grep -Ec '^[[:space:]]*[-*+][[:space:]]+\[[[:space:]]\][[:space:]]' || true)"
    fi
    summary "### PR #$PR_NUMBER → issue #$audit_issue"
    summary "- Claim release: $audit_result"
    summary "- Issue state: $issue_state"
    if [ "$issue_state" = "open" ]; then
        summary "- Remaining unticked criteria: $remaining"
    fi
}

job_rc=0
while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    rc=0
    "$release_script" \
        --repo "$GH_REPO" --issue "$issue" \
        --reason "PR #${PR_NUMBER} merged (claiming work unit complete)" \
        --not-after "$MERGED_AT" --branch "$HEAD_REF" || rc=$?
    case "$rc" in
    0) write_audit "$issue" "released" ;;
    3) write_audit "$issue" "no attributable live claim" ;;
    *)
        write_audit "$issue" "failed (exit $rc)"
        echo "issue #$issue: release failed with exit $rc — continuing to the rest" >&2
        job_rc="$rc"
        ;;
    esac
done < <(sort -nu "$issues_file")

exit "$job_rc"
