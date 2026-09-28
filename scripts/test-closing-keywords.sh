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
rev-parse) printf '%s\n' localhead ;;
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
repos/acme/repo/pulls\?*head=*)
    # GitHub's `head` filter is OWNER:ref matched against the HEAD repository's
    # owner, so a filter built from the BASE owner matches nothing a fork opened.
    # Answering it the way GitHub would is what makes the fork fixture below
    # fail if that query shape ever comes back.
    [ "${GH_STUB_FAIL:-0}" = 0 ] || exit 1
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

echo '==> an explicit port survives only where it is the API authority'
# A colon means three different things across the remote forms, so stripping it
# everywhere cost an Enterprise instance published on a non-default port its API
# authority before --hostname was ever passed (challenge r4). Each case asserts
# the exact --hostname that reaches gh, which is the only thing the port is for.
for spec in \
    'https://ghe.example.com:8443/acme/repo.git|ghe.example.com:8443' \
    'ssh://git@ghe.example.com:2222/acme/repo.git|ghe.example.com' \
    'git@ghe.example.com:acme/repo.git|ghe.example.com'; do
    form="${spec%%|*}"
    want="${spec#*|}"
    rm -rf "$tmp/remote-fixture"
    git init -q "$tmp/remote-fixture"
    git -C "$tmp/remote-fixture" remote add origin "$form"
    : >"$GH_STUB_CALLS"
    out="$(cd "$tmp/remote-fixture" && PATH="$tmp/bin-gh:$PATH" bash -c \
        "unset GH_REPO GH_HOST; . '$repo_root/scripts/lib/gh-rest.sh'; repo=\"\$(gh_rest_repo)\"; echo \"\$repo \$(gh_rest_host)\"; gh_rest_api \"repos/\${repo}/issues/1\" >/dev/null")" ||
        fail "ported remote ${form} read failed"
    [ "$out" = "acme/repo ${want}" ] ||
        fail "ported remote ${form} resolved to '${out}', expected 'acme/repo ${want}'"
    grep -qx "api repos/acme/repo/issues/1 --hostname ${want}" "$GH_STUB_CALLS" ||
        fail "ported remote ${form} read went to: $(cat "$GH_STUB_CALLS")"
done
# A port that is not a number leaves the authority unusable, so the derivation
# says nothing at all — gh keeps its own choice — rather than passing on a
# --hostname it cannot parse. The name is validated apart from the port for the
# same reason: one class over `host:port` would have to admit `:` and would then
# accept `ghe:8443:x` and `:443` as hosts.
rm -rf "$tmp/remote-fixture"
git init -q "$tmp/remote-fixture"
git -C "$tmp/remote-fixture" remote add origin 'https://ghe.example.com:not-a-port/acme/repo.git'
: >"$GH_STUB_CALLS"
out="$(cd "$tmp/remote-fixture" && PATH="$tmp/bin-gh:$PATH" bash -c \
    "unset GH_REPO GH_HOST; . '$repo_root/scripts/lib/gh-rest.sh'; echo \"\$(gh_rest_repo)|\$(gh_rest_host)\"; gh_rest_api 'repos/acme/repo/issues/1' >/dev/null")" ||
    fail 'unparseable-port remote read failed'
[ "$out" = 'acme/repo|' ] || fail "unparseable-port remote resolved to '${out}', expected no host"
grep -q -- '--hostname' "$GH_STUB_CALLS" &&
    fail "an unparseable port reached gh as a hostname: $(cat "$GH_STUB_CALLS")"

