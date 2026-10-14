#!/usr/bin/env bash
# Offline tests of the shipped helper and its remediation integration.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/project/scripts" "$TMP/bin"
cp 'template/scripts/[% if use_node %]security-audit.sh[% endif %]' "$TMP/project/scripts/security-audit.sh"
cp 'template/scripts/[% if use_node %]security-audit-fix.sh[% endif %]' "$TMP/project/scripts/security-audit-fix.sh"
cat >"$TMP/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$STUB/calls"
case "$*" in
'audit --audit-level=high --json') cat "$STUB/full.json"; exit 1 ;;
'audit --audit-level=high --prod --json') cat "$STUB/prod.json"; exit 1 ;;
'audit --audit-level=high --ignore GHSA-vfj7-8cjw-p6xm')
    printf '\nauditConfig: {ignoreGhsas: [GHSA-vfj7-8cjw-p6xm]}\n' >>pnpm-workspace.yaml
    exit 0
    ;;
  'audit --audit-level=high')
    if grep -q 'auditConfig:' pnpm-workspace.yaml && ! jq -e '.advisories[] | select(.github_advisory_id != "GHSA-vfj7-8cjw-p6xm" and (.severity == "high" or .severity == "critical"))' "$STUB/full.json" >/dev/null; then
        exit 0
    fi
    exit 1
    ;;
'view braces@>=3.0.4 version --json')
    if [ -f "$STUB/unpublished" ]; then
        printf '{"error":{"code":"ERR_PNPM_PACKAGE_NOT_FOUND","message":"No matching version found for braces@>=3.0.4"}}\n'
        exit 1
    elif [ -f "$STUB/view-failure" ]; then
        printf '{"error":{"code":"NETWORK","message":"unreachable"}}\n'
        exit 1
    fi
    printf '\"3.0.4\"\n'
    ;;

*) echo "unexpected pnpm call: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP/bin/pnpm"
export PATH="$TMP/bin:$PATH" STUB="$TMP"
cd "$TMP/project"
file=.security-audit-allowances.json
printf '{}\n' >package.json
printf 'lockfileVersion: 9\n' >pnpm-lock.yaml
printf 'overrides: {}\n' >pnpm-workspace.yaml
cp pnpm-workspace.yaml "$TMP/pristine.workspace"
jq -n '{advisories:{"1":{github_advisory_id:"GHSA-vfj7-8cjw-p6xm",module_name:"braces",severity:"high",patched_versions:"<0.0.0",findings:[{version:"3.0.3",paths:[".>markdownlint-cli2>micromatch>braces"]}]}}}' >"$TMP/base.json"
today="$(date -u +%Y-%m-%d)"
now="$(jq -n --arg t "$today" '$t + "T00:00:00Z" | fromdateiso8601')"
entry() {
    jq -n --arg today "$today" '{allowances:[{ghsa:"GHSA-vfj7-8cjw-p6xm",package:"braces",reason:"Unpatched lint dependency; reviewed exception",tracking_issue:"https://github.com/example/repo/issues/1",added:$today,expires:$today}]}' >"$file"
}
reset() {
    cp "$TMP/base.json" "$TMP/full.json"
    printf '{"advisories":{}}\n' >"$TMP/prod.json"
    : >"$TMP/calls"
    rm -f "$TMP/unpublished" "$TMP/view-failure"
    entry
}
edit() {
    jq "$1" "$file" >"$TMP/edited.json"
    cp "$TMP/edited.json" "$file"
}
expect() {
    local rc=0
    ./scripts/security-audit.sh >"$TMP/out" 2>&1 || rc=$?
    [ "$rc" -eq "$1" ] || {
        cat "$TMP/out"
        echo "FAIL $2: exit $rc expected $1"
        exit 1
    }
    if [ "$1" -ne 0 ]; then
        grep -qF "$2" "$TMP/out" || {
            cat "$TMP/out"
            echo "missing failure: $2"
            exit 1
        }
        ! grep -q -- '--ignore' "$TMP/calls" || {
            echo 'invalid allowance ignored advisory'
            exit 1
        }
    fi
    echo "ok - $2"
}
reset
expect 0 'valid allowance'
grep -qx 'audit --audit-level=high --ignore GHSA-vfj7-8cjw-p6xm' "$TMP/calls"
[ "$(tail -1 "$TMP/calls")" = 'audit --audit-level=high' ]
cmp pnpm-workspace.yaml "$TMP/pristine.workspace"
echo 'ok - ignore runs only in scratch; ordinary audit still gates; source is byte-identical'
# Changing the production graph invalidates the same entry on the next run.
cp "$TMP/base.json" "$TMP/prod.json"
: >"$TMP/calls"
expect 1 'production reachable'
reset
jq '.advisories["1"].patched_versions=">=3.0.4"' "$TMP/base.json" >"$TMP/full.json"
expect 1 'patched version exists'
reset
jq '.advisories["1"].patched_versions=">=3.0.4"' "$TMP/base.json" >"$TMP/full.json"
touch "$TMP/unpublished"
expect 0 'unpublished synthesized patched range'
reset
jq '.advisories["1"].patched_versions=">=3.0.4"' "$TMP/base.json" >"$TMP/full.json"
touch "$TMP/view-failure"
expect 1 'patch lookup failed'

