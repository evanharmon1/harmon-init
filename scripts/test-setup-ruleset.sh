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
checks="$tmp_dir/check-runs.json"
statuses="$tmp_dir/statuses.json"
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
unset RULESET_SETUP_CHECK_RUNS RULESET_SETUP_STATUSES
cp ".github/Branch Protection Ruleset - Protect Main.json" "$file"
jq '{check_runs: [.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[] | {name: .context, app: {id: .integration_id}}]}' "$file" >"$checks"
printf '[]\n' >"$statuses"
printf '[{"id":42,"name":"Protect Main","source_type":"Repository"}]\n' >"$list"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_setup() {
    rm -f "$wrote"
    RULESET_AUDIT_FILE="$file" RULESET_AUDIT_LIVE_LIST="$list" \
        RULESET_AUDIT_LIVE_DETAIL="$live" RULESET_SETUP_WRITE_OUT="$wrote" \
        RULESET_SETUP_CHECK_RUNS="${RULESET_SETUP_CHECK_RUNS:-$checks}" \
        RULESET_SETUP_STATUSES="${RULESET_SETUP_STATUSES:-$statuses}" \
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
grep -q 'after-state differs from the update payload' "$tmp_dir/out" || fail "missing outcome not reported"
grep -q 'closing-keywords' "$tmp_dir/out" || fail "outcome diff did not name the missing check"
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
grep -q 'after-state differs from the update payload' "$tmp_dir/out" || fail "wrong-integration outcome not reported"
grep -q 'integration_id' "$tmp_dir/out" || fail "outcome diff did not name the changed binding"
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
for variable in RULESET_AUDIT_LIVE_LIST RULESET_AUDIT_LIVE_DETAIL RULESET_SETUP_WRITE_OUT RULESET_SETUP_LIVE_AFTER RULESET_SETUP_CHECK_RUNS RULESET_SETUP_STATUSES; do
    if env -u RULESET_AUDIT_LIVE_LIST -u RULESET_AUDIT_LIVE_DETAIL \
        -u RULESET_SETUP_WRITE_OUT -u RULESET_SETUP_LIVE_AFTER -u RULESET_SETUP_CHECK_RUNS -u RULESET_SETUP_STATUSES \
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
python3 - "$setup" "$file" "$list" "$live" "$wrote" "$checks" <<'PY'
import json
import os
import pathlib
import pty
import select
import subprocess
import sys
import time

setup, source, listing, live, wrote, checks = sys.argv[1:]
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
               RULESET_AUDIT_LIVE_DETAIL=live, RULESET_SETUP_WRITE_OUT=wrote,
               RULESET_SETUP_CHECK_RUNS=checks)
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

echo "==> every writable after-state field and rule must match the sent payload"
run_setup --yes >"$tmp_dir/out" 2>&1 || fail "could not establish the expected payload"
cp "$wrote" "$tmp_dir/expected-payload.json"
for transform in '.name = "Changed name"' '.target = "tag"' '.enforcement = "disabled"' \
    '.bypass_actors = []' '.conditions.ref_name.include = ["refs/heads/release"]' \
    '.rules |= map(select(.type != "deletion"))' \
    '.rules += [{"type":"required_signatures"}]' \
    '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 0' \
    '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = false'; do
    jq "$transform" "$tmp_dir/expected-payload.json" >"$tmp_dir/after.json"
    if RULESET_SETUP_LIVE_AFTER="$tmp_dir/after.json" run_setup --yes >"$tmp_dir/out" 2>&1; then
        fail "changed after-state was accepted: $transform"
    else
        [ "$?" -eq 1 ] || fail "wrong exit for changed after-state: $transform"
    fi
    grep -q 'after-state differs from the update payload' "$tmp_dir/out" || fail "after-state diff not reported"
    grep -q '^[-+]' "$tmp_dir/out" || fail "changed fields were not shown"
    if grep -q 'RULESET SETUP APPLIED' "$tmp_dir/out"; then
        fail "changed after-state still claimed APPLIED"
    fi
done

