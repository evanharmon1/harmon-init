#!/usr/bin/env bash
# test-setup-github-issue-fields.sh — unit-test setup-github-issue-fields.sh's
# field creation against a stubbed `gh`; no live API calls, so it is safe in CI.
# Run via `task test:setup-github-issue-fields`.
#
# What makes a test worth having here: this hits a public-preview REST API, so
# nothing else exercises it — a regression that recreated a retired field
# (Agent, Domain, Layer — #662, #875) or warned on the wrong condition would
# still pass `verify`.
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/setup-github-issue-fields.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    [ -f "$tmp/out" ] && sed 's/^/    /' "$tmp/out" >&2
    exit 1
}

# Fake `gh`: serves $STUB_FIELDS_FILE for reads, records write bodies.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
method=""
prev=""
for a in "$@"; do
    [ "$prev" = "--method" ] && method="$a"
    prev="$a"
done
case "$method" in
"") cat "$STUB_FIELDS_FILE" ;;
POST)
    cat >>"$POSTS"
    printf '\n' >>"$POSTS"
    ;;
*)
    echo "fake gh: unexpected method $method" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
export PATH

STUB_FIELDS_FILE="$tmp/fields.json"
POSTS="$tmp/posts"
export STUB_FIELDS_FILE POSTS

# run_with FIELDS_JSON — run the script against that org snapshot.
run_with() {
    printf '%s' "$1" >"$STUB_FIELDS_FILE"
    : >"$POSTS"
    "$script" --org testorg >"$tmp/out" 2>&1 || fail "script exited non-zero"
}

# Every field present. Deliberately no Agent, Domain, or Layer field: all
# three are retired (advisory routing is suggest:*/claim:* labels + Status:
# Agent Queue for Agent, ADR 0005 D4; Domain/Layer's only surface is the
# domain:/layer: labels, #875).
complete='[
 {"id":1,"name":"Product","data_type":"text"}
]'

echo "==> a re-run against an already-synced org writes nothing"
run_with "$complete"
[ ! -s "$POSTS" ] || fail "expected no field creation on an unchanged org"
grep -q "already exists — leaving it as-is" "$tmp/out" || fail "expected 'leaving it as-is' output for Product"
grep -q "DONE: GitHub issue fields are ready" "$tmp/out" || fail "expected an explicit ready outcome"

echo "==> the retired Agent field is never created"
grep -q '"name":"Agent"' "$POSTS" &&
    fail "the retired Agent field was created — routing lives in suggest:*/claim:* labels"

echo "==> Domain and Layer are never created"
case "$(cat "$POSTS")" in
*'"name":"Domain"'* | *'"name":"Layer"'*)
    fail "a retired Domain/Layer issue field was created — their only surface is domain:/layer: labels (#875)"
    ;;
esac

echo "==> a missing Product field is created"
run_with '[]'
[ -s "$POSTS" ] || fail "expected a field creation when Product is missing"
grep -q '"name":"Product"' "$POSTS" || fail "expected the POST body to name Product"
grep -q '"data_type":"text"' "$POSTS" || fail "expected Product to be created as text"

echo "==> a field of the wrong data type is warned about, never recreated"
wrong='[{"id":1,"name":"Product","data_type":"single_select"}]'
run_with "$wrong"
[ ! -s "$POSTS" ] || fail "a wrong-typed field must not be recreated"
grep -q "already exists as 'single_select', not 'text'" "$tmp/out" ||
    fail "expected a data-type warning for Product"
grep -q "Done, WITH WARNINGS" "$tmp/out" || fail "expected the run to end with warnings"
grep -q "WARN: GitHub issue fields need attention" "$tmp/out" || fail "expected a warning final outcome"
! grep -q "DONE: GitHub issue fields are ready" "$tmp/out" || fail "incompatible fields claimed readiness"

echo "PASS: setup-github-issue-fields.sh field creation"
