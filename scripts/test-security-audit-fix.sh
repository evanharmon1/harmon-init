#!/usr/bin/env bash
# test-security-audit-fix.sh — offline unit tests for the template's
# scripts/security-audit-fix.sh (task security:audit:fix and the scheduled
# security-audit-fix workflow's publish step).
#
# Every case runs the REAL shipped helper in a throwaway project while `pnpm`
# and `gh` are stubs on PATH. The pnpm stub replays canned results shaped like
# pnpm 11's (verified against pnpm 11.28.5): `audit --json` returns a fixture
# report until the expected floors are present, and `audit --fix` rewrites
# pnpm-workspace.yaml the way pnpm does — one `<pkg>@<vulnerable range>:
# ^<patch>` entry per advisory, appended to the overrides map, with a comment
# dropped. Nothing here touches the network, this repository, or GitHub.
# Run via `task test:security-audit-fix`.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

HELPER='template/scripts/[% if use_node %]security-audit-fix.sh[% endif %]'
FIX_BRANCH="bot/security-audit-fix"
BLOCK_START='  # --- harmon-init security floors (template-owned; updated by copier update) ---'
BLOCK_END='  # --- end harmon-init security floors; repository-local floors go below this line ---'

command -v jq >/dev/null 2>&1 || {
    echo "test-security-audit-fix: jq is required" >&2
    exit 1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

cases=0
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
pass() {
    cases=$((cases + 1))
    echo "ok - $*"
}

# ── Stubs ─────────────────────────────────────────────────────────────
mkdir -p "$TMPROOT/bin"
cat >"$TMPROOT/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
# pnpm stub. State lives in $STUB_DIR:
#   audit.json      the report `audit --json` returns while unremediated
#   cleared-by      a line whose presence in pnpm-workspace.yaml means remediated
#   fixed.yaml      the workspace file `audit --fix` writes
#   calls           every invocation, one per line
set -euo pipefail
echo "pnpm $*" >>"$STUB_DIR/calls"
case "$*" in
"audit --audit-level=high --json")
    if [ -f "$STUB_DIR/cleared-by" ] && grep -qF -f "$STUB_DIR/cleared-by" pnpm-workspace.yaml; then
        echo '{"advisories":{},"metadata":{}}'
    else
        cat "$STUB_DIR/audit.json"
    fi
    exit 1
    ;;
"audit --fix --audit-level=high")
    cat "$STUB_DIR/fixed.yaml" >pnpm-workspace.yaml
    echo "overrides were added to pnpm-workspace.yaml"
    ;;
"install --lockfile-only --ignore-scripts")
    echo "# relocked" >>pnpm-lock.yaml
    ;;
*)
    echo "pnpm stub: unexpected invocation: $*" >&2
    exit 64
    ;;
esac
STUB
cat >"$TMPROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub over a local bare origin. State in $STUB_DIR: pr (open PR number),
# draft (true/false), calls.
set -euo pipefail
echo "gh $*" >>"$STUB_DIR/calls"
head_sha() { git --git-dir="$ORIGIN" rev-parse "refs/heads/bot/security-audit-fix"; }
case "$1 $2" in
"pr list") cat "$STUB_DIR/pr" 2>/dev/null || true ;;
"pr create") echo 7 >"$STUB_DIR/pr"; echo true >"$STUB_DIR/draft" ;;
"pr edit") ;;
"pr view") echo "$(head_sha) $(cat "$STUB_DIR/draft")" ;;
"pr ready") echo true >"$STUB_DIR/draft" ;;
*) echo "gh stub: unexpected: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMPROOT/bin/pnpm" "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH"
# A credential-free run: git_remote must fall back to plain git.
unset GH_TOKEN GITHUB_TOKEN GH_APP_SLUG

# ── Fixtures ─────────────────────────────────────────────────────────

# advisory ID PKG SEVERITY RANGE VERSION DIRECT — one audit.json advisory entry.
advisory() {
    jq -n --arg id "$1" --arg pkg "$2" --arg sev "$3" --arg range "$4" --arg ver "$5" --arg direct "$6" '
        {($id): {github_advisory_id: $id, module_name: $pkg, severity: $sev,
                 vulnerable_versions: $range,
                 findings: [{version: $ver, paths: [".>" + $direct + (if $direct == $pkg then "" else ">" + $pkg end)]}]}}'
}