reset
jq 'del(.advisories["1"].patched_versions)' "$TMP/base.json" >"$TMP/full.json"
expect 1 'patch status is unknown'
reset
past="$(jq -nr --argjson n "$now" '$n - 86400 | strftime("%Y-%m-%d")')"
edit ".allowances[0].added=\"$past\" | .allowances[0].expires=\"$past\""
expect 1 expired
reset
future="$(jq -nr --argjson n "$now" '$n + 91*86400 | strftime("%Y-%m-%d")')"
edit ".allowances[0].expires=\"$future\""
expect 1 'expiry window exceeds 90 days'
reset
future="$(jq -nr --argjson n "$now" '$n + 90*86400 | strftime("%Y-%m-%d")')"
edit ".allowances[0].expires=\"$future\""
expect 0 '90-day boundary'
reset
printf '{"advisories":{}}\n' >"$TMP/full.json"
expect 1 stale
reset
printf '{broken' >"$file"
expect 1 'malformed allowance file'
reset
edit '.allowances={}'
expect 1 'malformed allowance file'
reset
edit '.allowances[0].package="other"'
expect 1 'package does not match'
reset
edit '.allowances[0].added="2026-02-30"'
expect 1 'malformed added/expires date'
reset
edit '.allowances[0].ghsa="--ignore"'
expect 1 'malformed GHSA id'
reset
edit '.allowances[0].reason="  "'
expect 1 'missing reason'
reset
edit 'del(.allowances[0].tracking_issue)'
expect 1 'missing tracking issue URL'
reset
edit '.allowances[0]=null'
expect 1 'malformed entry'
reset
printf '{"error":{"code":"NETWORK"}}\n' >"$TMP/prod.json"
expect 1 'invalid audit report'
reset
printf '{"error":{"code":"NETWORK"}}\n' >"$TMP/full.json"
expect 1 'invalid audit report'
reset
edit ".allowances[0].added=\"$future\" | .allowances[0].expires=\"$future\""
expect 1 'added date is in the future'
# Missing and empty files run the unchanged high audit, including its exit.
rm "$file"
: >"$TMP/calls"
rc=0
./scripts/security-audit.sh || rc=$?
[ "$rc" -eq 1 ]
[ "$(cat "$TMP/calls")" = 'audit --audit-level=high' ]
echo 'ok - no file preserves ordinary audit'
printf '{"allowances":[]}\n' >"$file"
: >"$TMP/calls"
rc=0
./scripts/security-audit.sh || rc=$?
[ "$rc" -eq 1 ]
[ "$(cat "$TMP/calls")" = 'audit --audit-level=high' ]
echo 'ok - empty seed preserves ordinary audit'
# Filter removes only allowed IDs, never an unrelated advisory.
reset
jq '.advisories["2"]={github_advisory_id:"GHSA-aaaa-bbbb-cccc",module_name:"other",patched_versions:">=2.0.0",severity:"critical"}' "$TMP/base.json" >"$TMP/full.json"
./scripts/security-audit.sh filter "$TMP/full.json" "$TMP/filtered.json"
jq -e '.advisories | keys == ["2"]' "$TMP/filtered.json" >/dev/null
echo 'ok - filter preserves unrelated advisory'
rc=0
./scripts/security-audit.sh >"$TMP/out" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || {
    echo 'unrelated high advisory did not fail gate'
    exit 1
}
cmp pnpm-workspace.yaml "$TMP/pristine.workspace"
echo 'ok - allowed advisory never hides an unrelated high finding'
# A fresh validation happens in fix, even when invoked without the gate.
reset
printf '{"overrides":{}}\n' >pnpm-workspace.yaml
printf 'lockfileVersion: 9\n' >pnpm-lock.yaml
printf '{}\n' >package.json
cp pnpm-workspace.yaml "$TMP/before.workspace"
cp pnpm-lock.yaml "$TMP/before.lock"
./scripts/security-audit-fix.sh fix --report "$TMP/report.md"
! grep -q -- '--fix' "$TMP/calls"
cmp pnpm-workspace.yaml "$TMP/before.workspace"
cmp pnpm-lock.yaml "$TMP/before.lock"
echo 'ok - allowed-only fix writes no floors and opens no remediation path'
# Consumer-owned seed is frozen by Copier policy, not a mutable template map.
grep -qx '  - .security-audit-allowances.json' "$ROOT/copier.yml"
echo 'security-audit tests passed'
