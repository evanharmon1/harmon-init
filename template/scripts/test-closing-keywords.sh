#!/usr/bin/env bash
# test-closing-keywords.sh — offline behavior fixtures for the closing-keyword
# guard. The fixture directory replaces GitHub's read-only Issues API.
set -euo pipefail
cd "$(dirname "$0")/.."
# Absolute, captured BEFORE any fixture `cd`: the remote fixtures below run the
# helpers from another directory and must still source this checkout's library.
repo_root="$PWD"

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
if [ "${GH_STUB_ENDLESS:-0}" = 1 ]; then
    # Every page is full (exactly per_page items, as GitHub answers), so only
    # a bound can end the walk.
    n="${endpoint##*per_page=}"
    n="${n%%&*}"
    case "$endpoint" in
    orgs/acme/issue-fields\?*) jq -cn --argjson n "$n" '{issue_fields: [range(0;$n) | {id:.}]}' ;;
    *) jq -cn --argjson n "$n" '[range(0;$n) | {number:.}]' ;;
    esac
    exit 0
fi
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

echo '==> the page ceiling bounds every walk and returns its own code'
# MAX_ITEMS=0 against an endless endpoint: without GH_REST_MAX_PAGES this would
# be the unbounded whole-repository walk the helpers exist to prevent.
: >"$GH_STUB_CALLS"
rc=0
GH_STUB_ENDLESS=1 GH_REST_MAX_PAGES=3 PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_array "repos/acme/repo/pulls?state=all" 0' >/dev/null || rc=$?
[ "$rc" = 4 ] || fail "page ceiling on an array walk returned ${rc}, expected 4"
[ "$(grep -c '^api repos/acme/repo/pulls' "$GH_STUB_CALLS")" = 3 ] ||
    fail "page ceiling let the array walk request $(grep -c '^api ' "$GH_STUB_CALLS") pages, expected 3"
: >"$GH_STUB_CALLS"
rc=0
GH_STUB_ENDLESS=1 GH_REST_MAX_PAGES=2 PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_key "orgs/acme/issue-fields" issue_fields' >/dev/null || rc=$?
[ "$rc" = 4 ] || fail "page ceiling on a keyed walk returned ${rc}, expected 4"
[ "$(grep -c '^api orgs/acme/issue-fields' "$GH_STUB_CALLS")" = 2 ] ||
    fail "page ceiling let the keyed walk request $(grep -c '^api ' "$GH_STUB_CALLS") pages, expected 2"
# A MAX_ITEMS under the ceiling ends the walk normally, without spending it.
: >"$GH_STUB_CALLS"
count="$(GH_STUB_ENDLESS=1 GH_REST_MAX_PAGES=3 PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_array "repos/acme/repo/pulls?state=all" 150 | jq -s "add | length"')" ||
    fail 'a bounded walk under the ceiling must succeed'
[ "$count" = 150 ] || fail "MAX_ITEMS=150 returned ${count} items"
[ "$(grep -c '^api ' "$GH_STUB_CALLS")" = 2 ] || fail 'MAX_ITEMS=150 should cost exactly two pages'
rc=0
GH_REST_MAX_PAGES=0 PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_array "repos/acme/repo/pulls?state=all" 0' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "GH_REST_MAX_PAGES=0 must be rejected (got ${rc}); zero would mean no ceiling"

echo '==> MAX_ITEMS is a required positional, never guessed from a following option'
for args in '"repos/acme/repo/pulls?state=open"' '"repos/acme/repo/pulls?state=open" -H "Accept: x"' '"repos/acme/repo/pulls?state=open" ten'; do
    : >"$GH_STUB_CALLS"
    rc=0
    PATH="$tmp/bin:$PATH" bash -c ". scripts/lib/gh-rest.sh; gh_rest_paginate_array ${args}" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "gh_rest_paginate_array ${args} returned ${rc}, expected 2"
    [ ! -s "$GH_STUB_CALLS" ] || fail "gh_rest_paginate_array ${args} reached gh with an unusable limit"
done
: >"$GH_STUB_CALLS"
PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_array "repos/acme/repo/pulls?state=open" 5' >/dev/null ||
    fail 'two-argument form failed'
[ "$(grep -c '^api repos/acme/repo/pulls?state=open&per_page=5&page=1$' "$GH_STUB_CALLS")" = 1 ] ||
    fail "two-argument form forwarded the endpoint wrongly: $(cat "$GH_STUB_CALLS")"
: >"$GH_STUB_CALLS"
PATH="$tmp/bin:$PATH" bash -c \
    '. scripts/lib/gh-rest.sh; gh_rest_paginate_array "repos/acme/repo/pulls?state=open" 5 -H "Accept: x"' >/dev/null ||
    fail 'limit-then-option form failed'
