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
# dropped. Assertions read the result through the REAL yq (mikefarah v4), the
# tool the helper itself edits with, so a case passes only when the written
# file parses and its overrides map holds exactly the expected entries.
# Nothing here touches the network, this repository, or GitHub.
# Run via `task test:security-audit-fix`.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

HELPER='template/scripts/[% if use_node %]security-audit-fix.sh[% endif %]'
FIX_BRANCH="bot/security-audit-fix"
BLOCK_START='  # --- harmon-init security floors (template-owned; updated by copier update) ---'
BLOCK_END='  # --- end harmon-init security floors; repository-local floors go below this line ---'

for _bin in jq yq; do
    command -v "$_bin" >/dev/null 2>&1 || {
        echo "test-security-audit-fix: $_bin is required" >&2
        exit 1
    }
done

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
#   needs-relock    when present, remediated also needs a re-resolved lockfile
#   audit-after.json  the report once remediated (default: no advisories)
#   fixed.yaml      the workspace file `audit --fix` writes
#   calls           every invocation, one per line
set -euo pipefail
echo "pnpm $*" >>"$STUB_DIR/calls"
case "$*" in
"audit --audit-level=high --json")
    if [ -f "$STUB_DIR/cleared-by" ] && grep -qF -f "$STUB_DIR/cleared-by" pnpm-workspace.yaml &&
        { [ ! -f "$STUB_DIR/needs-relock" ] || grep -qx '# relocked' pnpm-lock.yaml; }; then
        if [ -f "$STUB_DIR/audit-after.json" ]; then
            cat "$STUB_DIR/audit-after.json"
        else
            echo '{"advisories":{},"metadata":{}}'
        fi
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

