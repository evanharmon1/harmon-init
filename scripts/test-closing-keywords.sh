#!/usr/bin/env bash
# test-closing-keywords.sh — offline behavior fixtures for the closing-keyword
# guard. The fixture directory replaces GitHub's read-only Issues API.
set -euo pipefail
cd "$(dirname "$0")/.."

guard="./scripts/check-closing-keywords.sh"
guard_driver="./scripts/guard-closing-keywords.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/issues"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
issue() { printf '%s\n' "$2" >"$tmp/issues/acme_repo__$1.md"; }
run() {
    title="$1"
    body="$2"
    commits="$3"
    printf '%s\n' "$commits" >"$tmp/commits"
    rc=0
    ISSUE_BODY_DIR="$tmp/issues" PR_TITLE="$title" PR_BODY="$body" \
        "$guard" --repo acme/repo --title-env PR_TITLE --body-env PR_BODY \
        --commits-file "$tmp/commits" >"$tmp/out" 2>"$tmp/err" || rc=$?
    echo "$rc"
}

issue 1 '- [x] completed'
issue 2 '- [ ] still open'

echo '==> rejects unfinished same-repo issues across title, body, and commits'
[ "$(run 'fix: closes #2' '' '')" = 1 ] || fail 'title closing reference must fail'
[ "$(run 'fix: x' 'Resolves #2' '')" = 1 ] || fail 'body closing reference must fail'
[ "$(run 'fix: x' '' $'chore: first\n\nFixes #2')" = 1 ] || fail 'commit closing reference must fail'

echo '==> a fully completed same-repo issue passes'
[ "$(run 'fix: closes #1' '' '')" = 0 ] || fail 'completed issue should pass'

echo '==> explicit same-repo references are evaluated'
[ "$(run 'fix: closes acme/repo#2' '' '')" = 1 ] || fail 'explicit same-repo reference must fail'
[ "$(run 'fix: x' 'Fixes https://github.com/acme/repo/issues/1' '')" = 0 ] ||
    fail 'completed same-repo issue URL should pass'

echo '==> case variants of same-repo references are evaluated'
[ "$(run 'fix: closes AcMe/RePo#2' '' '')" = 1 ] ||
    fail 'mixed-case same-repo shorthand must fail'
[ "$(run 'fix: x' 'Fixes https://GiThUb.CoM/AcMe/RePo/issues/2' '')" = 1 ] ||
    fail 'mixed-case GitHub URL must fail'

echo '==> explicit owner/repo references are informational, not queried'
[ "$(run 'fix: closes other/repo#99' 'Fixes https://github.com/other/repo/issues/100' '')" = 0 ] ||
    fail 'cross-repository references should be informational'
grep -q 'informational' "$tmp/out" || fail 'informational references should be reported'

echo '==> an unreadable same-repo issue fails distinctly'
[ "$(run 'fix: closes #404' '' '')" = 2 ] || fail 'unreadable issue should fail closed with exit 2'
grep -q 'could not verify' "$tmp/err" || fail 'unreadable issue needs a distinct message'

echo '==> no closing keyword is inert without issue metadata'
[ "$(run 'fix: x' 'Refs #404' '')" = 0 ] || fail 'non-closing reference should pass'

echo '==> REST-only proxy reads preserve checker and guard verdicts'
mkdir -p "$tmp/bin"
cat >"$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
merge-base) printf '%s\n' base ;;
rev-list) printf '%s\n' 0 ;;
log) ;;
branch) printf '%s\n' feature ;;
*) exit 64 ;;
esac
STUB
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${GH_STUB_CALLS:-}" ] || printf '%s\n' "$*" >>"${GH_STUB_CALLS}"
[ "${1:-}" = api ] || {
    echo "proxy: non-REST gh command rejected: $*" >&2
    exit 64
}
endpoint="${2:-}"
case "$endpoint" in
graphql | search/* | repositories/*)
    echo 'HTTP 403: GitHub GraphQL/search/paginate links are unavailable' >&2
    exit 1
    ;;
*'&page=2'*)
    printf '[]\n'
    ;;
repos/acme/repo/pulls\?*)
    [ "${GH_STUB_FAIL:-0}" = 0 ] || exit 1
    if [ "${GH_STUB_FULL_PAGE:-0}" = 1 ]; then
        jq -cn '[range(0;100) | {number:.}]'
    else
        printf '%s\n' "${GH_STUB_PR_JSON:-[]}"
    fi
    ;;
repos/acme/repo/issues/1)
    [ "${GH_STUB_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' '- [x] completed'
    ;;
repos/acme/repo/issues/2)
    [ "${GH_STUB_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' '- [ ] still open'
    ;;
*)
    echo "proxy: unexpected endpoint: $endpoint" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$tmp/bin/git" "$tmp/bin/gh"

GH_STUB_CALLS="$tmp/proxy-calls"
export GH_STUB_CALLS
: >"$GH_STUB_CALLS"
page_count="$(GH_STUB_FULL_PAGE=1 PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_array "repos/acme/repo/pulls?state=open" 0 | jq -s "add | length"')"
[ "$page_count" = 100 ] || fail "explicit REST pagination returned ${page_count}, expected 100"
grep -q 'repos/acme/repo/pulls?state=open&per_page=100&page=2' "$GH_STUB_CALLS" ||
    fail 'explicit REST pagination never requested page 2'
grep -q 'repositories/' "$GH_STUB_CALLS" &&
    fail 'REST pagination followed a forbidden numeric repositories link'

proxy_checker() {
    local title="$1" rc=0
    : >"$tmp/proxy-commits"
    PATH="$tmp/bin:$PATH" PR_TITLE="$title" PR_BODY='' \
        "$guard" --repo acme/repo --title-env PR_TITLE --body-env PR_BODY \
        --commits-file "$tmp/proxy-commits" >"$tmp/proxy-out" 2>"$tmp/proxy-err" || rc=$?
    echo "$rc"
}
[ "$(proxy_checker 'fix: closes #1')" = 0 ] || fail 'REST completed issue should pass'
[ "$(proxy_checker 'fix: closes #2')" = 1 ] || fail 'REST unfinished issue should fail'
GH_STUB_FAIL=1
export GH_STUB_FAIL
[ "$(proxy_checker 'fix: closes #1')" = 2 ] || fail 'REST read failure must be indeterminate'
unset GH_STUB_FAIL

proxy_guard() {
    local pr_json="$1" rc=0
    GH_STUB_PR_JSON="$pr_json" PATH="$tmp/bin:$PATH" GH_REPO=acme/repo \
        BASE_SHA=HEAD HEAD_SHA=HEAD "$guard_driver" >"$tmp/driver-out" 2>"$tmp/driver-err" || rc=$?
    echo "$rc"
}
[ "$(proxy_guard '[{"title":"fix: closes #1","body":""}]')" = 0 ] ||
    fail "REST guard completed-issue verdict should pass: $(cat "$tmp/driver-err")"
[ "$(proxy_guard '[{"title":"fix: closes #2","body":""}]')" = 1 ] ||
    fail "REST guard unfinished-issue verdict should fail: $(cat "$tmp/driver-err")"
GH_STUB_FAIL=1
export GH_STUB_FAIL
[ "$(proxy_guard '[]')" = 2 ] ||
    fail "REST guard metadata failure must be indeterminate: $(cat "$tmp/driver-err")"
unset GH_STUB_FAIL
unset GH_STUB_CALLS

echo 'closing-keywords guard: all cases passed'
