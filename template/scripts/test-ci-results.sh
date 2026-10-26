#!/usr/bin/env bash
# Hermetic truth tables for CI aggregation and closing-keyword semantics.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
verifier="${repo}/scripts/verify-ci-results.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

accept_required() {
    label="$1"
    expected="$2"
    shift 2
    if ! EXPECTED_RESULT="$expected" "$verifier" "$@" >/dev/null 2>&1; then
        fail "CI result helper rejected ${label}"
    fi
}

reject_required() {
    label="$1"
    expected="$2"
    shift 2
    if EXPECTED_RESULT="$expected" "$verifier" "$@" >/dev/null 2>&1; then
        fail "CI result helper accepted ${label}"
    fi
}

accept_required "trusted jobs succeeding" success check=success security=success
accept_required "fork-suppressed jobs skipping" skipped check=skipped security=skipped
reject_required "a skipped trusted job" success check=success security=skipped
reject_required "a successful fork-suppressed job" skipped check=skipped security=success
reject_required "a failed job" success check=success security=failure
reject_required "a cancelled job" success check=success security=cancelled
reject_required "an unknown job result" success check=success security=unknown
reject_required "an empty result" success check=success security=
reject_required "an empty job name" success =success
reject_required "a malformed pair" success check
reject_required "an unsupported expectation" neutral check=neutral
reject_required "an empty result set" success

# A docs skip is evidence from a successful classifier, on PRs only.
if ! output="$(DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
    DOCS_ONLY_JOBS='build-test' "$verifier" changes=success check=success build-test=skipped 2>&1)"; then
    fail 'classifier-authorized skip rejected'
fi
grep -Fq 'Job build-test deliberately skipped: docs-only' <<<"$output" ||
    fail 'deliberate skip was not reported distinctly'
for classifier_result in failure cancelled skipped ''; do
    if DOCS_ONLY=true CHANGES_RESULT="$classifier_result" CI_EVENT_NAME=pull_request \
        DOCS_ONLY_JOBS='build-test' "$verifier" build-test=skipped >/dev/null 2>&1; then
        fail "upstream-failure skip accepted ($classifier_result)"
    fi
done
for event in push merge_group workflow_dispatch ''; do
    if DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME="$event" \
        DOCS_ONLY_JOBS='build-test' "$verifier" build-test=skipped >/dev/null 2>&1; then
        fail "docs-only skip accepted on $event"
    fi
done
for docs_only in false unknown ''; do
    if DOCS_ONLY="$docs_only" CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
        DOCS_ONLY_JOBS='build-test' "$verifier" build-test=skipped >/dev/null 2>&1; then
        fail "skip accepted with docs_only=$docs_only"
    fi
done
if DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
    DOCS_ONLY_JOBS='build-test' "$verifier" security=skipped >/dev/null 2>&1; then
    fail 'security skip accepted on a docs-only PR'
fi
if DOCS_ONLY=true CHANGES_RESULT=success CI_EVENT_NAME=pull_request \
    DOCS_ONLY_JOBS='build-test' "$verifier" check=failure build-test=skipped >/dev/null 2>&1; then
    fail 'docs skip hid a failed always-on job'
fi

# Root-only CI coverage needs the stress job bound into both verifier paths.
# Generated consumers do not declare that root-only job, so their rendered
# workflow takes the same aggregate checks without these extra assertions.
if grep -Eq '^  session-cleanup-stress:' "$repo/.github/workflows/build.yml"; then
    trusted_inline="$(awk '
        /name: Verify required jobs succeeded/ { step = 1 }
        step && /^        run: / { sub(/^        run: /, ""); print; exit }
    ' "$repo/.github/workflows/build.yml")"
    [ -n "$trusted_inline" ] || fail 'inline trusted aggregate was not found'
    trusted_aggregate() {
        CHANGES_RESULT=success CHECK_RESULT=success REPO_GUARDS_RESULT=success \
            DEVCONTAINER_PERMISSIONS_RESULT=success TEMPLATE_TEST_RESULT=success \
            SESSION_CLEANUP_STRESS_RESULT="$1" \
            bash -c "cd \"$repo\" && $trusted_inline" >/dev/null 2>&1
    }
    trusted_aggregate success || fail 'inline aggregate rejected successful cleanup stress'
    for result in failure cancelled skipped; do
        if trusted_aggregate "$result"; then
            fail "inline aggregate accepted cleanup stress result: $result"
        fi
    done
fi

# Exercise the actual inline fork aggregate: it must fail if a job did not
# skip at the fork boundary, rather than treating an upstream failure as a skip.
inline="$(awk '
    /name: Verify deliberate skips at the untrusted-fork boundary/ { step = 1 }
    step && /^        run: \|/ { body = 1; next }
    body && /^      -/ { exit }
    body { sub(/^          /, ""); print }
' "$repo/.github/workflows/build.yml")"
[ -n "$inline" ] || fail 'inline fork aggregate was not found'
fork_aggregate() {
    CHANGES_RESULT="$1" CHECK_RESULT=skipped REPO_GUARDS_RESULT=skipped \
        DEVCONTAINER_PERMISSIONS_RESULT=skipped TEMPLATE_TEST_RESULT=skipped \
        SESSION_CLEANUP_STRESS_RESULT="${2:-skipped}" \
        CODEGEN_GUARD_RESULT=skipped SECURITY_RESULT=skipped BUILD_TEST_RESULT=skipped \
        E2E_RESULT=skipped LIGHTHOUSE_RESULT=skipped RENDER_PARITY_RESULT=skipped \
        bash -c "$inline" >/dev/null 2>&1
}
fork_aggregate skipped || fail 'inline aggregate rejected deliberate fork skips'
if fork_aggregate failure; then
    fail 'inline aggregate accepted a classifier failure at the fork boundary'
fi
if grep -Eq '^  session-cleanup-stress:' "$repo/.github/workflows/build.yml" &&
    fork_aggregate skipped success; then
    fail 'inline aggregate accepted a non-skipped cleanup stress job at the fork boundary'
fi

# The closing-keyword guard lives in its own workflow (harmon-init#1328) so it
# can keep the `pull_request.edited` trigger the build matrix deliberately
# drops — it reads the PR title and body, so a body edit genuinely changes its
# input, while a body edit cannot change what the matrix tests.
workflow="${repo}/.github/workflows/closing-keywords.yml"
grep -q 'types: \[opened, edited, synchronize, reopened\]' "$workflow" ||
    fail 'the closing-keyword guard must re-run when the PR title or body is edited'
# Fixed-string over the trigger block with COMMENTS STRIPPED: `\b` is a GNU
# extension (BSD grep happens to honour it, ugrep does too — but a negative
# assertion that silently stops matching is vacuous, and this form depends on
# nothing beyond POSIX). Comments must go first: build.yml's own explanation of
# why `edited` is absent contains the word.
if awk '/^on:/,/^jobs:/' "${repo}/.github/workflows/build.yml" |
    grep -v '^[[:space:]]*#' | grep -F 'edited' >/dev/null; then
    fail 'the build matrix must not re-run on a PR title/body edit'
fi
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

echo "CI result helper truth tables: PASS"