# fix_adds PROJECT KEY VALUE… — what `pnpm audit --fix` leaves behind, for
# fixtures fix_writes' line edits cannot model: the same file with each KEY set
# to VALUE in its overrides map (written by yq).
fix_adds() {
    _fa="$1"
    shift
    cp "$_fa/pnpm-workspace.yaml" "$_fa/.stub/fixed.yaml"
    while [ $# -ge 2 ]; do
        K="$1" V="$2" yq -i '.overrides[strenv(K)] = strenv(V)' "$_fa/.stub/fixed.yaml"
        shift 2
    done
}

# expect_overrides PROJECT LABEL JSON — the written file parses and its
# overrides map is exactly JSON (keys and values, order-insensitive).
expect_overrides() {
    _eo_got="$(yq -o=json -I=0 '.overrides // {}' "$1/pnpm-workspace.yaml" 2>&1)" ||
        fail "$2: the written pnpm-workspace.yaml does not parse: $_eo_got"
    [ "$(jq -S . <<<"$_eo_got")" = "$(jq -S . <<<"$3")" ] ||
        fail "$2: overrides are $_eo_got, expected $3"
}

# expect_below_marker PROJECT LABEL KEY — both markers are still present, in
# order, and KEY sits below the end marker.
expect_below_marker() {
    _eb_s="$(grep -nF -- "${BLOCK_START#  }" "$1/pnpm-workspace.yaml" | cut -d: -f1)"
    _eb_e="$(grep -nF -- "${BLOCK_END#  }" "$1/pnpm-workspace.yaml" | cut -d: -f1)"
    [ -n "$_eb_s" ] && [ -n "$_eb_e" ] && [ "$_eb_s" -lt "$_eb_e" ] || fail "$2: a template marker was lost or reordered"
    _eb_k="$(K="$3" yq '.overrides[strenv(K)] | key | line' "$1/pnpm-workspace.yaml")"
    [ "$_eb_k" -gt "$_eb_e" ] || fail "$2: $3 (line $_eb_k) is not below the end marker (line $_eb_e)"
}

# head_comment_of PROJECT KEY — the comment yq attaches above KEY.
head_comment_of() {
    K="$2" yq '.overrides[strenv(K)] | key | head_comment' "$1/pnpm-workspace.yaml"
}

# expect_refused PROJECT LABEL PATTERN [ARGS…] — exit 3, every byte unchanged,
# PATTERN in the output.
expect_refused() {
    _er="$1" _er_label="$2" _er_pat="$3"
    shift 3
    _er_before="$(snapshot_of "$_er")"
    _er_rc=0
    run_fix "$_er" "$@" >"$_er/out.log" 2>&1 || _er_rc=$?
    [ "$_er_rc" -eq 3 ] || {
        cat "$_er/out.log"
        fail "$_er_label: expected exit 3, got $_er_rc"
    }
    [ "$(snapshot_of "$_er")" = "$_er_before" ] || fail "$_er_label: a refused run changed bytes"
    grep -q -- "$_er_pat" "$_er/out.log" || fail "$_er_label: refusal does not say '$_er_pat'"
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
expect_overrides "$p" bounded '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.0 <2",
    "@babel/traverse@7": ">=7.23.2 <8", "lodash@4": ">=4.18.1 <5", "tiny-zero@0.4": ">=0.4.9 <0.5"}'
for k in @babel/traverse@7 lodash@4 tiny-zero@0.4; do expect_below_marker "$p" bounded "$k"; done
[ "$(head_comment_of "$p" lodash@4)" = 'lodash@4: GHSA-35jh-r3h4-6jhm, GHSA-r5fr-rjxr-66jc.' ] ||
    fail "bounded: lodash@4 does not carry its advisory comment"
grep -qF "'@babel/traverse@7': '>=7.23.2 <8'" "$p/pnpm-workspace.yaml" || fail "bounded: floors must be single-quoted"
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
expect_overrides "$p" skip-refused '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.0 <2", "minimist@1": ">=1.2.6 <2"}'
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
expect_overrides "$p" raise-local '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.4 <2"}'
# yq attaches the end marker to the first key below it, so the head comment
# being rewritten here also carries the marker: it must survive.
expect_below_marker "$p" raise-local left-pad@1
[ "$(head_comment_of "$p" left-pad@1 | tail -n 1)" = 'left-pad@1: GHSA-0000-0000-0002.' ] || fail "raise-local: comment not refreshed"
! grep -qF 'GHSA-0000-0000-0001' "$p/pnpm-workspace.yaml" || fail "raise-local: the previous advisory comment was kept"
pass "raise-local: an existing lower floor is raised in place; the end marker in its head comment survives"

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

# ── 8. challenge round 1 shapes ───────────────────────────────────────

# One advisory spanning two installed majors (r1 finding 1): the 2.x floor is
# written, the 1.x row is refused, and the 1.x row still standing after the
# re-resolve must not roll the 2.x floor back.
p="$(new_project mixed-major)"
mixed_advisory() {
    jq -n --argjson findings "$1" '{advisories: {"GHSA-mmmm-mmmm-mmmm": {
        github_advisory_id: "GHSA-mmmm-mmmm-mmmm", module_name: "mm", severity: "high",
        vulnerable_versions: "<2.5.0", findings: $findings}}}'
}
mixed_advisory '[{"version":"1.9.0","paths":[".>old-dep>mm"]},{"version":"2.4.0","paths":[".>new-dep>mm"]}]' >"$p/.stub/audit.json"
mixed_advisory '[{"version":"1.9.0","paths":[".>old-dep>mm"]}]' >"$p/.stub/audit-after.json"
fix_writes "$p" '  mm@<2.5.0: ^2.5.0'
echo "mm@2: '>=2.5.0 <3'" >"$p/.stub/cleared-by"
rc=0
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
    cat "$p/out.log"
    fail "mixed-major: expected exit 0, got $rc"
}
expect_overrides "$p" mixed-major '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.0 <2", "mm@2": ">=2.5.0 <3"}'
grep -qF '| 1.9.0 | **refused:** the fix (2.5.0) crosses from major 1 to major 2' "$p/report.md" ||
    fail "mixed-major: the 1.x refusal is missing from the report"
