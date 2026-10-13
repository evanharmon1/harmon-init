#!/usr/bin/env bash
# Test web identity setup with stubbed tools: no real secrets or Claude session.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

cat >"${test_tmp}/op" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: >"${TEST_LOG_DIR}/op-started"
[ "$#" -eq 2 ] && [ "$1" = read ] && [ "$2" = 'op://test-vault/test-item/token' ] || exit 99
case "$TEST_READ_MODE" in
fail) exit 1 ;;
empty) exit 0 ;;
success) printf '%s\n' 'stub-web-identity-canary' ;;
*) exit 99 ;;
esac
STUB
cat >"${test_tmp}/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: >"${TEST_LOG_DIR}/claude-started"
[ "$#" -eq 0 ] || exit 99
[ -z "${TEST_TOKEN+x}" ] || exit 99
[ -z "${token+x}" ] || exit 99
[ "${GH_TOKEN:-}" = 'stub-web-identity-canary' ] || exit 99
[ -z "$(ls -A)" ] || exit 99
pwd -P >"${TEST_LOG_DIR}/claude-directory"
exit "${TEST_CLAUDE_RC:-0}"
STUB
chmod +x "${test_tmp}/op" "${test_tmp}/claude"
export OP_BIN="${test_tmp}/op" CLAUDE_BIN="${test_tmp}/claude"
export TEST_LOG_DIR="$test_tmp"
unset TEST_TOKEN
TEST_TOKEN='stub-web-identity-canary'

run_setup() {
    rm -f "${test_tmp}/op-started" "${test_tmp}/claude-started" "${test_tmp}/claude-directory"
    rc=0
    [ "$#" -gt 0 ] || set -- bash
    "$@" "${repo}/scripts/web-identity.sh" >"${test_tmp}/output" 2>&1 || rc=$?
    if grep -Fq "$TEST_TOKEN" "${test_tmp}/output"; then
        fail "script output contains the token"
    fi
}

echo "==> an unset reference refuses before reading a secret or starting Claude"
unset WEB_SETUP_TOKEN_REF
export TEST_READ_MODE=success
run_setup
[ "$rc" -ne 0 ] || fail "an unset reference must fail"
[ ! -e "${test_tmp}/op-started" ] || fail "an unset reference started op"
[ ! -e "${test_tmp}/claude-started" ] || fail "an unset reference started Claude"
grep -Fq 'Usage: WEB_SETUP_TOKEN_REF=' "${test_tmp}/output" || fail "missing usage message"

export WEB_SETUP_TOKEN_REF='op://test-vault/test-item/token'
for TEST_READ_MODE in fail empty; do
    echo "==> a $TEST_READ_MODE secret read refuses before starting Claude"
    export TEST_READ_MODE
    run_setup
    [ "$rc" -ne 0 ] || fail "$TEST_READ_MODE read must fail"
    [ -e "${test_tmp}/op-started" ] || fail "$TEST_READ_MODE read never ran"
    [ ! -e "${test_tmp}/claude-started" ] || fail "$TEST_READ_MODE read started Claude"
done

export TEST_READ_MODE=success
for TEST_CLAUDE_RC in 0 7; do
    echo "==> Claude receives GH_TOKEN without arguments; its empty directory is cleaned up"
    export TEST_CLAUDE_RC
    run_setup
    [ "$rc" -eq "$TEST_CLAUDE_RC" ] || fail "Claude did not receive the token without arguments, or its exit status changed"
    [ -e "${test_tmp}/claude-started" ] || fail "Claude never started"
    setup_dir="$(cat "${test_tmp}/claude-directory")"
    [ ! -e "$setup_dir" ] || fail "Claude's directory still exists"
    grep -Fq 'Connected as evanharmon1-bot' "${test_tmp}/output" || fail "missing expected identity"
done

export TEST_CLAUDE_RC=0
for trace_mode in inherited explicit; do
    echo "==> $trace_mode tracing never prints the token"
    if [ "$trace_mode" = inherited ]; then
        run_setup env SHELLOPTS=xtrace bash
    else
        run_setup bash -x
    fi
    [ "$rc" -eq 0 ] || fail "$trace_mode traced run failed"
    [ -e "${test_tmp}/claude-started" ] || fail "$trace_mode traced run never started Claude"
done

echo "==> an inherited token export does not carry the secret to Claude"
export token=ambient-value
run_setup
[ "$rc" -eq 0 ] || fail "an inherited token export reached Claude"
[ -e "${test_tmp}/claude-started" ] || fail "exported-token run never started Claude"
unset token

echo "==> inherited allexport does not carry the secret in a token variable"
run_setup env SHELLOPTS=allexport bash
[ "$rc" -eq 0 ] || fail "inherited allexport exported the token to Claude"
[ -e "${test_tmp}/claude-started" ] || fail "allexport run never started Claude"

echo "==> TMPDIR inside a Git work tree does not determine Claude's directory"
mkdir -p "${test_tmp}/checkout/tmp"
git -c init.templateDir= init -q "${test_tmp}/checkout"
run_setup env TMPDIR="${test_tmp}/checkout/tmp" bash
[ "$rc" -eq 0 ] || fail "TMPDIR placed Claude inside a work tree"
[ -e "${test_tmp}/claude-started" ] || fail "TMPDIR run never started Claude"
setup_dir="$(cat "${test_tmp}/claude-directory")"
tmp_real="$(cd /tmp && pwd -P)"
case "$setup_dir" in
"$tmp_real"/web-identity.*) ;;
*) fail "Claude's directory was not under the fixed absolute base" ;;
esac
[ ! -e "$setup_dir" ] || fail "TMPDIR run left Claude's directory behind"

echo "==> setup:web-identity stays interactive through Task's global output grouping"
# The root Taskfile sets `output: group`, so Task pipes each task's stdout; without
# `interactive: true` the claude TUI would be buffered. scripts/test-tasks.sh pins
# the same key for tasks both twins share; this task is root-only, so it is pinned
# here. A whole-line directive, never a substring of a comment.
block="$(awk '$0 == "  setup:web-identity:" { inblock = 1; next }
    inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
    inblock { print }' "${repo}/Taskfile.yml")"
[ -n "$block" ] || fail "Taskfile.yml: task setup:web-identity not found"
printf '%s\n' "$block" | grep -vE '^[[:space:]]*#' |
    grep -qE '^[[:space:]]*interactive:[[:space:]]*true[[:space:]]*$' ||
    fail "Taskfile.yml: setup:web-identity lacks 'interactive: true'"

echo "test-web-identity.sh passed"
