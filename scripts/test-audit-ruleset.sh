#!/usr/bin/env bash
# Hermetic tests for audit-ruleset.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
audit="$(pwd)/scripts/audit-ruleset.sh"
tmp_dir="$(mktemp -d -t harmon-init-test-ruleset-XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT

file="$tmp_dir/file.json"
list="$tmp_dir/list.json"
live="$tmp_dir/live.json"
stub_bin="$tmp_dir/bin"
cp ".github/Branch Protection Ruleset - Protect Main.json" "$file"
printf '[{"id":42,"name":"Protect Main","source_type":"Repository"}]\n' >"$list"
jq '.id = 999 | .node_id = "R_fake" | .created_at = "2026-01-01T00:00:00Z" | .updated_at = "2026-01-02T00:00:00Z" | .current_user_can_bypass = true | .rules |= reverse | (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= reverse' "$file" >"$live"
mkdir -p "$stub_bin"

run_audit() {
    RULESET_AUDIT_FILE="$file" RULESET_AUDIT_LIVE_LIST="$list" \
        RULESET_AUDIT_LIVE_DETAIL="$live" RULESET_AUDIT_REPO=example/ruleset \
        "$audit" "$@"
}

echo "==> identical fixtures"
run_audit >/dev/null

echo "==> server-added disabled dismissal restriction"
jq '(.rules[] | select(.type == "pull_request") | .parameters.dismissal_restriction) = {"allowed_actors": [], "enabled": false}' "$file" >"$live"
run_audit >/dev/null

for restriction in '{"allowed_actors": [], "enabled": true}' '{"allowed_actors": [42], "enabled": false}' '{"allowed_actors": [], "enabled": false, "extra": true}'; do
    echo "==> meaningful dismissal restriction: $restriction"
    jq --argjson restriction "$restriction" '(.rules[] | select(.type == "pull_request") | .parameters.dismissal_restriction) = $restriction' "$file" >"$live"
    if run_audit >"$tmp_dir/out"; then
        echo "FAIL: dismissal restriction was reported clean" >&2
        exit 1
    else
        status=$?
        [ "$status" -eq 1 ] || {
            echo "FAIL: dismissal restriction exit was $status" >&2
            exit 1
        }
    fi
    grep -q 'RULESET AUDIT DRIFT' "$tmp_dir/out" || {
        echo "FAIL: drift output missing" >&2
        exit 1
    }
done
cp "$file" "$live"

echo "==> missing required-check context"
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "devcontainer-verify"))' "$file" >"$live.tmp"
mv "$live.tmp" "$live"
if run_audit >"$tmp_dir/out"; then
    echo "FAIL: missing context was reported clean" >&2
    exit 1
else
    status=$?
    [ "$status" -eq 1 ] || {
        echo "FAIL: missing context exit was $status" >&2
        exit 1
    }
fi
grep -q 'RULESET AUDIT DRIFT' "$tmp_dir/out" || {
    echo "FAIL: drift output missing" >&2
    exit 1
}
cp "$file" "$live"

echo "==> extra live flag"
jq '(.rules[] | select(.type == "pull_request") | .parameters.extra_fixture_flag) = true' "$live" >"$live.tmp"
mv "$live.tmp" "$live"
if run_audit >"$tmp_dir/out"; then
    echo "FAIL: extra flag was reported clean" >&2
    exit 1
else
    status=$?
    [ "$status" -eq 1 ] || {
        echo "FAIL: extra flag exit was $status" >&2
        exit 1
    }
fi
cp "$file" "$live"

echo "==> absent ruleset"
printf '[]\n' >"$list"
if run_audit >/dev/null 2>&1; then
    echo "FAIL: absent ruleset was reported clean" >&2
    exit 1
else
    status=$?
    [ "$status" -eq 2 ] || {
        echo "FAIL: absent ruleset exit was $status" >&2
        exit 1
    }
fi

echo "==> permission denied"
cat >"$stub_bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$stub_bin/gh"
if env -u RULESET_AUDIT_LIVE_LIST -u RULESET_AUDIT_LIVE_DETAIL PATH="$stub_bin:$PATH" \
    RULESET_AUDIT_FILE="$file" RULESET_AUDIT_REPO=example/ruleset "$audit" >/dev/null 2>&1; then
    echo "FAIL: permission denial was reported clean" >&2
    exit 1
else
    status=$?
    [ "$status" -eq 2 ] || {
        echo "FAIL: permission exit was $status" >&2
        exit 1
    }
fi

echo "PASS: audit-ruleset fixtures behave"