pass "mixed-major: clearance is judged per major — a refused 1.x row does not roll back the 2.x floor"

# Any failure after a write restores the snapshot (r1 finding 2): here the
# post-install audit is malformed, so jq itself fails under set -e.
p="$(new_project trap-restore)"
advisory GHSA-0000-0000-0004 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
echo '{"advisories":{"x":{"severity":"high","findings":5}}}' >"$p/.stub/audit-after.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
before="$(snapshot_of "$p")"
rc=0
run_fix "$p" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "trap-restore: a malformed post-install audit must fail"
[ "$(snapshot_of "$p")" = "$before" ] ||
    fail "trap-restore: an unexpected failure after the write left the workspace file or lockfile changed"
pass "trap-restore: an unexpected failure after the write restores every byte"

# No keep-as-is branch (r1 finding 3, restructured in r2 finding 2): every
# floor the script touches is rewritten in the canonical shape
# '>=max(existing lower, proposal) <next-major'. A stricter existing lower
# bound survives as the lower bound; the upper bound is always canonical; the
# stale lockfile is re-resolved; the report names the floor in the file.
# existing_floor NAME VALUE — a project whose local left-pad@1 entry is VALUE
# and whose stale lockfile still reports a left-pad 1.3.1 advisory.
existing_floor() {
    _ef="$(new_project "$1")"
    awk -v v="$2" '/^  left-pad@1: / { print "  left-pad@1: " v; next } { print }' "$_ef/pnpm-workspace.yaml" >"$_ef/ws.tmp" &&
        mv "$_ef/ws.tmp" "$_ef/pnpm-workspace.yaml"
    advisory GHSA-0000-0000-0005 left-pad high '<1.3.4' 1.3.1 left-pad | jq '{advisories: .}' >"$_ef/.stub/audit.json"
    fix_writes "$_ef" '  left-pad@<1.3.4: ^1.3.4'
    : >"$_ef/.stub/needs-relock"
    echo "$_ef"
}

# expect_floor PROJECT LABEL FLOOR — exactly one left-pad@1 entry, canonical,
# at FLOOR; lockfile re-resolved; the report names that floor and no other.
expect_floor() {
    echo "left-pad@1: '>=$3 <2'" >"$1/.stub/cleared-by"
    run_fix "$1" --report "$1/report.md" >"$1/out.log" 2>&1 || {
        cat "$1/out.log"
        fail "$2: exited non-zero"
    }
    expect_overrides "$1" "$2" "{\"source-map-js@1\": \">=1.2.2 <2\", \"left-pad@1\": \">=$3 <2\"}"
    grep -qF "left-pad@1: '>=$3 <2'" "$1/pnpm-workspace.yaml" || fail "$2: the floor is not written in the single-quoted canonical form"
    expect_below_marker "$1" "$2" left-pad@1
    grep -qx '# relocked' "$1/pnpm-lock.yaml" || fail "$2: the stale lockfile was not re-resolved"
    grep -qF "floor \`left-pad@1: '>=$3 <2'\`" "$1/report.md" || fail "$2: report must name the floor in the file"
    [ "$3" = 1.3.4 ] || ! grep -qF "'>=1.3.4" "$1/report.md" || fail "$2: report names a floor that was not written"
}

p="$(existing_floor bounded-higher "'>=1.3.8 <2'")"
expect_floor "$p" bounded-higher 1.3.8
pass "bounded-higher: a stricter bounded floor keeps its lower bound in the canonical shape, lockfile re-resolved"

# A consumer-written upper bound past the major ('<3') is never kept: it could
# let the re-resolve cross into 2.x while the 1.x row reads as cleared.
p="$(existing_floor wide-bound "'>=1.3.8 <3'")"
expect_floor "$p" wide-bound 1.3.8
pass "wide-bound: an upper bound past the next major is replaced by the canonical one"