# new_project NAME — a project whose workspace file carries the template block
# and a local floor, plus a stub state dir. Echoes the project path.
new_project() {
    _np="$TMPROOT/$1"
    mkdir -p "$_np/scripts" "$_np/.stub"
    cp "$REPO_ROOT/$HELPER" "$_np/scripts/security-audit-fix.sh"
    chmod +x "$_np/scripts/security-audit-fix.sh"
    printf '{"name":"fixture","private":true}\n' >"$_np/package.json"
    printf 'lockfileVersion: 9.0\n' >"$_np/pnpm-lock.yaml"
    cat >"$_np/pnpm-workspace.yaml" <<EOF
allowBuilds:
  esbuild: true

overrides:
$BLOCK_START
  # source-map-js@1: GHSA-68fv-2mgg-jv7q.
  source-map-js@1: '>=1.2.2 <2'
$BLOCK_END
  # left-pad@1: GHSA-0000-0000-0001.
  left-pad@1: '>=1.3.0 <2'

# pnpm 11 defaults minimumReleaseAge to 1440
EOF
    : >"$_np/.stub/calls"
    echo "$_np"
}

# fix_writes PROJECT LINES… — what `pnpm audit --fix` leaves behind: the
# original map with LINES appended and the template end marker dropped, the
# comment loss observed from real pnpm 11.
fix_writes() {
    _fw="$1"
    shift
    {
        grep -vF "$BLOCK_END" "$_fw/pnpm-workspace.yaml" | sed '/^# pnpm 11/,$d' | sed '$d'
        printf '%s\n' "$@"
        printf '\n# pnpm 11 defaults minimumReleaseAge to 1440\n'
    } >"$_fw/.stub/fixed.yaml"
}

run_fix() {
    _rf="$1"
    shift
    (cd "$_rf" && STUB_DIR="$_rf/.stub" ./scripts/security-audit-fix.sh fix "$@")
}

snapshot_of() {
    cat "$1/pnpm-workspace.yaml" "$1/pnpm-lock.yaml" "$1/package.json" | cksum
}

# ── 1. bounded floors below the end marker, merged per major ─────────
p="$(new_project bounded)"
{
    advisory GHSA-35jh-r3h4-6jhm lodash high '<4.17.21' 4.17.20 lodash
    advisory GHSA-r5fr-rjxr-66jc lodash high '>=4.0.0 <=4.17.23' 4.17.20 lodash
    advisory GHSA-67hx-6x53-jw92 @babel/traverse critical '<7.23.2' 7.22.0 vite
    advisory GHSA-aaaa-bbbb-cccc tiny-zero high '>=0.4.0 <0.4.9' 0.4.2 astro
} | jq -s 'add | {advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" \
    '  lodash@<4.17.21: ^4.17.21' \
    "  lodash@>=4.0.0 <=4.17.23: ^4.18.1" \
    "  '@babel/traverse@<7.23.2': ^7.23.2" \
    '  tiny-zero@>=0.4.0 <0.4.9: ^0.4.9'
echo "lodash@4: '>=4.18.1 <5'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "bounded: fix exited non-zero"
}
cat >"$p/expected.yaml" <<EOF
allowBuilds:
  esbuild: true

overrides:
$BLOCK_START
  # source-map-js@1: GHSA-68fv-2mgg-jv7q.
  source-map-js@1: '>=1.2.2 <2'
$BLOCK_END
  # left-pad@1: GHSA-0000-0000-0001.
  left-pad@1: '>=1.3.0 <2'
  # @babel/traverse@7: GHSA-67hx-6x53-jw92.
  '@babel/traverse@7': '>=7.23.2 <8'
  # lodash@4: GHSA-35jh-r3h4-6jhm, GHSA-r5fr-rjxr-66jc.
  lodash@4: '>=4.18.1 <5'
  # tiny-zero@0.4: GHSA-aaaa-bbbb-cccc.
  tiny-zero@0.4: '>=0.4.9 <0.5'

# pnpm 11 defaults minimumReleaseAge to 1440
EOF
diff -u "$p/expected.yaml" "$p/pnpm-workspace.yaml" || fail "bounded: workspace file differs from the expected bounded floors"
grep -qx '# relocked' "$p/pnpm-lock.yaml" || fail "bounded: lockfile was not re-resolved"
grep -qx 'pnpm install --lockfile-only --ignore-scripts' "$p/.stub/calls" || fail "bounded: re-resolve must not run lifecycle scripts"
grep -qF "| GHSA-r5fr-rjxr-66jc | \`lodash\` | high | 4.17.20 | floor \`lodash@4: '>=4.18.1 <5'\` |" "$p/report.md" ||
    fail "bounded: report does not list the advisory with its floor"
