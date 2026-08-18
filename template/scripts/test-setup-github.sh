#!/usr/bin/env bash
# Unit-test setup-github.sh against a stubbed gh; never touches GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/scripts/setup-github.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    [ -f "$tmp/out" ] && sed 's/^/    /' "$tmp/out" >&2
    exit 1
}

mkdir -p "$tmp/bin"
stub_calls="$tmp/calls"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALLS:?}"
case "$*" in
*"${GH_FAIL_MATCH:-__never__}"*) exit "${GH_FAIL_RC:-1}" ;;
esac
case "$*" in
*" --jq .private") printf '%s\n' "${GH_PRIVATE:-true}" ;;
esac
STUB
chmod +x "$tmp/bin/gh"

run_case() {
    : >"$stub_calls"
    set +e
    PATH="$tmp/bin:$PATH" STUB_CALLS="$stub_calls" NO_COLOR=1 \
        "$script" "$@" >"$tmp/out" 2>&1
    run_rc=$?
    set -e
}

echo "==> private repositories report success plus the reason for a skip"
GH_PRIVATE=true run_case --repo owner/private
[ "$run_rc" -eq 0 ] || fail "private path exited $run_rc"
grep -Fq '[x] Dependabot alerts - enabled' "$tmp/out" || fail "missing Dependabot success"
grep -Fq '[-] Private vulnerability reporting - skipped: private repository' "$tmp/out" || fail "missing private-repo skip reason"
grep -Fq 'DONE: GitHub repository settings are ready for owner/private' "$tmp/out" || fail "missing final outcome"
LC_ALL=C od -An -tu1 -v "$tmp/out" | awk '
    { for (i = 1; i <= NF; i++) if ($i != 9 && $i != 10 && $i != 13 && ($i < 32 || $i > 126)) exit 1 }
' || fail "plain setup output contains non-ASCII presentation bytes"
if grep -q 'private-vulnerability-reporting' "$stub_calls"; then
    fail "private repository attempted to enable public-only reporting"
fi

echo "==> public repositories enable every requested setting and collaborator"
GH_PRIVATE=false run_case --repo owner/public --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "public path exited $run_rc"
grep -Fq '[x] Private vulnerability reporting - enabled' "$tmp/out" || fail "missing reporting success"
grep -Fq '[x] Bot collaborator - owner-bot has push access' "$tmp/out" || fail "missing collaborator success"
grep -q 'private-vulnerability-reporting --method PUT' "$stub_calls" || fail "reporting API was not called"
grep -q 'collaborators/owner-bot --method PUT -f permission=push' "$stub_calls" || fail "collaborator API was not called"

echo "==> failures are formatted, preserve status, and never claim completion"
GH_PRIVATE=false GH_FAIL_MATCH=vulnerability-alerts GH_FAIL_RC=23 \
    run_case --repo owner/failing
[ "$run_rc" -eq 23 ] || fail "API exit 23 became $run_rc"
grep -Fq '[ ] Dependabot alerts - GitHub API request failed (exit 23)' "$tmp/out" || fail "missing formatted failure"
if grep -q 'DONE:' "$tmp/out"; then fail "failed run printed a completion summary"; fi
if grep -q 'private-vulnerability-reporting' "$stub_calls"; then
    fail "script continued mutating after the first failure"
fi

echo "PASS: setup-github outcomes and failure propagation"