echo "==> one normalization permits server metadata, rule order and the disabled dismissal default"
jq '.id = 42 | .updated_at = "2026-11-03T00:00:00Z" | .rules |= reverse
    | (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= reverse
    | (.rules[] | select(.type == "pull_request") | .parameters.dismissal_restriction)
      = {"enabled":false,"allowed_actors":[]}' "$tmp_dir/expected-payload.json" >"$tmp_dir/after.json"
RULESET_SETUP_LIVE_AFTER="$tmp_dir/after.json" run_setup --yes >"$tmp_dir/out" 2>&1 || fail "normalized equivalent after-state rejected"

echo "==> APPLIED states the enforcement mode and explains inactive enforcement"
for mode in active evaluate disabled; do
    jq --arg mode "$mode" '.enforcement = $mode
      | (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
        |= map(select(.context != "closing-keywords"))' "$file" >"$live"
    run_setup --yes >"$tmp_dir/out" 2>&1 || fail "enforcement mode $mode rejected"
    grep -q "enforcement: $mode" "$tmp_dir/out" || fail "enforcement mode not reported"
    if [ "$mode" = active ]; then
        if grep -q 'configured but not enforced' "$tmp_dir/out"; then
            fail "active enforcement was described as inactive"
        fi
    else
        grep -q 'configured but not enforced' "$tmp_dir/out" || fail "inactive enforcement not explained"
    fi
done

echo "==> unreported or wrong-app additions refuse, including dry-run, unless explicitly overridden"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(select(.context != "closing-keywords"))' "$file" >"$live"
for transform in '.check_runs |= map(select(.name != "closing-keywords"))' \
    '(.check_runs[] | select(.name == "closing-keywords") | .app.id) = 99999'; do
    jq "$transform" "$checks" >"$tmp_dir/unreported.json"
    for mode in --yes --dry-run; do
        if RULESET_SETUP_CHECK_RUNS="$tmp_dir/unreported.json" run_setup "$mode" >"$tmp_dir/out" 2>&1; then
            fail "unreported addition was accepted without an override ($mode)"
        else
            [ "$?" -eq 1 ] || fail "wrong exit for an unreported addition"
        fi
        [ ! -f "$wrote" ] || fail "unreported addition reached the write"
        grep -q 'closing-keywords' "$tmp_dir/out" || fail "unreported context not named"
        grep -q 'wedge every PR' "$tmp_dir/out" || fail "unreported consequence not explained"
        RULESET_SETUP_CHECK_RUNS="$tmp_dir/unreported.json" run_setup "$mode" --allow-unreported >"$tmp_dir/out" 2>&1 ||
            fail "explicit unreported override rejected"
        grep -q 'explicit --allow-unreported override' "$tmp_dir/out" || fail "override not disclosed"
        if [ "$mode" = --dry-run ]; then
            [ ! -f "$wrote" ] || fail "override made dry-run write"
        else
            [ -f "$wrote" ] || fail "override did not permit the addition"
        fi
    done
done

[ ! -f "$RULESET_TEST_GH_CALLS" ] || fail "fixture path invoked gh: $(cat "$RULESET_TEST_GH_CALLS")"

echo "==> the actual gh path uses the exact read/PUT contract through a fail-closed recording stub"
python3 - "$setup" "$file" "$tmp_dir" <<'PY'
import json
import os
import pathlib
import pty
import select
import subprocess
import sys
import time

setup, source, temporary = sys.argv[1:]
server = pathlib.Path(temporary) / "server"
server.mkdir()
server_bin = pathlib.Path(temporary) / "server-bin"
server_bin.mkdir()
stub = server_bin / "gh"
stub.write_text('''#!/usr/bin/env python3
import json
import os
import pathlib
import sys

server = pathlib.Path(os.environ["RULESET_TEST_SERVER"])
args = sys.argv[1:]
with (server / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\\n")
endpoint = "repos/example/ruleset/rulesets/42"
head = "a" * 40
state_file = server / "state.json"
state = json.loads(state_file.read_text()) if state_file.exists() else {"put": False}
if args == ["api", "--paginate", "--slurp", "repos/example/ruleset/rulesets?includes_parents=false&per_page=100"]:
    result = [[{"id": 42, "name": "Protect Main", "source_type": "Repository"}]]
elif args == ["api", "repos/example/ruleset"]:
    result = {"default_branch": "trunk"}
elif args == ["api", "repos/example/ruleset/commits/trunk"]:
    result = {"sha": head}
elif args == ["api", "--paginate", "--slurp", "repos/example/ruleset/commits/" + head + "/check-runs?per_page=100"]:
    result = json.loads((server / "checks.json").read_text())
elif args == ["api", "--paginate", "--slurp", "repos/example/ruleset/commits/" + head + "/statuses?per_page=100"]:
    result = [json.loads((server / "statuses.json").read_text())]
elif args == ["api", endpoint]:
    response = "live.json"
    if state["put"]:
        response = "after.json" if (server / "after.json").exists() else "payload.json"
    result = json.loads((server / response).read_text())
elif len(args) == 6 and args[:5] == ["api", "--method", "PUT", endpoint, "--input"]:
    result = json.loads(pathlib.Path(args[5]).read_text())
    (server / "payload.json").write_text(json.dumps(result))
    if (server / "put-fails").exists():
        print("HTTP 422: simulated PUT failure", file=sys.stderr)
        sys.exit(1)
    state["put"] = True
    state_file.write_text(json.dumps(state))
else:
    print("Unexpected gh call: " + repr(args), file=sys.stderr)
    sys.exit(97)
print(json.dumps(result))
''')
stub.chmod(0o755)
env = dict(os.environ, PATH=str(server_bin) + os.pathsep + os.environ["PATH"],
           RULESET_TEST_SERVER=str(server), RULESET_AUDIT_FILE=source)
for variable in ("RULESET_AUDIT_LIVE_LIST", "RULESET_AUDIT_LIVE_DETAIL", "RULESET_SETUP_WRITE_OUT",
                 "RULESET_SETUP_LIVE_AFTER", "RULESET_SETUP_CHECK_RUNS", "RULESET_SETUP_STATUSES"):
    env.pop(variable, None)

original = json.loads(pathlib.Path(source).read_text())
declared = next(rule["parameters"]["required_status_checks"] for rule in original["rules"]
                if rule["type"] == "required_status_checks")

def prepare(missing=("closing-keywords",), unreported=False, wrong_app=False, unpinned=False):
    for filename in ("calls.jsonl", "state.json", "payload.json", "after.json", "put-fails"):
        (server / filename).unlink(missing_ok=True)
    live = json.loads(json.dumps(original))
    for rule in live["rules"]:
        if rule["type"] == "required_status_checks":
            rule["parameters"]["required_status_checks"] = [check for check in declared
                                                           if check["context"] not in missing]
    (server / "live.json").write_text(json.dumps(live))
    runs = [{"name": check["context"], "app": {"id": check.get("integration_id")}}
            for check in declared]
    if unreported:
        runs = [run for run in runs if run["name"] != "closing-keywords"]
    if wrong_app:
        for run in runs:
            if run["name"] == "closing-keywords":
                run["app"]["id"] = 99999
    # Two pages prove the single gh inventory read aggregates before matching.
    (server / "checks.json").write_text(json.dumps([{"check_runs": runs[:1]}, {"check_runs": runs[1:]}]))
    (server / "statuses.json").write_text(json.dumps([{"context": "closing-keywords"}]))
    policy = json.loads(json.dumps(original))
    if unpinned:
        for rule in policy["rules"]:
            if rule["type"] == "required_status_checks":
                for check in rule["parameters"]["required_status_checks"]:
                    if check["context"] == "closing-keywords":
                        check["integration_id"] = None
    (server / "policy.json").write_text(json.dumps(policy))
    env["RULESET_AUDIT_FILE"] = str(server / "policy.json")

def invoke(*args):
    return subprocess.run([setup, "--repo", "example/ruleset", *args], env=env,
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)

endpoint = "repos/example/ruleset/rulesets/42"
lookup = [
    ["api", "--paginate", "--slurp", "repos/example/ruleset/rulesets?includes_parents=false&per_page=100"],
    ["api", endpoint],
    ["api", "repos/example/ruleset"],
    ["api", "repos/example/ruleset/commits/trunk"],
    ["api", "--paginate", "--slurp", "repos/example/ruleset/commits/" + "a" * 40 + "/check-runs?per_page=100"],
]
put = ["api", "--method", "PUT", endpoint, "--input", "<payload>"]
success = lookup + [["api", endpoint], put, ["api", endpoint]]
status_read = ["api", "--paginate", "--slurp", "repos/example/ruleset/commits/" + "a" * 40 + "/statuses?per_page=100"]

def assert_calls(expected):
    actual = [json.loads(line) for line in (server / "calls.jsonl").read_text().splitlines()]
    for call in actual:
        if call[:5] == put[:5] and len(call) == 6:
            assert pathlib.Path(call[5]).name == "payload.json", call
            call[5] = "<payload>"
    assert actual == expected, (actual, expected)

prepare()
unknown = subprocess.run([str(stub), "api", "--method", "DELETE", endpoint], env=env,
                         capture_output=True, text=True, timeout=30)
assert unknown.returncode == 97 and "Unexpected gh call" in unknown.stderr
assert_calls([["api", "--method", "DELETE", endpoint]])

prepare(missing=("closing-keywords", "security"))
result = invoke("--yes")
assert result.returncode == 0, result
assert "RULESET SETUP APPLIED" in result.stdout and "enforcement: active" in result.stdout, result
assert_calls(success)
payload = json.loads((server / "payload.json").read_text())
assert payload["conditions"] == original["conditions"]
assert {check["context"] for rule in payload["rules"] if rule["type"] == "required_status_checks"
        for check in rule["parameters"]["required_status_checks"]} == {check["context"] for check in declared}

prepare()
(server / "put-fails").touch()
result = invoke("--yes")
assert result.returncode == 1 and "could not update live ruleset" in result.stderr, result
assert "RULESET SETUP APPLIED" not in result.stdout, result
assert_calls(success[:-1])

prepare()
after = json.loads(json.dumps(original))
after["conditions"]["ref_name"]["include"] = ["refs/heads/release"]
(server / "after.json").write_text(json.dumps(after))
result = invoke("--yes")
assert result.returncode == 1 and "after-state differs from the update payload" in result.stderr, result
assert "refs/heads/release" in result.stderr and "RULESET SETUP APPLIED" not in result.stdout, result
assert_calls(success)

for options in ({"unreported": True}, {"wrong_app": True}):
    for flag in ("--yes", "--dry-run"):
        prepare(**options)
        result = invoke(flag)
        assert result.returncode == 1 and "RULESET SETUP UNREPORTED" in result.stderr, result
        assert "closing-keywords" in result.stderr and "wedge every PR" in result.stderr, result
        assert_calls(lookup)
        assert not (server / "payload.json").exists()
    prepare(**options)
    result = invoke("--yes", "--allow-unreported")
    assert result.returncode == 0 and "explicit --allow-unreported override" in result.stderr, result
    assert_calls(success)

prepare(unreported=True, unpinned=True)
result = invoke("--yes")
assert result.returncode == 0, result
assert_calls(lookup + [status_read, ["api", endpoint], put, ["api", endpoint]])

prepare()
master, slave = pty.openpty()
with subprocess.Popen([setup, "--repo", "example/ruleset"], env=env, stdin=slave,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
    os.close(slave)
    try:
        output = b""
        deadline = time.monotonic() + 30
        while b"[y/N] " not in output:
            if time.monotonic() >= deadline:
                raise AssertionError(f"decline prompt timed out: {output!r}")
            if select.select([process.stdout], [], [], 1)[0]:
                part = os.read(process.stdout.fileno(), 4096)
                assert part, ("exited before decline prompt", output)
                output += part
        os.write(master, b"n\n")
        remaining, _ = process.communicate(timeout=30)
        output += remaining
    finally:
        os.close(master)
assert process.returncode == 2 and b"declined" in output, output
assert_calls(lookup)
assert not (server / "payload.json").exists()
PY

echo "setup-ruleset: all cases passed"
