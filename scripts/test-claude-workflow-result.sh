#!/usr/bin/env bash
# Offline fixtures; GH writes are captured by a stub.
set -euo pipefail
cd "$(dirname "$0")/.."
guard=${CLAUDE_RESULT_SCRIPT:-"$PWD/scripts/claude-workflow-result.sh"}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$COMMENT_CAPTURE"
STUB
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
export COMMENT_CAPTURE="$scratch/comment"
export GH_REPO=owner/repo TARGET=42
export GH_TOKEN=ghp_testcredential REDACT_PRIMARY=sk-ant-primary REDACT_ALT=sk-ant-alternate
export REDACT_APP_TOKEN=ghp_testgithub
export GITHUB_OUTPUT="$scratch/output" EXECUTION_FILE="$scratch/execution.json"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

run() {
    expected_retry=$1
    expected_failed=$2
    export ACTION_OUTCOME=$3 HAS_ALT=$4
    : >"$GITHUB_OUTPUT"
    rm -f "$COMMENT_CAPTURE"
    "$guard" >"$scratch/log"
    [ "$(cat "$GITHUB_OUTPUT")" = "$(printf 'retry=%s\nfailed=%s' "$expected_retry" "$expected_failed")" ] ||
        fail "retry=$expected_retry failed=$expected_failed expected for $ACTION_OUTCOME / $HAS_ALT"
    if [ "$expected_failed" = true ]; then
        [ -s "$COMMENT_CAPTURE" ] || fail 'failure comment missing'
        [ -s "$scratch/log" ] || fail 'failure log missing'
    else
        [ ! -e "$COMMENT_CAPTURE" ] || fail 'success must not post a failure'
    fi
}

fixture() {
    printf '[{"type":"result","result":"OAuth token expired","subtype":"%s","is_error":%s,"total_cost_usd":%s,"modelUsage":%s}]\n' \
        "$1" "$2" "$3" "$4" >"$EXECUTION_FILE"
}

fixture success true 0 '{}'
run true true failure true
grep -q 'OAuth token expired' "$scratch/log" || fail 'result text missing'
for field in subtype is_error total_cost_usd modelUsage; do
    grep -q "$field" "$COMMENT_CAPTURE" || fail "$field missing from comment"
done
run false true failure false
fixture success false 0 '{}'
run false false success true
# A successful step must never retry even if its execution result is erroneous.
fixture success true 0 '{}'
run false true success true
fixture error true 1 '{}'
run false true failure true
fixture error true 0 '{"opus":{"inputTokens":1}}'
run false true failure true
fixture error true 0 null
run false true failure true
printf '[{"type":"result","is_error":true,"modelUsage":{}}]' >"$EXECUTION_FILE"
run false true failure true
# Only the last result controls the decision.
printf '[{"type":"result","is_error":true,"total_cost_usd":0,"modelUsage":{}},{"type":"result","subtype":"success","is_error":false}]' >"$EXECUTION_FILE"
run false false success true
printf '{broken' >"$EXECUTION_FILE"
run false true failure true
printf '[] []' >"$EXECUTION_FILE"
run false true failure true
printf '{"type":"result","is_error":true,"total_cost_usd":0,"modelUsage":{}}' >"$EXECUTION_FILE"
run false true failure true
printf '[{"type":"system"}]' >"$EXECUTION_FILE"
run false true failure true
rm "$EXECUTION_FILE"
run false true failure true
# Credential values, token patterns, and review mentions never leave the script.
fixture error true 0 '{}'
jq '.[0].result = "sk-ant-primary sk-ant-alternate ghp_testcredential ghp_testgithub sk-ant-unknown \u0040codex ``` ::error::injected"' \
    "$EXECUTION_FILE" >"$scratch/redacted.json"
mv "$scratch/redacted.json" "$EXECUTION_FILE"
run true true failure true
# Prove the detector matches the raw input, and require grep's no-match status.
grep -qiE 'sk-ant-|ghp_|@co[d]ex' "$EXECUTION_FILE" || fail 'leak detector did not match fixture'
leak_status=0
grep -qiE 'sk-ant-|ghp_|@co[d]ex' "$scratch/log" "$COMMENT_CAPTURE" || leak_status=$?
[ "$leak_status" = 1 ] || fail 'credential or review mention leaked, or grep failed'
grep -q '\[REDACTED\]' "$COMMENT_CAPTURE" || fail 'redaction absent'
# Finalization restores the red job after continue-on-error, including missing data.
LAST_OUTCOME=success LAST_FAILED=false "$guard" finish || fail 'successful final attempt failed'
for outcome in failure cancelled skipped ''; do
    if LAST_OUTCOME="$outcome" LAST_FAILED=false "$guard" finish; then
        fail 'failed final action passed'
    fi
done
if LAST_OUTCOME=success LAST_FAILED=true "$guard" finish; then
    fail 'error result passed finalization'
fi
if LAST_OUTCOME=success LAST_FAILED='' "$guard" finish; then
    fail 'missing inspection passed finalization'
fi
# Retiring the primary output leaves the next inspection with no stale result.
fixture success true 0 '{}'
ARCHIVE_EXECUTION=true run true true failure true
[ ! -f "$EXECUTION_FILE" ] || fail 'primary execution file was not retired'
[ -f "$EXECUTION_FILE.primary" ] || fail 'archived primary file missing'
run false true failure true
grep -q 'Execution file missing' "$scratch/log" || fail 'alternate reported stale primary result'

# Local branch cleanup returns to the starting commit, never a remote branch.
export RUNNER_TEMP="$scratch" DEFAULT_BRANCH=main
mkdir "$scratch/repo"
(
    cd "$scratch/repo"
    git init -q
    git config user.name 'Fixture'
    git config user.email 'fixture@example.invalid'
    git checkout -q -b main
    git commit -q --allow-empty -m initial
    git rev-parse HEAD >"$RUNNER_TEMP/claude-start-commit"
    git checkout -q -b claude/fixture
    git update-ref refs/remotes/origin/claude/fixture HEAD
    PRIMARY_BRANCH=claude/fixture "$guard" cleanup >/dev/null 2>&1
    if git show-ref --verify --quiet refs/heads/claude/fixture; then
        fail 'local Claude branch survived'
    fi
    [ "$(git rev-parse HEAD)" = "$(cat "$RUNNER_TEMP/claude-start-commit")" ] || fail 'starting commit not restored'
    git show-ref --verify --quiet refs/remotes/origin/claude/fixture || fail 'remote ref was changed'
    PRIMARY_BRANCH=claude/absent "$guard" cleanup || fail 'absent branch should be inert'
    git checkout -q -b unrelated
    if PRIMARY_BRANCH=unrelated "$guard" cleanup >/dev/null 2>&1; then
        fail 'unrelated branch accepted for cleanup'
    fi
    git show-ref --verify --quiet refs/heads/unrelated || fail 'unrelated branch removed'
    git checkout -q -b claude/default
    if DEFAULT_BRANCH=claude/default PRIMARY_BRANCH=claude/default "$guard" cleanup >/dev/null 2>&1; then
        fail 'default branch accepted for cleanup'
    fi
    # The fallback to the current branch is safe when no action output exists.
    PRIMARY_BRANCH='' "$guard" cleanup >/dev/null 2>&1
    if git show-ref --verify --quiet refs/heads/claude/default; then
        fail 'current Claude branch survived fallback cleanup'
    fi
) || fail 'cleanup fixture failed'
echo 'Claude workflow result: all cases passed'
