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
*"collaborators/"*" --method PUT"*) printf '%s' "${GH_COLLAB_RESPONSE:-}" ;;
*"variable list --repo "*" --json name,value --jq "*)
    [ "${GH_VARIABLE_GET_RC:-0}" -eq 0 ] || exit "$GH_VARIABLE_GET_RC"
    printf '%s\n' "${GH_VARIABLE_VALUE:-}"
    ;;
*"/permission --jq .permission")
    [ -n "${GH_PERMISSION:-}" ] || exit 1
    printf '%s\n' "$GH_PERMISSION"
    ;;
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

desired='["self-hosted","linux","x64","owner"]'

echo "==> missing private CI_RUNS_ON variables are created"
GH_PRIVATE=true GH_VARIABLE_VALUE= run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "missing-variable path exited $run_rc"
grep -Fq '[x] Actions runner routing - created CI_RUNS_ON' "$tmp/out" || fail "missing created routing outcome"
grep -Fq "variable set CI_RUNS_ON --repo owner/private --body $desired" "$stub_calls" ||
    fail "missing CI_RUNS_ON variable was not created"

echo "==> matching private CI_RUNS_ON variables are unchanged"
GH_PRIVATE=true GH_VARIABLE_VALUE="$desired" run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "matching-variable path exited $run_rc"
grep -Fq '[x] Actions runner routing - CI_RUNS_ON already matches' "$tmp/out" || fail "missing matching routing outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "matching CI_RUNS_ON was rewritten"; fi

echo "==> stale self-hosted labels are standardized"
GH_PRIVATE=true GH_VARIABLE_VALUE='["self-hosted","linux"]' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "stale-variable path exited $run_rc"
grep -Fq '[x] Actions runner routing - standardized CI_RUNS_ON' "$tmp/out" || fail "missing standardized routing outcome"
grep -Fq "variable set CI_RUNS_ON --repo owner/private --body $desired" "$stub_calls" ||
    fail "stale self-hosted CI_RUNS_ON was not updated"

echo "==> explicit GitHub-hosted overrides are preserved"
GH_PRIVATE=true GH_VARIABLE_VALUE='"ubuntu-latest"' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "hosted-override path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved explicit GitHub-hosted' "$tmp/out" ||
    fail "missing preserved override outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "hosted override was rewritten"; fi

echo "==> GitHub-hosted runner arrays are preserved"
GH_PRIVATE=true GH_VARIABLE_VALUE='["ubuntu-latest"]' \
    run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 0 ] || fail "hosted-array path exited $run_rc"
grep -Fq '[-] Actions runner routing - preserved explicit GitHub-hosted' "$tmp/out" ||
    fail "missing preserved hosted-array outcome"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "hosted array was rewritten"; fi

echo "==> ambiguous scalar runner labels fail closed"
GH_PRIVATE=true GH_VARIABLE_VALUE='"self-hosted"' \
    run_case --repo owner/private --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 1 ] || fail "ambiguous-scalar path exited $run_rc"
grep -Fq '[ ] Actions runner routing - existing CI_RUNS_ON is not valid hosted or self-hosted JSON' "$tmp/out" ||
    fail "ambiguous scalar was not rejected"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "ambiguous scalar was rewritten"; fi

echo "==> switching a template to GitHub-hosted clears its stale self-hosted routing"
GH_PRIVATE=true GH_VARIABLE_VALUE="$desired" \
    run_case --repo owner/private --ci-runs-on '"ubuntu-latest"'
[ "$run_rc" -eq 0 ] || fail "hosted transition exited $run_rc"
grep -Fq 'variable set CI_RUNS_ON --repo owner/private --body "ubuntu-latest"' "$stub_calls" ||
    fail "stale self-hosted routing was not changed to GitHub-hosted"