# An inline comment after the value does not hide the existing floor (r2
# finding 1): the stricter lower bound is still never lowered.
p="$(existing_floor inline-comment "'>=1.3.8 <2' # pinned for the CVE backport")"
expect_floor "$p" inline-comment 1.3.8
pass "inline-comment: a trailing comment after a quoted floor is parsed, the floor is not lowered"

p="$(existing_floor caret-higher '^1.3.8')"
expect_floor "$p" caret-higher 1.3.8
pass "caret-higher: an existing caret floor keeps its lower bound in the canonical shape and is re-resolved"

# A column-zero comment inside the overrides map does not end the map (r1
# finding 4): the fix is still read, and the floor lands after the local entries.
p="$(new_project col0-comment)"
awk -v be="$BLOCK_END" '{ print } $0 == be { print "# a column-zero note inside the map" }' "$p/pnpm-workspace.yaml" >"$p/ws.tmp" &&
    mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0007 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "col0-comment: exited non-zero"
}
grep -q 'no patched version' "$p/out.log" && fail "col0-comment: the column-zero comment hid the fix (false refusal)"
expect_overrides "$p" col0-comment '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.0 <2", "lodash@4": ">=4.17.21 <5"}'
expect_below_marker "$p" col0-comment lodash@4
pass "col0-comment: a column-zero comment inside the map is transparent"

# A column-zero end marker (r2 finding 3) lies outside the overrides map, so
# yq cannot append below it: the script refuses instead of moving YAML lines.
# (An indented marker — the rendered shape — holds by construction: see
# bounded and raise-local.)
p="$(new_project col0-marker)"
awk -v be="$BLOCK_END" '$0 == be { print substr(be, 3); next } /left-pad@1/ { next } { print }' \
    "$p/pnpm-workspace.yaml" >"$p/ws.tmp" && mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0009 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
expect_refused "$p" col0-marker 'indent the marker into the overrides map'
pass "col0-marker: a column-zero end marker is refused, never written above"

# An advisory that appears only after the re-resolve (r2 observation 4) is
# listed in the report, never hidden behind a passing clearance check.
p="$(new_project new-after-relock)"
advisory GHSA-0000-0000-0010 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
advisory GHSA-0000-0000-0011 undici high '<7.30.0' 7.29.0 astro | jq '{advisories: .}' >"$p/.stub/audit-after.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "new-after-relock: exited non-zero"
}
grep -qF -- '- GHSA-0000-0000-0011 — `undici` 7.29.0 (high): new, not fixed by this run' "$p/report.md" ||
    fail "new-after-relock: the post-relock advisory is missing from the report"
pass "new-after-relock: an advisory first seen after the re-resolve is listed as new, not fixed"

# ── 9. challenge round 3 shapes: yq reads and writes the map ──────────

# Existing floors whose lower bound only a real range reader gets right (r3
# finding 1): yq hands back a clean scalar, floor_lower reads it once.
for spec in \
    "ws-quotes|' >= 1.3.8 < 2 '|1.3.8" \
    "eq-space|'= 1.3.8'|1.3.8" \
    "strict-gt|'>1.3.8'|1.3.9" \
    "hyphen|'1.3.8 - 1.9.0'|1.3.8" \
    "or-range|'>=1.5.0 <2 || >=1.3.8 <1.4.0'|1.3.8" \
    "folded|>-\\n    >=1.3.8\\n    <2|1.3.8"; do
    name="${spec%%|*}" rest="${spec#*|}"
    p="$(existing_floor "$name" "${rest%|*}")"
    expect_floor "$p" "$name" "${rest##*|}"
    pass "$name: the existing floor's lower bound is read from yq's scalar and never lowered"
done