grep -qF '| `@babel/traverse` |' "$p/report.md" || fail "bounded: scoped package must be a code span (no @mention)"
pass "bounded: --fix output becomes pkg@<major> floors below the end marker, markers restored, lockfile re-resolved"

# ── 2. idempotent on an already-remediated tree ───────────────────────
before="$(snapshot_of "$p")"
: >"$p/.stub/calls"
run_fix "$p" >"$p/out2.log" 2>&1 || fail "idempotent: second run exited non-zero"
[ "$(snapshot_of "$p")" = "$before" ] || fail "idempotent: second run changed bytes"
! grep -q -- '--fix\|install' "$p/.stub/calls" || fail "idempotent: second run ran --fix or install"
pass "idempotent: a second run is a byte-identical no-op"

# ── 3. strict refusal on a major crossing writes nothing ──────────────
p="$(new_project crossing)"
{
    advisory GHSA-8cf7-32gw-wr33 jsonwebtoken high '<=8.5.1' 8.5.1 jsonwebtoken
    advisory GHSA-xvch-5gv4-984h minimist critical '>=1.0.0 <1.2.6' 1.2.5 mkdirp
} | jq -s 'add | {advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  jsonwebtoken@<=8.5.1: ^9.0.0' '  minimist@>=1.0.0 <1.2.6: ^1.2.6'
before="$(snapshot_of "$p")"
rc=0
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 3 ] || {
    cat "$p/out.log"
    fail "crossing: expected exit 3, got $rc"
}
[ "$(snapshot_of "$p")" = "$before" ] || fail "crossing: a refused run must leave every byte unchanged"
grep -q 'jsonwebtoken.*major 8 to major 9' "$p/out.log" || fail "crossing: refusal must name the package and both majors"
grep -q 'direct dependency `jsonwebtoken`' "$p/out.log" || fail "crossing: refusal must name the direct dependency"
grep -q 'install' "$p/.stub/calls" && fail "crossing: a refused run must not re-resolve the lockfile"
grep -q '\*\*refused:\*\* the fix (9.0.0) crosses from major 8 to major 9' "$p/report.md" ||
    fail "crossing: report does not carry the refusal reason"
pass "crossing: strict mode refuses, names package + majors, writes nothing, exits 3"

# ── 4. --skip-refused applies the rest and reports the refusal ─────────
echo "minimist@1: '>=1.2.6 <2'" >"$p/.stub/cleared-by"
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "skip-refused: exited non-zero"
}
grep -qF "  minimist@1: '>=1.2.6 <2'" "$p/pnpm-workspace.yaml" || fail "skip-refused: fixable floor not applied"
! grep -q jsonwebtoken "$p/pnpm-workspace.yaml" || fail "skip-refused: refused fix leaked into the workspace file"
grep -qF '**refused:**' "$p/report.md" || fail "skip-refused: report lost the refusal"
grep -qF "floor \`minimist@1: '>=1.2.6 <2'\`" "$p/report.md" || fail "skip-refused: report lost the applied floor"
pass "skip-refused: applies the bounded floors, reports the refused crossing"

# ── 5. a floor the template block owns is refused, never edited ───────
p="$(new_project template-owned)"
advisory GHSA-dddd-eeee-ffff source-map-js high '<1.2.3' 1.2.2 postcss | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  source-map-js@<1.2.3: ^1.2.3'
before="$(snapshot_of "$p")"
rc=0
run_fix "$p" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "template-owned: expected exit 3, got $rc"
[ "$(snapshot_of "$p")" = "$before" ] || fail "template-owned: the template block must never be edited"
grep -q 'template-owned floor' "$p/out.log" || fail "template-owned: refusal reason missing"
pass "template-owned: a key inside the template block is refused (raise upstream)"

