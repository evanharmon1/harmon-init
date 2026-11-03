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
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
# Every setup fixture must return before any gh call, including reads. This
# canary records an accidental call and cannot contact the real service.
cat >"$stub_bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$RULESET_TEST_GH_CALLS"
exit 99
EOF
chmod +x "$stub_bin/gh"
export PATH="$stub_bin:$PATH"
export RULESET_TEST_GH_CALLS="$tmp_dir/gh-calls"
# Do not inherit another invocation's optional simulated response.
unset RULESET_SETUP_LIVE_AFTER
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
jq '.rules = [{"type":"copilot_code_review"}]' "$file" >"$live"
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

echo "==> missing contexts preserve live identity fields, check objects and policy flags"
jq '.name = "Protect Main" | .target = "tag" | .enforcement = "evaluate"
    | .bypass_actors = [{"actor_id": 99, "actor_type": "Integration", "bypass_mode": "always"}]
    | .conditions = {ref_name: {include: ["refs/tags/release-*"], exclude: ["refs/tags/private-*"]}}
    | (.rules[] | select(.type == "required_status_checks") | .parameters)
      |= (.strict_required_status_checks_policy = false
          | .do_not_enforce_on_create = false
          | .required_status_checks |= (map(select(.context != "closing-keywords"))
             + [{"context":"locally-added-check","integration_id":12345}]))' "$file" >"$live"
out="$(run_setup --yes)" || fail "identity run exited non-zero"
diff <(jq -S '{name, target, enforcement, bypass_actors, conditions}' "$live") \
    <(jq -S '{name, target, enforcement, bypass_actors, conditions}' "$wrote") ||
    fail "payload replaced live identity fields with local values"
diff <(jq -S '[.rules[] | select(.type == "required_status_checks") | .parameters | del(.required_status_checks)]' "$live") \
    <(jq -S '[.rules[] | select(.type == "required_status_checks") | .parameters | del(.required_status_checks)]' "$wrote") ||
    fail "payload changed live status-check policy flags"
jq -e --slurpfile before "$live" '
  [.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] as $after
  | all($before[0].rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[];
      . as $check | $after | index($check) != null)
' "$wrote" >/dev/null || fail "payload changed an existing live check object"

echo "==> additions with an integration mismatch remain incomplete, including dry-run"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= (map(select(.context != "closing-keywords"))
        | map(if .context == "verify" then .integration_id = 99999 else . end))' "$file" >"$live"
for mode in --yes --dry-run; do
    if run_setup "$mode" >"$tmp_dir/out" 2>&1; then
        fail "$mode reported success despite an integration mismatch"
    else
        status=$?
        [ "$status" -eq 1 ] || fail "combined mismatch exit was $status, expected 1"
    fi
    grep -q 'RULESET SETUP MISMATCH' "$tmp_dir/out" || fail "combined mismatch not reported"
    if [ "$mode" = --yes ]; then
        [ -f "$wrote" ] || fail "combined mismatch did not apply safe additions"
        jq -e '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]
            | select(.context == "verify" and .integration_id == 99999)] | length == 1' "$wrote" >/dev/null ||
            fail "combined mismatch silently repaired an existing binding"
        live_contexts "$wrote" | grep -qx 'closing-keywords' || fail "combined mismatch lost the addition"
    else
        [ ! -f "$wrote" ] || fail "dry-run wrote despite a mismatch"
    fi
done

echo "==> accepted writes are verified against a fresh result, not just a successful request"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(select(.context != "closing-keywords"))' "$file" >"$live"
if RULESET_SETUP_LIVE_AFTER="$live" run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "accepted-but-unchanged result reported success"
else
    [ "$?" -eq 1 ] || fail "wrong exit for accepted-but-unchanged result"
fi
grep -q 'still does not require: closing-keywords' "$tmp_dir/out" || fail "missing outcome not reported"
if RULESET_SETUP_LIVE_AFTER="$file" run_setup --yes >"$tmp_dir/out" 2>&1; then
    grep -q 'RULESET SETUP APPLIED' "$tmp_dir/out" || fail "verified outcome not reported"
else
    fail "successful post-write result rejected: $(cat "$tmp_dir/out")"
fi
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]
    | select(.context == "closing-keywords") | .integration_id) = 99999' "$file" >"$tmp_dir/after.json"
if RULESET_SETUP_LIVE_AFTER="$tmp_dir/after.json" run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "same-name result from the wrong integration reported success"
else
    [ "$?" -eq 1 ] || fail "wrong exit for changed outcome integration"
fi
grep -q 'integration bindings changed' "$tmp_dir/out" || fail "wrong-integration outcome not reported"
printf 'invalid JSON\n' >"$tmp_dir/after.json"
if RULESET_SETUP_LIVE_AFTER="$tmp_dir/after.json" run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "malformed post-write result reported success"
else
    [ "$?" -eq 2 ] || fail "wrong exit for malformed post-write result"
fi
if RULESET_SETUP_LIVE_AFTER="$tmp_dir/absent.json" run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "unreadable post-write result reported success"
else
    [ "$?" -eq 2 ] || fail "wrong exit for unreadable post-write result"
fi

echo "==> absent, inherited-only and malformed ruleset lists are unavailable"
for listing in '[]' '[{"id":42,"name":"Protect Main","source_type":"Organization"}]' 'not JSON'; do
    printf '%s\n' "$listing" >"$list"
    if run_setup --yes >"$tmp_dir/out" 2>&1; then
        fail "unusable ruleset list accepted: $listing"
    else
        [ "$?" -eq 2 ] || fail "wrong exit for unusable ruleset list"
    fi
    [ ! -f "$wrote" ] || fail "unusable list still wrote"