echo '==> hyphenated owners and names resolve (this repository is one)'
# The resolved OWNER/REPO was validated against `*[!A-Za-z0-9_.-/]*`, in which
# `.-/` is the RANGE 0x2E-0x2F: it admitted `/` and rejected `-`, so EVERY
# hyphenated repository failed resolution — evanharmon1/harmon-init included,
# which cost `task guard:closing-keywords` its PR metadata and `task status:gh`
# its whole open-PR section (challenge r3). Every fixture above is hyphen-free,
# which is exactly why they missed it; these cover a hyphen in the name, in the
# owner, and in both, across the remote URL forms.
for spec in \
    'git@github.com:evanharmon1/harmon-init.git|evanharmon1/harmon-init github.com' \
    'https://github.com/acme/harmon-init.git|acme/harmon-init github.com' \
    'ssh://git@ghe.example.com/my-org/widget.git|my-org/widget ghe.example.com' \
    'git@ghe.example.com:my-org/harmon-init.git|my-org/harmon-init ghe.example.com'; do
    form="${spec%%|*}"
    want="${spec#*|}"
    rm -rf "$tmp/remote-fixture"
    git init -q "$tmp/remote-fixture"
    git -C "$tmp/remote-fixture" remote add origin "$form"
    out="$(cd "$tmp/remote-fixture" && PATH="$tmp/bin-gh:$PATH" bash -c \
        "unset GH_REPO GH_HOST; . '$repo_root/scripts/lib/gh-rest.sh'; echo \"\$(gh_rest_repo) \$(gh_rest_host)\"")" ||
        fail "hyphenated remote ${form} read failed"
    [ "$out" = "$want" ] || fail "hyphenated remote ${form} resolved to '${out}', expected '${want}'"
done
# The same shape arriving through gh's own [HOST/]OWNER/REPO override.
out="$(PATH="$tmp/bin:$PATH" GH_REPO=ghe.example.com/my-org/harmon-init bash -c \
    '. scripts/lib/gh-rest.sh; echo "$(gh_rest_repo) $(gh_rest_host)"')" ||
    fail 'hyphenated host-qualified GH_REPO read failed'
