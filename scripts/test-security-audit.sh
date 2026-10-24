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
'--version') printf '%s.0.0\n' "${STUB_PNPM_MAJOR:?STUB_PNPM_MAJOR must be set for the pnpm version probe}" ;;
'audit --audit-level=high --json') cat "$STUB/full.json"; exit 1 ;;
'audit --audit-level=high --prod --json') cat "$STUB/prod.json"; exit 1 ;;
'audit --audit-level=high --ignore GHSA-vfj7-8cjw-p6xm')
    # pnpm 10 files GHSA inputs under ignoreCves; 11/12 use ignoreGhsas.
    if [ "$STUB_PNPM_MAJOR" = 10 ]; then key=ignoreCves; else key=ignoreGhsas; fi
    KEY="$key" yq -i '.auditConfig[strenv(KEY)] = ["GHSA-vfj7-8cjw-p6xm"]' pnpm-workspace.yaml
    exit 0
    ;;
  'audit --audit-level=high')
    cp pnpm-workspace.yaml "$STUB/applied.workspace"
    if yq -e '(.audit.ignore // .auditConfig.ignoreGhsas) | contains(["GHSA-vfj7-8cjw-p6xm"])' pnpm-workspace.yaml >/dev/null 2>&1 && ! jq -e '.advisories[] | select(.github_advisory_id != "GHSA-vfj7-8cjw-p6xm" and (.severity == "high" or .severity == "critical"))' "$STUB/full.json" >/dev/null; then
        exit 0
    fi
    exit 1
    ;;
  'view braces versions --json')
    if [ -f "$STUB/view-failure" ]; then
        printf '{"error":{"code":"NETWORK"}}\n'; exit 1
    fi
    cat "$STUB/versions.json"
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
# Isolate package provisioning, not the helper's writer: execute its actual
# stdin Python using a YAML adapter backed by the root suite's existing yq.
# Real pnpm proofs exercise the pinned ruamel.yaml implementation separately.
cat >"$TMP/bin/uv" <<'UV'
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$STUB/uv-runner.py" "$@"
UV
cat >"$TMP/uv-runner.py" <<'PYTHON'
import json
import subprocess
import sys
import types

assert sys.argv[1:4] == ["run", "--no-project", "--with"]
assert sys.argv[4].startswith("ruamel.yaml==")
assert sys.argv[5:7] == ["python", "-"]

class YAML:
    def __init__(self, **kwargs):
        pass

    def load(self, text):
        return json.loads(subprocess.check_output(["yq", "-o=json", "."], input=text, text=True))

    def dump(self, data, path):
        path.write_text(subprocess.check_output(["yq", "-P", "."], input=json.dumps(data), text=True))

module = types.ModuleType("ruamel.yaml")
module.YAML = YAML
sys.modules["ruamel"] = types.ModuleType("ruamel")
sys.modules["ruamel.yaml"] = module
sys.argv = sys.argv[6:]
exec(compile(sys.stdin.read(), "security-audit YAML writer", "exec"))
PYTHON
chmod +x "$TMP/bin/uv"
# A cold, offline cache must not affect this offline test suite.
export UV_CACHE_DIR="$TMP/cold-uv-cache" UV_OFFLINE=true
export PATH="$TMP/bin:$PATH" STUB="$TMP" STUB_PNPM_MAJOR=10
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
    printf '["1.0.0","2.3.2","3.0.3"]\n' >"$TMP/versions.json"
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
        ! grep -qE -- '--ignore|^config set ' "$TMP/calls" || {
            echo 'invalid allowance registered an ignore'
            exit 1
        }
    fi
    echo "ok - $2"
}
reset
for STUB_PNPM_MAJOR in 10 11 12; do
    export STUB_PNPM_MAJOR
    if [ "$STUB_PNPM_MAJOR" = 12 ]; then
        jq '.advisories["1"].patched_versions=null | .advisories["1"].vulnerable_versions="<=3.0.3"' "$TMP/base.json" >"$TMP/full.json"
    fi
    expect 0 "valid allowance (pnpm $STUB_PNPM_MAJOR)"
    ! grep -qE -- '--ignore|^config set ' "$TMP/calls"
    cmp pnpm-workspace.yaml "$TMP/pristine.workspace"
    printf '{"allowances":[]}\n' >"$file"
    rc=0
    ./scripts/security-audit.sh >"$TMP/out" 2>&1 || rc=$?
    [ "$rc" -eq 1 ]
    echo "ok - empty seed fails (pnpm $STUB_PNPM_MAJOR)"
    reset