# `overrides: # comment` and `overrides: {}` are just the map (r3 finding 2):
# no second map is appended.
for spec in "header-comment|overrides: # local floors" "empty-flow|overrides: {}"; do
    name="${spec%%|*}"
    p="$(new_project "$name")"
    printf 'allowBuilds:\n  esbuild: true\n%s\n\n# trailer\n' "${spec#*|}" >"$p/pnpm-workspace.yaml"
    advisory GHSA-0000-0000-0012 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
    echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
    run_fix "$p" >"$p/out.log" 2>&1 || {
        cat "$p/out.log"
        fail "$name: exited non-zero"
    }
    expect_overrides "$p" "$name" '{"lodash@4": ">=4.17.21 <5"}'
    [ "$(grep -c '^overrides:' "$p/pnpm-workspace.yaml")" -eq 1 ] || fail "$name: a second overrides map was written"
    pass "$name: the floor goes into the one existing overrides map"
done

# One marker without the other (r3 finding 3) is a refusal, not a guess.
p="$(new_project end-only)"
grep -vF -- "$BLOCK_START" "$p/pnpm-workspace.yaml" >"$p/ws.tmp" && mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0013 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
expect_refused "$p" end-only 'both template floor markers'
pass "end-only: an end marker without its start marker is refused, nothing written"

p="$(new_project start-only)"
grep -vF -- "$BLOCK_END" "$p/pnpm-workspace.yaml" >"$p/ws.tmp" && mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0014 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
expect_refused "$p" start-only 'both template floor markers'
pass "start-only: a start marker without its end marker is refused, nothing written"

# Tabs cannot indent YAML: yq refuses to parse it, and so does the script.
p="$(new_project tab-indent)"
advisory GHSA-0000-0000-0015 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
sed -i.bak "$(printf 's/^  /\t/')" "$p/pnpm-workspace.yaml" && rm -f "$p/pnpm-workspace.yaml.bak"
expect_refused "$p" tab-indent 'yq cannot parse'
pass "tab-indent: a workspace file yq cannot parse is refused, nothing written"

# A four-space map (r1 finding 5): yq owns indentation; the file re-parses and
# the floor sits below the end marker.
p="$(new_project four-space)"
sed -i.bak 's/^  /    /' "$p/pnpm-workspace.yaml" && rm -f "$p/pnpm-workspace.yaml.bak"
advisory GHSA-0000-0000-0008 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "four-space: exited non-zero"
}
expect_overrides "$p" four-space '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.0 <2", "lodash@4": ">=4.17.21 <5"}'
expect_below_marker "$p" four-space lodash@4
pass "four-space: yq normalizes the indentation; the floor parses and sits below the end marker"

# Without yq the script refuses before touching anything (r4 prep). The case
# runs on a PATH of links to just the tools the script needs, so a yq anywhere
# on the host PATH (e.g. /usr/bin on a hosted runner) cannot leak in.
p="$(new_project no-yq)"
advisory GHSA-0000-0000-0016 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
mkdir -p "$p/.nobin"
for tool in bash env jq awk sed grep cut sort uniq comm cat cp cmp mktemp rm head tail tr dirname; do
    ln -s "$(command -v "$tool")" "$p/.nobin/$tool"
done
ln -s "$TMPROOT/bin/pnpm" "$p/.nobin/pnpm"
before="$(snapshot_of "$p")"
rc=0
(cd "$p" && PATH="$p/.nobin" STUB_DIR="$p/.stub" ./scripts/security-audit-fix.sh fix) >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 3 ] || {
    cat "$p/out.log"
    fail "no-yq: expected exit 3, got $rc"
}
[ "$(snapshot_of "$p")" = "$before" ] || fail "no-yq: a run without yq changed bytes"
grep -q 'yq (mikefarah v4) is required' "$p/out.log" || fail "no-yq: refusal does not name yq"
grep -q 'setup action' "$p/out.log" || fail "no-yq: refusal does not point at the setup action"
! grep -q -- '--fix' "$p/.stub/calls" || fail "no-yq: ran pnpm audit --fix before refusing"
pass "no-yq: a missing yq is a refusal before anything is touched"

# ── 10. publish: one rolling draft PR, scope-checked patch ─────────────
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