[ "$out" = 'my-org/harmon-init ghe.example.com' ] ||
    fail "hyphenated host-qualified GH_REPO resolved to '${out}'"

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
[ "$(proxy_guard '[{"title":"fix: closes #1","body":"","head":{"sha":"localhead","ref":"feature"}}]')" = 0 ] ||
    fail "REST guard completed-issue verdict should pass: $(cat "$tmp/driver-err")"
[ "$(proxy_guard '[{"title":"fix: closes #2","body":"","head":{"sha":"localhead","ref":"feature"}}]')" = 1 ] ||
    fail "REST guard unfinished-issue verdict should fail: $(cat "$tmp/driver-err")"
GH_STUB_FAIL=1
export GH_STUB_FAIL
[ "$(proxy_guard '[]')" = 2 ] ||
    fail "REST guard metadata failure must be indeterminate: $(cat "$tmp/driver-err")"
unset GH_STUB_FAIL

echo '==> a fork PR is found by a local ref match, not by a base-owner query'
# The listing used to be filtered server side with `head=OWNER:branch` built from
# the BASE repository's owner. GitHub matches that against the HEAD repository's
# owner, so a PR opened from a fork matched nothing: the guard fell through to
# its inert placeholder metadata and scanned the commits against a title and
# body that were never the PR's (challenge r3). The gh stub answers any
# head-filtered listing with [], the way GitHub answers one naming the wrong
# owner, so a regression to that query shape fails every case below.
fork_head='"head":{"sha":"localhead","ref":"feature","repo":{"full_name":"contributor/repo"}}'
fork_base='"base":{"repo":{"full_name":"acme/repo"}}'
[ "$(proxy_guard "[{\"title\":\"fix: closes #2\",\"body\":\"\",${fork_head},${fork_base}}]")" = 1 ] ||
    fail "a fork PR's real title was not used: $(cat "$tmp/driver-err")"
grep -q 'inert pre-PR metadata' "$tmp/driver-err" &&
    fail "a fork PR was demoted to placeholder metadata: $(cat "$tmp/driver-err")"
# Its body too, not only its title: only the real one carries this reference.
[ "$(proxy_guard "[{\"title\":\"fix: x\",\"body\":\"Resolves #2\",${fork_head},${fork_base}}]")" = 1 ] ||
    fail "a fork PR's real body was not used: $(cat "$tmp/driver-err")"
# A head that has since moved remotely is still matched, because the ref is what
# selects — the matching `gh pr list --head "$branch"` did before the rewrite.
moved_head='"head":{"sha":"a1b2c3d4","ref":"feature","repo":{"full_name":"contributor/repo"}}'
[ "$(proxy_guard "[{\"title\":\"fix: closes #2\",\"body\":\"\",${moved_head}}]")" = 1 ] ||
    fail "a fork PR whose head moved was not matched by branch: $(cat "$tmp/driver-err")"
# Two PRs on one branch name stay fail-closed rather than picking one.
other_head='"head":{"sha":"e5f6a7b8","ref":"feature","repo":{"full_name":"other/repo"}}'
[ "$(proxy_guard "[{\"title\":\"fix: closes #1\",\"body\":\"\",${moved_head}},{\"title\":\"fix: closes #2\",\"body\":\"\",${other_head}}]")" = 2 ] ||
    fail "two PRs matching one branch must stay indeterminate: $(cat "$tmp/driver-err")"
grep -q 'multiple open PRs match branch' "$tmp/driver-err" ||
    fail "the multiple-match branch reported the wrong reason: $(cat "$tmp/driver-err")"

echo '==> the branch ref selects the PR; a stranger on this head SHA does not'
# The listing used to be selected on .head.sha == the local head FIRST, falling
# back to the branch ref only when that matched nothing — so any unrelated open
# PR that happened to share this checkout's head commit outranked the branch's
# own PR and supplied the wrong title and body (challenge r4). Both listings
# below hold such a stranger, and each verdict is reachable ONLY by reading the
# branch's own PR: not by the old precedence, which reads the stranger, and not
# by the placeholder path, which reads neither.
stranger_head='"head":{"sha":"localhead","ref":"someone-elses-branch"}'
mine_moved_head='"head":{"sha":"a1b2c3d4","ref":"feature"}'
[ "$(proxy_guard "[{\"title\":\"fix: closes #1\",\"body\":\"\",${stranger_head}},{\"title\":\"fix: closes #2\",\"body\":\"\",${mine_moved_head}}]")" = 1 ] ||
    fail "the branch's own PR was not the one read: $(cat "$tmp/driver-err")"
[ "$(proxy_guard "[{\"title\":\"fix: closes #2\",\"body\":\"\",${stranger_head}},{\"title\":\"fix: closes #1\",\"body\":\"\",${mine_moved_head}}]")" = 0 ] ||
    fail "a stranger sharing the head SHA supplied the verdict: $(cat "$tmp/driver-err")"
grep -q 'inert pre-PR metadata' "$tmp/driver-err" &&
    fail "the branch's own PR was demoted to placeholder metadata: $(cat "$tmp/driver-err")"

echo '==> the local head SHA still narrows a ref several open PRs share'
# Demoted from selector to tie-breaker, not dropped: two PRs on this branch's
# ref resolve to the one whose head IS this checkout's, rather than staying
# indeterminate the way two unidentifiable ones do.
mine_here_head='"head":{"sha":"localhead","ref":"feature"}'
same_ref_head='"head":{"sha":"e5f6a7b8","ref":"feature"}'
[ "$(proxy_guard "[{\"title\":\"fix: closes #2\",\"body\":\"\",${mine_here_head}},{\"title\":\"fix: closes #1\",\"body\":\"\",${same_ref_head}}]")" = 1 ] ||
    fail "the head SHA did not narrow two PRs on one ref: $(cat "$tmp/driver-err")"

echo '==> a listing that filled its bound cannot witness an absence'
# The lookup reads one bounded page of open PRs, and a repository with more can
# leave an older branch's PR on a page nobody asked for. Grading that as "no PR"
# fell through to the inert placeholder metadata and scanned the commits alone,
# silently weakening the guard — so a full page with no match is indeterminate,
# exactly as a failed listing is. This is the invariant the three status.sh
# inventories encode: an incomplete read is unknown, never "none" (challenge r2).
rc=0
GH_STUB_FULL_PAGE=1 PATH="$tmp/bin:$PATH" GH_REPO=acme/repo BASE_SHA=HEAD HEAD_SHA=HEAD \
    "$guard_driver" >"$tmp/driver-out" 2>"$tmp/driver-err" || rc=$?
[ "$rc" = 2 ] ||
    fail "a full open-PR page with no match must be indeterminate, got ${rc}: $(cat "$tmp/driver-err")"
grep -q 'supply both PR_TITLE and PR_BODY' "$tmp/driver-err" ||
    fail "the bound-filled listing did not name the remedy: $(cat "$tmp/driver-err")"
grep -q 'inert pre-PR metadata' "$tmp/driver-err" &&
    fail "a bound-filled listing was graded as an absence: $(cat "$tmp/driver-err")"
# A page SHORT of the bound with no match really is an absence, and keeps the
# placeholder path: that is the pre-PR pre-flight this guard is usually run as.
[ "$(proxy_guard '[]')" = 0 ] ||
    fail "a complete empty listing should scan commits inertly: $(cat "$tmp/driver-err")"
grep -q 'inert pre-PR metadata' "$tmp/driver-err" ||
    fail "a complete empty listing did not take the placeholder path: $(cat "$tmp/driver-err")"

echo '==> a host-qualified GH_REPO reaches the guard only through the helper'
# End-to-end, through the same stub: gh documents GH_REPO as [HOST/]OWNER/REPO,
# and the guard now resolves it exclusively through gh_rest_repo. While it read
# GH_REPO itself it built repos/ghe.example.com/acme/repo/pulls and a
# ghe.example.com:feature head query — an endpoint that cannot exist, from a
# host whose only correct destination is --hostname (challenge r2). The stub
# answers repos/acme/repo/pulls alone, so a bypass cannot reach a verdict here.
: >"$GH_STUB_CALLS"
rc=0
GH_STUB_PR_JSON='[{"title":"fix: closes #1","body":"","head":{"sha":"localhead","ref":"feature"}}]' PATH="$tmp/bin:$PATH" \
    GH_REPO=ghe.example.com/acme/repo BASE_SHA=HEAD HEAD_SHA=HEAD \
    "$guard_driver" >"$tmp/driver-out" 2>"$tmp/driver-err" || rc=$?
[ "$rc" = 0 ] ||
    fail "host-qualified GH_REPO guard run exited ${rc}: $(cat "$tmp/driver-err")"
grep -qx 'api repos/acme/repo/pulls?state=open&sort=updated&direction=desc&per_page=100&page=1 --hostname ghe.example.com' \
    "$GH_STUB_CALLS" ||
    fail "host-qualified GH_REPO did not reach the PR lookup normalized: $(grep '^api ' "$GH_STUB_CALLS" | tr '\n' ';')"
grep -q 'repos/ghe.example.com/' "$GH_STUB_CALLS" &&
    fail "the host leaked into an endpoint path: $(grep '^api ' "$GH_STUB_CALLS" | tr '\n' ';')"
grep -q 'ghe.example.com%3A' "$GH_STUB_CALLS" &&
    fail "the host leaked into the head query: $(grep '^api ' "$GH_STUB_CALLS" | tr '\n' ';')"
# ...and the checker it hands off to was given the normalized OWNER/REPO too:
# only that spelling reaches the issue read the verdict above came from.
grep -q '^api repos/acme/repo/issues/1 .*--hostname ghe.example.com$' "$GH_STUB_CALLS" ||
    fail "the checker was handed a host-qualified repository: $(grep '^api ' "$GH_STUB_CALLS" | tr '\n' ';')"
unset GH_STUB_CALLS

echo 'closing-keywords guard: all cases passed'