[ "$(grep -c '^api repos/acme/repo/pulls?state=open&per_page=5&page=1 -H Accept: x$' "$GH_STUB_CALLS")" = 1 ] ||
    fail "limit-then-option form forwarded the endpoint wrongly: $(cat "$GH_STUB_CALLS")"

echo '==> the GitHub host survives into every REST read'
# gh documents GH_REPO as [HOST/]OWNER/REPO. Splitting the host off keeps the
# endpoint at repos/OWNER/REPO; passing it back as --hostname keeps the read on
# the host it names. The git stub answers nothing about remotes here, so the
# host can only have come from GH_REPO.
: >"$GH_STUB_CALLS"
out="$(PATH="$tmp/bin:$PATH" GH_REPO=ghe.example.com/acme/repo bash -c \
    '. scripts/lib/gh-rest.sh; repo="$(gh_rest_repo)"; echo "$repo $(gh_rest_host)"; gh_rest_api "repos/${repo}/issues/1" >/dev/null')" ||
    fail 'host-qualified GH_REPO read failed'
[ "$out" = 'acme/repo ghe.example.com' ] || fail "host-qualified GH_REPO parsed as '${out}'"
grep -qx 'api repos/acme/repo/issues/1 --hostname ghe.example.com' "$GH_STUB_CALLS" ||
    fail "host-qualified GH_REPO read went to: $(cat "$GH_STUB_CALLS")"
# Plain OWNER/REPO with no remote: no host is known, so gh keeps its own choice.
: >"$GH_STUB_CALLS"
out="$(PATH="$tmp/bin:$PATH" GH_REPO=acme/repo bash -c \
    'unset GH_HOST; . scripts/lib/gh-rest.sh; echo "$(gh_rest_repo)|$(gh_rest_host)"; gh_rest_api "repos/acme/repo/issues/1" >/dev/null')" ||
    fail 'plain GH_REPO read failed'
[ "$out" = 'acme/repo|' ] || fail "plain GH_REPO parsed as '${out}'"
grep -qx 'api repos/acme/repo/issues/1' "$GH_STUB_CALLS" ||
    fail "plain GH_REPO read went to: $(cat "$GH_STUB_CALLS")"
# Remote-derived hosts: an SSH Enterprise remote in both URL forms carries its
# host; a github.com remote adds nothing. Real git builds these fixtures, so
# only gh is stubbed on PATH for them.
mkdir -p "$tmp/bin-gh"
cp "$tmp/bin/gh" "$tmp/bin-gh/gh"
for form in ssh://git@ghe.example.com/acme/repo.git git@ghe.example.com:acme/repo.git; do
    rm -rf "$tmp/remote-fixture"
    git init -q "$tmp/remote-fixture"
    git -C "$tmp/remote-fixture" remote add origin "$form"
    : >"$GH_STUB_CALLS"
    out="$(cd "$tmp/remote-fixture" && PATH="$tmp/bin-gh:$PATH" bash -c \
        "unset GH_REPO GH_HOST; . '$repo_root/scripts/lib/gh-rest.sh'; repo=\"\$(gh_rest_repo)\"; echo \"\$repo \$(gh_rest_host)\"; gh_rest_api \"repos/\${repo}/issues/1\" >/dev/null")" ||
        fail "remote ${form} read failed"
    [ "$out" = 'acme/repo ghe.example.com' ] || fail "remote ${form} parsed as '${out}'"
    grep -qx 'api repos/acme/repo/issues/1 --hostname ghe.example.com' "$GH_STUB_CALLS" ||
        fail "remote ${form} read went to: $(cat "$GH_STUB_CALLS")"
done
rm -rf "$tmp/remote-fixture"
git init -q "$tmp/remote-fixture"
git -C "$tmp/remote-fixture" remote add origin https://github.com/acme/repo.git
: >"$GH_STUB_CALLS"
out="$(cd "$tmp/remote-fixture" && PATH="$tmp/bin-gh:$PATH" bash -c \
    "unset GH_REPO GH_HOST; . '$repo_root/scripts/lib/gh-rest.sh'; echo \"\$(gh_rest_repo) \$(gh_rest_host)\"; gh_rest_api 'repos/acme/repo/issues/1' >/dev/null")" ||
    fail 'github.com remote read failed'
[ "$out" = 'acme/repo github.com' ] || fail "github.com remote parsed as '${out}'"
grep -qx 'api repos/acme/repo/issues/1' "$GH_STUB_CALLS" ||
    fail "github.com remote must not add --hostname, got: $(cat "$GH_STUB_CALLS")"

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