done
export STUB_PNPM_MAJOR=10
expect 0 'valid allowance'
[ "$(tail -1 "$TMP/calls")" = 'audit --audit-level=high' ]
cmp pnpm-workspace.yaml "$TMP/pristine.workspace"
echo 'ok - ignores stay in scratch; ordinary audit still gates; source is byte-identical'
cat >pnpm-workspace.yaml <<'YAML'
overrides: {other: '>=2.0.0', on: '>=1.0.0'}
auditConfig:
  ignoreGhsas: [GHSA-aaaa-bbbb-cccc, GHSA-vfj7-8cjw-p6xm]
  ignoreCves: [CVE-2026-4800]
  ignoreRegistryErrors: false
YAML
cp pnpm-workspace.yaml "$TMP/merge.workspace"
expect 0 'existing audit configuration merged'
cmp pnpm-workspace.yaml "$TMP/merge.workspace"
yq -o=json '.' "$TMP/applied.workspace" | jq -e '
    .auditConfig.ignoreGhsas == ["GHSA-aaaa-bbbb-cccc", "GHSA-vfj7-8cjw-p6xm"]
    and .auditConfig.ignoreCves == ["CVE-2026-4800"]
    and .auditConfig.ignoreRegistryErrors == false
    and .overrides.other == ">=2.0.0"
    and .overrides.on == ">=1.0.0"' >/dev/null
cp "$TMP/pristine.workspace" pnpm-workspace.yaml
echo 'ok - existing ignores and unrelated settings preserved without duplicate GHSAs'
export STUB_PNPM_MAJOR=12
printf 'audit: {ignore: [GHSA-aaaa-bbbb-cccc], registryErrors: false}\n' >pnpm-workspace.yaml
cp pnpm-workspace.yaml "$TMP/canonical.workspace"
expect 0 'pnpm 12 canonical audit settings merged'
cmp pnpm-workspace.yaml "$TMP/canonical.workspace"
yq -o=json '.audit' "$TMP/applied.workspace" | jq -e '
    .ignore == ["GHSA-aaaa-bbbb-cccc", "GHSA-vfj7-8cjw-p6xm"] and .registryErrors == false' >/dev/null
cp "$TMP/pristine.workspace" pnpm-workspace.yaml
export STUB_PNPM_MAJOR=10
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

# Explicit null needs an independent proof over all published releases.
null_report() {
    jq '.advisories["1"].patched_versions=null | .advisories["1"].vulnerable_versions="<=3.0.3"' "$TMP/base.json" >"$TMP/full.json"
}
reset
null_report
expect 0 'null patch with every published release vulnerable'
jq '.advisories["1"].vulnerable_versions="<3.0.4"' "$TMP/full.json" >"$TMP/changed.json"
cp "$TMP/changed.json" "$TMP/full.json"
expect 0 'null patch with strict upper bound'
: >"$TMP/calls"
jq '.advisories["1"].vulnerable_versions="<3.0.3"' "$TMP/full.json" >"$TMP/changed.json"
cp "$TMP/changed.json" "$TMP/full.json"
expect 1 'patched version exists'
reset
null_report
printf '["1.0.0","3.0.3","4.0.0"]\n' >"$TMP/versions.json"
expect 1 'patched version exists'
reset
null_report
touch "$TMP/view-failure"
expect 1 'patch status is unknown'
for response in '{broken' '{}' '[]' '[null]' '["3.0.3-beta.1"]' '["9007199254740992.0.0"]'; do
    reset
    null_report
    printf '%s\n' "$response" >"$TMP/versions.json"
    expect 1 'patch status is unknown'
done
reset
null_report
jq '.advisories["1"].vulnerable_versions="garbage"' "$TMP/full.json" >"$TMP/changed.json"
cp "$TMP/changed.json" "$TMP/full.json"
expect 1 'patch status is unknown'
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
