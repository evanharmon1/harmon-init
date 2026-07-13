#!/usr/bin/env bash
# mock.sh — canned-diff test adapter. Exists to prove the backend seam and to
# make foreman's own end-to-end paths exercisable without a vendor CLI,
# network, or spend. Never dispatch real work at it.
#
# Knobs (env):
#   FOREMAN_MOCK_STATUS=completed|blocked|fail   default: completed
#   FOREMAN_MOCK_FILE=<relative path>            default: MOCK.md
set -euo pipefail

cmd="${1:-run}"
case "$cmd" in
capabilities)
    echo "cost"
    exit 0
    ;;
run | resume) ;;
*)
    echo "mock.sh: unknown command: $cmd" >&2
    exit 1
    ;;
esac

: "${FOREMAN_RESULT_FILE:?}" "${FOREMAN_SESSION_FILE:?}" "${FOREMAN_LOG_FILE:?}"

echo "SESSION_REF=mock-$$" >>"$FOREMAN_SESSION_FILE"
echo "mock adapter: cwd=$(pwd) cmd=$cmd status=${FOREMAN_MOCK_STATUS:-completed}" >>"$FOREMAN_LOG_FILE"

if [ "${FOREMAN_READONLY:-0}" = "1" ]; then
    cat <<'FINDINGS'
# Mock preflight findings

No real analysis — this is the seam-proof adapter.

## DRAFT COMMENT FOR #0

Mock drafted correction (delete me; unit #0 never exists).
FINDINGS
    exit 0
fi

status="${FOREMAN_MOCK_STATUS:-completed}"
case "$status" in
fail)
    echo "mock adapter: simulated agent failure" >>"$FOREMAN_LOG_FILE"
    exit 1
    ;;
blocked)
    cat >"$FOREMAN_RESULT_FILE" <<'JSON'
{
  "schema": 1,
  "status": "blocked",
  "blocked_question": "Mock question: which behavior is intended?"
}
JSON
    echo "COST_USD=0.00" >>"$FOREMAN_SESSION_FILE"
    exit 2
    ;;
esac

target="${FOREMAN_MOCK_FILE:-MOCK.md}"
{
    echo "# Mock change"
    echo
    echo "Applied by the foreman mock backend adapter."
} >"$target"
git add "$target"
# LEFTHOOK=0 is lefthook's sanctioned skip switch for automation; the mock
# adapter's commits are throwaway seam proofs, not repo changes.
LEFTHOOK=0 git -c user.name="foreman-mock" -c user.email="mock@example.invalid" \
    commit -q -m "chore: mock change (foreman mock backend)"
cat >"$FOREMAN_RESULT_FILE" <<'JSON'
{
  "schema": 1,
  "status": "completed",
  "summary": "Mock backend applied a canned change.",
  "handoff": "Nothing downstream depends on this mock change.",
  "human_tasks": [],
  "proposed_pr_title": "chore: mock change",
  "ac_test_map": [
    { "criterion": "mock criterion [CI]", "tests": ["mock_test"] }
  ]
}
JSON
echo "COST_USD=0.00" >>"$FOREMAN_SESSION_FILE"