echo "==> variable lookup failures stop before a write"
GH_PRIVATE=true GH_VARIABLE_GET_RC=23 run_case --repo owner/private --ci-runs-on "$desired"
[ "$run_rc" -eq 23 ] || fail "variable lookup exit 23 became $run_rc"
grep -Fq '[ ] Actions runner routing - could not list repository variables (exit 23)' "$tmp/out" ||
    fail "missing variable-lookup failure"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "lookup failure attempted a write"; fi

echo "==> malformed runner JSON is rejected before GitHub access"
GH_PRIVATE=true run_case --repo owner/private --ci-runs-on 'not-json "self-hosted"'
[ "$run_rc" -eq 2 ] || fail "malformed runner JSON exited $run_rc"
if [ -s "$stub_calls" ]; then fail "malformed runner JSON reached GitHub"; fi

echo "==> public repositories reject self-hosted routing"
GH_PRIVATE=false run_case --repo owner/public --ci-runs-on "$desired"
[ "$run_rc" -eq 1 ] || fail "public self-hosted path exited $run_rc"
grep -Fq '[ ] Actions runner routing - refusing self-hosted CI_RUNS_ON' "$tmp/out" ||
    fail "missing public-repo refusal"
if grep -q 'variable set CI_RUNS_ON' "$stub_calls"; then fail "public repo received self-hosted routing"; fi

echo "==> public repositories enable every requested setting and collaborator"
GH_PRIVATE=false GH_PERMISSION=write GH_VARIABLE_VALUE= \
    run_case --repo owner/public --ci-runs-on '"ubuntu-latest"' --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "public path exited $run_rc"
grep -Fq '[x] Private vulnerability reporting - enabled' "$tmp/out" || fail "missing reporting success"
grep -Fq '[x] Bot collaborator - owner-bot has write access' "$tmp/out" || fail "missing collaborator success"
grep -q 'private-vulnerability-reporting --method PUT' "$stub_calls" || fail "reporting API was not called"
grep -q 'collaborators/owner-bot --method PUT -f permission=push' "$stub_calls" || fail "collaborator API was not called"
grep -q 'collaborators/owner-bot/permission --jq .permission' "$stub_calls" || fail "collaborator access was not verified"
grep -Fq 'variable set CI_RUNS_ON --repo owner/public --body "ubuntu-latest"' "$stub_calls" ||
    fail "public repository did not receive explicit GitHub-hosted routing"

echo "==> a new collaborator invitation is reported as pending until accepted"
GH_PRIVATE=false GH_COLLAB_RESPONSE='{"id":42,"invitee":{"login":"owner-bot"}}' \
    run_case --repo owner/public --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "pending invitation path exited $run_rc"
grep -Fq '[?] Bot collaborator - invitation sent to owner-bot; access starts after acceptance' "$tmp/out" ||
    fail "missing pending-invitation outcome"
grep -Fq 'WARN: GitHub repository settings are ready; bot collaborator acceptance is pending' "$tmp/out" ||
    fail "missing pending-invitation summary"
if grep -q 'owner-bot has write access' "$tmp/out"; then
    fail "pending invitation falsely claimed active push access"
fi

echo "==> a failed permission lookup is unknown, never mislabeled as an invitation"
GH_PRIVATE=false GH_COLLAB_RESPONSE= GH_PERMISSION= \
    run_case --repo owner/public --bot-collaborator owner-bot
[ "$run_rc" -eq 0 ] || fail "unverified collaborator path exited $run_rc"
grep -Fq '[?] Bot collaborator - GitHub accepted the request, but permission verification failed' "$tmp/out" ||
    fail "missing unverified-permission outcome"
grep -Fq 'WARN: GitHub repository settings changed, but collaborator access needs verification' "$tmp/out" ||
    fail "missing unverified-permission summary"
if grep -q 'invitation sent' "$tmp/out"; then
    fail "permission lookup failure was mislabeled as a confirmed invitation"
fi

grep -Fq 'SUMMARY: Repository setup - succeeded=' "$tmp/out" ||
    fail "missing compact repository outcome summary"

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
