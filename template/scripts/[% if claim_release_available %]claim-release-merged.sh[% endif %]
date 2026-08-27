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

# Treat PR-body text as data.  This recognizes standalone #N tokens plus the
# repository-qualified same-repo form (this exact owner/repo immediately
# before the #, itself preceded by a non-word character): a partial PR may
# legitimately write `Refs owner/repo#N` about its own repository.  Any other
# owner/repo#N, and URL fragments, keep their alphanumeric predecessor and are
# excluded.  The release engine still owns every write decision through its
# timestamp and branch-bound claim-record checks.
# Prefer the merge event's own body snapshot (PR_BODY, set by the workflow):
# a body edited after the merge must not change what a delayed or retried run
# processes. The fetch is only the fallback for manual/backfill invocations.
if [ "${PR_BODY+set}" = set ]; then
    body="$PR_BODY"
else
    body="$(gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json body --jq '.body // ""')"
fi
printf '%s\n' "$body" | awk -v repo="$GH_REPO" '
{
    for (i = 1; i <= length($0); i++) {
        if (substr($0, i, 1) != "#") {
            continue
        }
        before = i == 1 ? "" : substr($0, i - 1, 1)
        if (before != "" && before ~ /[[:alnum:]_]/) {
            qual_start = i - length(repo)
            # GitHub owner/repo slugs are case-insensitive.
            if (qual_start < 1 || tolower(substr($0, qual_start, length(repo))) != tolower(repo)) {
                continue
            }
            qual_before = qual_start == 1 ? "" : substr($0, qual_start - 1, 1)
            if (qual_before != "" && qual_before ~ /[[:alnum:]_.\/-]/) {
                continue
            }
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
    # A body reference can name a number that is not a live issue (deleted, a
    # typo, a PR). The audit line must not abort the loop and starve the
    # releases of the PR's other referenced issues.
    issue_json="$(gh api "repos/$GH_REPO/issues/$audit_issue" 2>/dev/null || printf '{}')"
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
