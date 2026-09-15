#!/usr/bin/env bash
# Hermetic truth tables for CI aggregation and closing-keyword semantics.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

workflow="${repo}/.github/workflows/build.yml"
grep -q 'HEAD_REPO:.*head.repo.full_name' "$workflow" || fail 'bootstrap must compare the PR head repository'
grep -q "grep -q '(HTTP 404)'" "$workflow" || fail 'bootstrap must require a confirmed default-branch 404'
grep -Fq '[ "$HEAD_REPO" = "$GH_REPO" ]' "$workflow" || fail 'bootstrap must permit same-repo heads only'
grep -q 'fetch_script "$DEFAULT_BRANCH"' "$workflow" || fail 'guard must prefer the default-branch script'
grep -q 'fetch_script "$HEAD_SHA"' "$workflow" || fail 'same-repo bootstrap must fetch the head SHA'
grep -q 'PR_COMMITS:.*pull_request.commits' "$workflow" || fail 'guard must receive the PR commit count'
grep -Fq '[ "$PR_COMMITS" -gt 250 ]' "$workflow" || fail 'guard must reject PRs beyond the commits API limit'
grep -Fq 'closing-keyword result is indeterminate' "$workflow" || fail 'commit-limit rejection must be distinct'
commit_limit_line="$(grep -nF '[ "$PR_COMMITS" -gt 250 ]' "$workflow" | cut -d: -f1)"
commits_fetch_line="$(grep -nF 'gh api --paginate "repos/${GH_REPO}/pulls/${PR_NUMBER}/commits"' "$workflow" | cut -d: -f1)"
[ "$commit_limit_line" -lt "$commits_fetch_line" ] || fail 'commit-limit rejection must precede the commits API fetch'

# Keep the closing-keyword fixtures in this CI contract test rather than in an
# orphan target: all five semantic cases run wherever CI checks its result
# aggregation, including generated repositories without vendored skills.
"${repo}/scripts/test-closing-keywords.sh"

echo "closing-keyword semantics: PASS"