# ── 6. a lower local floor is replaced in place with its comment ──────
p="$(new_project raise-local)"
advisory GHSA-0000-0000-0002 left-pad high '<1.3.4' 1.3.1 left-pad | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  left-pad@<1.3.4: ^1.3.4'
echo "left-pad@1: '>=1.3.4 <2'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || fail "raise-local: exited non-zero"
[ "$(grep -c 'left-pad@1' "$p/pnpm-workspace.yaml")" -eq 2 ] || fail "raise-local: expected exactly one comment + one entry for left-pad@1"
grep -qF '  # left-pad@1: GHSA-0000-0000-0002.' "$p/pnpm-workspace.yaml" || fail "raise-local: comment not refreshed"
pass "raise-local: an existing lower local floor is raised in place, not duplicated"

# ── 7. operational failures restore every byte and exit 1 ─────────────
p="$(new_project registry-down)"
echo 'ERR_PNPM_AUDIT_BAD_RESPONSE' >"$p/.stub/audit.json"
before="$(snapshot_of "$p")"
rc=0
run_fix "$p" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "registry-down: expected exit 1, got $rc"
[ "$(snapshot_of "$p")" = "$before" ] || fail "registry-down: bytes changed"
pass "registry-down: a non-report audit result is an operational failure"

p="$(new_project not-cleared)"
advisory GHSA-0000-0000-0003 left-pad high '<1.3.4' 1.3.1 left-pad | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  left-pad@<1.3.4: ^1.3.4'
before="$(snapshot_of "$p")"
rc=0
run_fix "$p" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "not-cleared: expected exit 1, got $rc"
[ "$(snapshot_of "$p")" = "$before" ] || fail "not-cleared: a floor that does not clear must be rolled back"
pass "not-cleared: a floor that leaves its advisory standing is rolled back"

# ── 8. publish: one rolling draft PR, scope-checked patch ─────────────
p="$(new_project publish)"
ORIGIN="$TMPROOT/origin.git"
export ORIGIN
git init -q --bare "$ORIGIN"
(
    cd "$p"
    rm -rf .stub/calls && : >.stub/calls
    printf '.stub/\nout/\n' >.gitignore
    git init -q -b main .
    git -c user.name=t -c user.email=t@example.invalid add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm 'chore: fixture'
    git remote add origin "$ORIGIN"
    git push -q origin main
    mkdir -p out
    printf "  # lodash@4: GHSA-x.\n  lodash@4: '>=4.18.1 <5'\n" >>pnpm-workspace.yaml
    echo '# relocked' >>pnpm-lock.yaml
    git diff --binary >out/changes.patch
    git checkout -q -- .
    echo '## Dependency audit remediation' >out/report.md
)
publish() {
    (cd "$p" && STUB_DIR="$p/.stub" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        ./scripts/security-audit-fix.sh publish "$p/out")
}
publish >"$p/out/1.log" 2>&1 || {
    cat "$p/out/1.log"
    fail "publish: first run failed"
}
git --git-dir="$ORIGIN" rev-parse -q --verify "refs/heads/$FIX_BRANCH" >/dev/null || fail "publish: bot branch not pushed"
[ "$(grep -c '^gh pr create --draft' "$p/.stub/calls")" -eq 1 ] || fail "publish: expected exactly one draft PR"
git --git-dir="$ORIGIN" show "refs/heads/$FIX_BRANCH:pnpm-workspace.yaml" | grep -qF "lodash@4: '>=4.18.1 <5'" ||
    fail "publish: bot branch lacks the floors"
first="$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$FIX_BRANCH")"
(cd "$p" && git checkout -q main)
publish >"$p/out/2.log" 2>&1 || fail "publish: rerun failed"
[ "$(grep -c '^gh pr create' "$p/.stub/calls")" -eq 1 ] || fail "publish: rerun opened a second PR"
grep -q '^gh pr edit 7 ' "$p/.stub/calls" || fail "publish: rerun did not refresh the open PR"
[ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$FIX_BRANCH")" = "$first" ] || fail "publish: unchanged floors must not re-push"
! grep -q 'merge' "$p/.stub/calls" || fail "publish: must never merge"
pass "publish: opens one draft PR on $FIX_BRANCH; a rerun updates it without churn"

(cd "$p" && git checkout -q main && printf '{"name":"evil"}\n' >package.json && git diff >out/changes.patch && git checkout -q -- .)
rc=0
publish >"$p/out/3.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || ! grep -q "touches 'package.json'" "$p/out/3.log"; then
    fail "publish: a patch outside the two floor files must be refused"
fi
pass "publish: a patch touching anything but the workspace file and lockfile is refused"

echo "test-security-audit-fix: $cases cases passed"
