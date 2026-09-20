#!/usr/bin/env bash
# Hermetic tests for setup-ruleset.sh. No network: the live listing, the live
# ruleset, and the write are all fixtures.
set -euo pipefail

cd "$(dirname "$0")/.."
setup="$(pwd)/scripts/setup-ruleset.sh"
tmp_dir="$(mktemp -d -t harmon-init-test-ruleset-setup-XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT

file="$tmp_dir/file.json"
list="$tmp_dir/list.json"
live="$tmp_dir/live.json"
wrote="$tmp_dir/wrote.json"
cp ".github/Branch Protection Ruleset - Protect Main.json" "$file"
printf '[{"id":42,"name":"Protect Main","source_type":"Repository"}]\n' >"$list"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_setup() {
    rm -f "$wrote"
    RULESET_AUDIT_FILE="$file" RULESET_AUDIT_LIVE_LIST="$list" \
        RULESET_AUDIT_LIVE_DETAIL="$live" RULESET_SETUP_WRITE_OUT="$wrote" \
        "$setup" --repo example/ruleset "$@"
}

# The contexts the live ruleset requires, as a sorted newline list.
live_contexts() {
    jq -r '[ .rules[]? | select(.type=="required_status_checks")
             | .parameters.required_status_checks[]?.context ] | sort | .[]' "$1"
}

echo "==> an in-sync ruleset writes nothing"
cp "$file" "$live"
out="$(run_setup --yes)" || fail "in-sync run exited non-zero"
grep -q 'RULESET SETUP CLEAN' <<<"$out" || fail "in-sync run did not report clean: $out"
[ ! -f "$wrote" ] || fail "in-sync run performed a write"

echo "==> a missing context is added, and only that one"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(select(.context != "closing-keywords"))' "$file" >"$live"
out="$(run_setup --yes)" || fail "missing-context run exited non-zero"
grep -q '+ closing-keywords' <<<"$out" || fail "did not name the missing context: $out"
[ -f "$wrote" ] || fail "missing-context run wrote nothing"
diff <(live_contexts "$wrote") <(live_contexts "$file") ||
    fail "payload contexts do not match the checked-in ruleset"

echo "==> the payload preserves live's other rules verbatim"
jq -e '.rules | map(select(.type != "required_status_checks")) | length > 0' "$wrote" >/dev/null ||
    fail "payload dropped live's non-status-check rules"
diff \
    <(jq -S '[.rules[] | select(.type != "required_status_checks")]' "$live") \
    <(jq -S '[.rules[] | select(.type != "required_status_checks")]' "$wrote") ||
    fail "payload mutated a rule other than required_status_checks"

echo "==> an extra live context is reported and NEVER removed"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    += [{"context":"locally-added-check","integration_id":1}]' "$file" >"$live"
out="$(run_setup --yes)" || fail "extra-context run exited non-zero"
grep -q 'locally-added-check' <<<"$out" || fail "did not report the extra context: $out"
grep -q 'RULESET SETUP CLEAN' <<<"$out" || fail "extra context should still be in sync: $out"
[ ! -f "$wrote" ] || fail "extra context triggered a write"

echo "==> --dry-run never writes"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(select(.context != "closing-keywords"))' "$file" >"$live"
out="$(run_setup --dry-run)" || fail "--dry-run exited non-zero"
grep -q '+ closing-keywords' <<<"$out" || fail "--dry-run did not name the addition: $out"
[ ! -f "$wrote" ] || fail "--dry-run performed a write"

echo "==> refuses to change a merge gate non-interactively without --yes"
if run_setup </dev/null >"$tmp_dir/out" 2>&1; then
    fail "non-interactive run without --yes was allowed"
fi
grep -q 'refusing to change a merge gate' "$tmp_dir/out" ||
    fail "wrong refusal for a non-interactive run: $(cat "$tmp_dir/out")"
[ ! -f "$wrote" ] || fail "refused run still wrote"

echo "==> a ruleset that is not live exactly once is unavailable, not a guess"
printf '[{"id":1,"name":"Protect Main","source_type":"Repository"},{"id":2,"name":"Protect Main","source_type":"Repository"}]\n' >"$list"
if run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "duplicate rulesets were not refused"
else
    status=$?
    [ "$status" -eq 2 ] || fail "duplicate-ruleset exit was $status, expected 2"
fi
grep -q 'not found exactly once' "$tmp_dir/out" || fail "wrong duplicate-ruleset message"
printf '[{"id":42,"name":"Protect Main","source_type":"Repository"}]\n' >"$list"

echo "==> a live ruleset with NO required_status_checks rule gets one CREATED"
# Observed shape: a real repository whose only branch rule was copilot_code_review.
# Appending to a rule that is not there is a no-op, so the payload would equal
# live and the script would report APPLIED having changed nothing.
jq '{name, target, enforcement, rules: [{"type":"copilot_code_review"}]}' "$file" >"$live"
out="$(run_setup --yes)" || fail "absent-rule run exited non-zero"
[ -f "$wrote" ] || fail "absent-rule run wrote nothing"
jq -e '[.rules[] | select(.type=="required_status_checks")] | length == 1' "$wrote" >/dev/null ||
    fail "payload did not create exactly one required_status_checks rule"
diff <(live_contexts "$wrote") <(live_contexts "$file") ||
    fail "created rule does not require every checked-in context"
jq -e '[.rules[] | select(.type=="copilot_code_review")] | length == 1' "$wrote" >/dev/null ||
    fail "creating the rule dropped live's other rules"
# The rule's policy flags must come from the checked-in file, not be invented.
diff \
    <(jq -S '[.rules[] | select(.type=="required_status_checks") | .parameters | del(.required_status_checks)]' "$file") \
    <(jq -S '[.rules[] | select(.type=="required_status_checks") | .parameters | del(.required_status_checks)]' "$wrote") ||
    fail "created rule did not take its parameters from the checked-in ruleset"

echo "==> a same-context/different-integration entry is reported, not called clean"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(if .context == "closing-keywords" then .integration_id = 99999 else . end)' "$file" >"$live"
if run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "an integration_id mismatch was reported as success"
else
    status=$?
    [ "$status" -eq 1 ] || fail "mismatch exit was $status, expected 1"
fi
grep -q 'RULESET SETUP MISMATCH' "$tmp_dir/out" || fail "mismatch not reported: $(cat "$tmp_dir/out")"
grep -q 'closing-keywords' "$tmp_dir/out" || fail "mismatch did not name the context"
[ ! -f "$wrote" ] || fail "mismatch triggered a write"

echo "==> the payload is proven to carry every expected context before sending"
# Union semantics: live's own extra context must survive into the payload
# alongside the added one, or the write would silently drop a required check.
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= (map(select(.context != "closing-keywords")) + [{"context":"locally-added-check","integration_id":1}])' "$file" >"$live"
out="$(run_setup --yes)" || fail "union run exited non-zero"
live_contexts "$wrote" | grep -qx 'closing-keywords' || fail "payload lost the added context"
live_contexts "$wrote" | grep -qx 'locally-added-check' || fail "payload dropped live's own required check"

echo "setup-ruleset: all cases passed"