done
printf '[{"id":42,"name":"Protect Main","source_type":"Repository"}]\n' >"$list"

echo "==> malformed live check arrays and missing identity fields cannot report clean"
for transform in '.rules = null' \
    '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = null' \
    'del(.conditions)' \
    '.rules += [.rules[] | select(.type == "required_status_checks")]'; do
    jq "$transform" "$file" >"$live"
    if run_setup --yes >"$tmp_dir/out" 2>&1; then
        fail "malformed live policy accepted: $transform"
    else
        [ "$?" -eq 2 ] || fail "wrong exit for malformed live policy"
    fi
    [ ! -f "$wrote" ] || fail "malformed policy still wrote"
done

echo "==> partial fixture configuration never falls through to gh"
for variable in RULESET_AUDIT_LIVE_LIST RULESET_AUDIT_LIVE_DETAIL RULESET_SETUP_WRITE_OUT RULESET_SETUP_LIVE_AFTER; do
    if env -u RULESET_AUDIT_LIVE_LIST -u RULESET_AUDIT_LIVE_DETAIL \
        -u RULESET_SETUP_WRITE_OUT -u RULESET_SETUP_LIVE_AFTER \
        RULESET_AUDIT_FILE="$file" "$variable=$file" \
        "$setup" --repo example/ruleset --yes >"$tmp_dir/out" 2>&1; then
        fail "partial fixture configuration accepted: $variable"
    else
        [ "$?" -eq 2 ] || fail "wrong exit for partial fixture configuration"
    fi
done

echo "==> confirmation re-reads every field the PUT could replace"
# PTY stdin exercises the real confirmation path. Mutate the fixture only once
# the prompt is visible, then confirm. No API or alternate write path is used.
python3 - "$setup" "$file" "$list" "$live" "$wrote" <<'PY'
import json
import os
import pathlib
import pty
import select
import subprocess
import sys
import time

setup, source, listing, live, wrote = sys.argv[1:]
original = json.loads(pathlib.Path(source).read_text())
for rule in original["rules"]:
    if rule["type"] == "required_status_checks":
        rule["parameters"]["required_status_checks"] = [
            check for check in rule["parameters"]["required_status_checks"]
            if check["context"] != "closing-keywords"
        ]
for field in (None, "rules", "name", "target", "enforcement", "bypass_actors", "conditions"):
    pathlib.Path(live).write_text(json.dumps(original))
    pathlib.Path(wrote).unlink(missing_ok=True)
    env = dict(os.environ, RULESET_AUDIT_FILE=source, RULESET_AUDIT_LIVE_LIST=listing,
               RULESET_AUDIT_LIVE_DETAIL=live, RULESET_SETUP_WRITE_OUT=wrote)
    master, slave = pty.openpty()
    with subprocess.Popen([setup, "--repo", "example/ruleset"], env=env,
                          stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        os.close(slave)
        output = b""
        deadline = time.monotonic() + 30
        while b"[y/N] " not in output:
            if time.monotonic() >= deadline:
                raise AssertionError(f"confirmation prompt timed out: {output!r}")
            if select.select([process.stdout], [], [], 1)[0]:
                part = os.read(process.stdout.fileno(), 4096)
                if not part:
                    raise AssertionError(f"exited before confirmation: {output!r}")
                output += part
        if field:
            changed = json.loads(json.dumps(original))
            if field == "rules":
                changed[field].append({"type": "required_signatures"})
            elif field == "bypass_actors":
                changed[field] = []
            elif field == "conditions":
                changed[field] = {"ref_name": {"include": ["refs/heads/release"], "exclude": []}}
            elif field == "enforcement":
                changed[field] = "evaluate"
            elif field == "target":
                changed[field] = "tag"
            else:
                changed[field] = "Changed while confirming"
            pathlib.Path(live).write_text(json.dumps(changed))
        os.write(master, b"yes\n")
        remaining, _ = process.communicate(timeout=30)
        output += remaining
        os.close(master)
        if field:
            assert process.returncode == 2, (field, process.returncode, output)
            assert b"changed while this was waiting" in output, (field, output)
            assert not pathlib.Path(wrote).exists(), field
        else:
            assert process.returncode == 0, (process.returncode, output)
            assert pathlib.Path(wrote).exists()
PY

echo "==> a broken payload is rejected before any write"
# Corrupt only the payload-building jq call. This exercises the pre-write
# invariant independently of the successful union cases above.
export RULESET_TEST_REAL_JQ
RULESET_TEST_REAL_JQ="$(command -v jq)"
cat >"$stub_bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
*'bypass_actors, conditions, rules:'*)
    "$RULESET_TEST_REAL_JQ" "$@" | "$RULESET_TEST_REAL_JQ" '
      (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
      |= map(select(.context != "closing-keywords"))'
    ;;
*) exec "$RULESET_TEST_REAL_JQ" "$@" ;;
esac
EOF
chmod +x "$stub_bin/jq"
"$RULESET_TEST_REAL_JQ" '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(select(.context != "closing-keywords"))' "$file" >"$live"
if run_setup --yes >"$tmp_dir/out" 2>&1; then
    fail "payload missing an expected context was accepted"
else
    [ "$?" -eq 1 ] || fail "wrong exit for an incomplete payload"
fi
grep -q 'payload would not require: closing-keywords' "$tmp_dir/out" || fail "pre-write invariant did not reject the broken payload"
[ ! -f "$wrote" ] || fail "incomplete payload reached the write"
rm "$stub_bin/jq"

[ ! -f "$RULESET_TEST_GH_CALLS" ] || fail "fixture path invoked gh: $(cat "$RULESET_TEST_GH_CALLS")"
echo "setup-ruleset: all cases passed"
