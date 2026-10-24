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
# Overrides resolve as pnpm 11's do (probed on 11.28.5): in map order, the last
# matching entry wins, so any later key for the same package (bare `pkg`, or
# a `pkg@<selector>`) outranks a cleared-by `pkg@<major>` key and the
# advisory stays open — except a key that is another line's exact
# `pkg@<major-key>`, exempt by its key alone (that key selects a disjoint
# line). A parent-scoped `parent>pkg…` key outranks it in either order (pnpm
# prefers the parent-scoped key), so it keeps it open too.
set -euo pipefail
echo "pnpm $*" >>"$STUB_DIR/calls"
outranked() {
    [ -f "$STUB_DIR/cleared-by" ] || return 1
    yq -r '.overrides // {} | keys | .[]' pnpm-workspace.yaml >"$STUB_DIR/keys.order"
    while IFS= read -r line; do
        k="${line%%: *}"
        awk -v k="$k" -v b="${k%@*}" '
            function disjoint(x,   m) { m = substr(x, length(b) + 2); return m ~ /^[1-9][0-9]*$/ || m ~ /^0\.[0-9]+$/ }
            $0 == k { seen = 1; next }
            seen && ($0 == b || (index($0, b "@") == 1 && !disjoint($0))) { found = 1 }
            { p = index($0, ">" b); r = substr($0, p + 1 + length(b)) }
            p && (r == "" || substr(r, 1, 1) == "@") { found = 1 }
            END { exit !found }' \
            "$STUB_DIR/keys.order" && return 0
    done <"$STUB_DIR/cleared-by"
    return 1
}
case "$*" in
"--version") cat "$STUB_DIR/version" ;;
"audit --audit-level=high --json")
    if [ -f "$STUB_DIR/cleared-by" ] && grep -qF -f "$STUB_DIR/cleared-by" pnpm-workspace.yaml && ! outranked &&
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
"audit --fix --audit-level=high" | "audit --fix=override --audit-level=high")
    major="$(cut -d. -f1 "$STUB_DIR/version")"
    if [ "$major" -ge 11 ] && [ "$2" = --fix ]; then
        echo '[ERR_PNPM_INVALID_FIX_OPTION] Invalid value for --fix: --audit-level=high. Should be one of "override" or "update"' >&2
        exit 1
    fi
    if [ "$major" -eq 10 ] && [ "$2" != --fix ]; then
        echo 'pnpm 10 stub: --fix must be a boolean' >&2
        exit 1
    fi
    cat "$STUB_DIR/fixed.yaml" >pnpm-workspace.yaml
    echo "overrides were added to pnpm-workspace.yaml"
    ;;
"install --lockfile-only --ignore-scripts")
    # requires-exclude: an entry the re-resolve needs in minimumReleaseAgeExclude
    # (a patched release younger than the cooldown), as real pnpm would.
    if [ -f "$STUB_DIR/requires-exclude" ] &&
        ! yq -e ".minimumReleaseAgeExclude // [] | contains([\"$(cat "$STUB_DIR/requires-exclude")\"])" pnpm-workspace.yaml >/dev/null 2>&1; then
        echo "ERR_PNPM_NO_MATCHING_VERSION: the patched release is younger than minimumReleaseAge" >&2
        exit 1
    fi
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
"pr view")
    # lag-at N: the Nth view reports a stale head, as GitHub can for a few
    # seconds after a push.
    views=$(($(cat "$STUB_DIR/views" 2>/dev/null || echo 0) + 1))
    echo "$views" >"$STUB_DIR/views"
    if [ -f "$STUB_DIR/lag-at" ] && [ "$views" -eq "$(cat "$STUB_DIR/lag-at")" ]; then
        echo "0000000000000000000000000000000000000000 $(cat "$STUB_DIR/draft")"
    else
        echo "$(head_sha) $(cat "$STUB_DIR/draft")"
    fi
    ;;
"pr ready") echo true >"$STUB_DIR/draft" ;;
*) echo "gh stub: unexpected: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMPROOT/bin/pnpm" "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH"
# A credential-free run: git_remote must fall back to plain git.
unset GH_TOKEN GITHUB_TOKEN GH_APP_SLUG
# A local run: no audited commit, so publish skips the moved-base check unless
# a case sets GITHUB_SHA itself (CI exports it for this test's own job).
unset GITHUB_SHA GITHUB_ACTIONS

# ── Fixtures ─────────────────────────────────────────────────────────

# advisory ID PKG SEVERITY RANGE VERSION DIRECT [PATCHED] — one audit.json
# advisory entry (PATCHED absent: no patched_versions field).
advisory() {
    jq -n --arg id "$1" --arg pkg "$2" --arg sev "$3" --arg range "$4" --arg ver "$5" --arg direct "$6" --arg patched "${7:-}" '
        {($id): ({github_advisory_id: $id, module_name: $pkg, severity: $sev,
                 vulnerable_versions: $range,
                 findings: [{version: $ver, paths: [".>" + $direct + (if $direct == $pkg then "" else ">" + $pkg end)]}]}
                + (if $patched == "" then {} else {patched_versions: $patched} end))}'
}

# new_project NAME — a project whose workspace file carries the template block
# and a local floor, plus a stub state dir. Echoes the project path.
new_project() {
    _np="$TMPROOT/$1"
    mkdir -p "$_np/scripts" "$_np/.stub"
    cp "$REPO_ROOT/template/scripts/[% if use_node %]security-audit.sh[% endif %]" "$_np/scripts/security-audit.sh"
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
    echo 11.10.0 >"$_np/.stub/version"
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
    cp "$_rf/pnpm-workspace.yaml" "$_rf/.stub/ws.before"
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

# region_of FILE — the text from the start-marker line through the end-marker
# line, inclusive (fixed-string match, as the helper extracts it).
region_of() {
    awk -v bs="${BLOCK_START#  }" -v be="${BLOCK_END#  }" '
        index($0, bs) { on = 1 } on { print } on && index($0, be) { exit }' "$1"
}

# expect_below_marker PROJECT LABEL KEY — both markers present once each, the
# marker-to-marker text byte-identical to before the run, and KEY's line
# (found as text, like the markers) below the end marker.
expect_below_marker() {
    [ "$(grep -cF -- "${BLOCK_START#  }" "$1/pnpm-workspace.yaml")" -eq 1 ] &&
        [ "$(grep -cF -- "${BLOCK_END#  }" "$1/pnpm-workspace.yaml")" -eq 1 ] || fail "$2: a template marker was lost or repeated"
    [ "$(region_of "$1/pnpm-workspace.yaml")" = "$(region_of "$1/.stub/ws.before")" ] ||
        fail "$2: the template floor block changed"
    _eb_e="$(grep -nF -- "${BLOCK_END#  }" "$1/pnpm-workspace.yaml" | cut -d: -f1)"
    _eb_k="$(awk -v a="$3:" -v b="'$3':" '{ t = $0; sub(/^[[:space:]]+/, "", t) }
        index(t, a) == 1 || index(t, b) == 1 { print NR; exit }' "$1/pnpm-workspace.yaml")"
    [ -n "$_eb_k" ] && [ "$_eb_k" -gt "$_eb_e" ] || fail "$2: $3 is not below the end marker"
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

# Version agreement uses the running pnpm, not a template-owned version pin.
for major in 10 11 12; do
    p="$(new_project "pnpm-$major")"
    echo "$major.10.0" >"$p/.stub/version"
    advisory GHSA-test-0000-0001 lodash high '<4.17.21' 4.17.20 lodash |
        jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
    echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
    run_fix "$p" >"$p/out.log" 2>&1 || {
        cat "$p/out.log"
        fail "pnpm $major: fix exited non-zero"
    }
    mode=--fix=override
    [ "$major" -ne 10 ] || mode=--fix
    grep -qx "pnpm audit $mode --audit-level=high" "$p/.stub/calls" ||
        fail "pnpm $major: wrong fix mode or severity filter"
    [ "$(grep -cx 'pnpm --version' "$p/.stub/calls")" -eq 1 ] || fail "pnpm $major: version not read exactly once"
    expect_overrides "$p" "pnpm $major" '{"source-map-js@1": ">=1.2.2 <2", "left-pad@1": ">=1.3.0 <2", "lodash@4": ">=4.17.21 <5"}'
    pass "pnpm $major: compatible fix mode applies a bounded floor"
done
for version in 9.15.0 13.0.0 garbage 11.bad; do
    p="$(new_project "unsupported-$version")"
    echo "$version" >"$p/.stub/version"
    before="$(snapshot_of "$p")"
    rc=0
    run_fix "$p" >"$p/out.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "pnpm $version: unsupported version succeeded"
    grep -qF "pnpm version '$version'" "$p/out.log" || fail "pnpm $version: diagnostic omits version"
    [ "$(snapshot_of "$p")" = "$before" ] || fail "pnpm $version: changed bytes"
    ! grep -q 'pnpm audit\|pnpm install' "$p/.stub/calls" || fail "pnpm $version: audited or installed before refusal"
    pass "pnpm $version: fails closed before auditing or editing"
done

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
[ "$(head_comment_of "$p" lodash@4)" = 'security-audit-fix: lodash@4 — GHSA-35jh-r3h4-6jhm, GHSA-r5fr-rjxr-66jc' ] ||
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
[ "$(head_comment_of "$p" left-pad@1 | tail -n 1)" = 'security-audit-fix: left-pad@1 — GHSA-0000-0000-0002' ] ||
    fail "raise-local: the tagged advisory comment was not written"
# The fixture's own `# left-pad@1: …` line is a consumer comment (untagged):
# it starts with the key, and it must survive (r4 finding 5).
grep -qF '# left-pad@1: GHSA-0000-0000-0001.' "$p/pnpm-workspace.yaml" || fail "raise-local: a consumer comment was dropped"
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
# floor the script touches is rewritten as '>=max(existing lower, proposal)
# UPPER'. A stricter existing lower bound survives as the lower bound; UPPER
# is <next-major unless the existing override provably caps the line lower
# (kept: see narrow-cap), and an override whose cap the script cannot read is
# refused (see unreadable-cap); the stale lockfile is re-resolved; the report
# names the floor in the file.
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
# The region-identity invariant catches it: the key lands between the
# markers. (An indented marker — the rendered shape — holds: see bounded,
# raise-local and the rendered fixture below.)
p="$(new_project col0-marker)"
awk -v be="$BLOCK_END" '$0 == be { print substr(be, 3); next } /left-pad@1/ { next } { print }' \
    "$p/pnpm-workspace.yaml" >"$p/ws.tmp" && mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0009 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  lodash@<4.17.21: ^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
expect_refused "$p" col0-marker 'changed the template floor block'
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
    "strict-gt|'>1.3.8'|1.3.9" \
    "folded|>-\\n    >=1.3.8\\n    <2|1.3.8" \
    "strict-minor|'>1.3'|1.4.0" \
    "strict-major|'>1'|1.3.4" \
    "conjunction|'>=1.2.0 >=1.3.8 <2'|1.3.8" \
    "conjunction-strict|'>=1.3.8 >1.2'|1.3.8"; do
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

# A four-space map (r1 finding 5): yq re-indents the whole file to two spaces,
# which rewrites the template block too, so the region-identity invariant
# refuses rather than reformat lines the template owns.
p="$(new_project four-space)"
sed -i.bak 's/^  /    /' "$p/pnpm-workspace.yaml" && rm -f "$p/pnpm-workspace.yaml.bak"
advisory GHSA-0000-0000-0008 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
expect_refused "$p" four-space 'is not two-space indented; yq would rewrite the template block'
pass "four-space: a write that would re-indent the template block is refused, nothing written"

# ── 10. challenge round 4 shapes: placement by region identity ────────

# The template's rendered pnpm-workspace.yaml, byte-for-byte: its five-line
# header comment, the shipped floor block, no local keys (r4 finding 1 — yq
# numbers lines from the first node after a leading comment, so line
# arithmetic refused every write on this file). Derived from the template
# source for the default web-astro answers (deploy_cloudflare_workers on);
# any other template tag fails the derivation loudly.
TEMPLATE_WS="$REPO_ROOT/template/[% if use_node %]pnpm-workspace.yaml[% endif %].jinja"
rendered_workspace() {
    awk '
        /^\[% if project_type == .web-app. %\]$/ { skip = 1; next }
        /^\[% else %\]$/ { skip = 0; next }
        /^\[% if deploy_cloudflare_workers %\]$/ { next }
        /^\[% endif %\]$/ { skip = 0; next }
        !skip { print }
    ' "$TEMPLATE_WS" >"$1"
    ! grep -q '\[%\|\[\[' "$1" || fail "rendered fixture: the template grew a tag this derivation does not render"
    yq '.' "$1" >/dev/null || fail "rendered fixture: the derived workspace file does not parse"
}

# new_variant NAME KIND — a project whose workspace file is KIND: base (the
# suite's fixture, one local key), rendered (the template's own file), or
# zero-local (base without its local key).
new_variant() {
    _nv="$(new_project "$1")"
    case "$2" in
    rendered) rendered_workspace "$_nv/pnpm-workspace.yaml" ;;
    zero-local)
        grep -v 'left-pad@1' "$_nv/pnpm-workspace.yaml" >"$_nv/ws.tmp" && mv "$_nv/ws.tmp" "$_nv/pnpm-workspace.yaml"
        ;;
    esac
    echo "$_nv"
}

# expect_keys PROJECT LABEL KEY=VALUE… — the map holds every KEY at VALUE, and
# every key it held before the run unchanged.
expect_keys() {
    _ek="$1" _ek_label="$2"
    shift 2
    _ek_want="$(yq -o=json -I=0 '.overrides // {}' "$_ek/.stub/ws.before")"
    for _kv in "$@"; do
        _ek_want="$(jq -c --arg k "${_kv%%=*}" --arg v "${_kv#*=}" '. + {($k): $v}' <<<"$_ek_want")"
    done
    expect_overrides "$_ek" "$_ek_label" "$_ek_want"
}

for kind in base rendered zero-local; do
    # One write.
    p="$(new_variant "one-$kind" "$kind")"
    advisory GHSA-0000-0000-0017 lodash high '<4.17.21' 4.17.20 lodash | jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
    echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
    run_fix "$p" >"$p/out.log" 2>&1 || {
        cat "$p/out.log"
        fail "one-$kind: exited non-zero"
    }
    expect_keys "$p" "one-$kind" 'lodash@4=>=4.17.21 <5'
    expect_below_marker "$p" "one-$kind" lodash@4
    pass "one-$kind: a single floor is written below the marker; the block is byte-identical"

    # Two writes in one run (where stale line numbers bit): the second write
    # sees the file the first one produced.
    p="$(new_variant "two-$kind" "$kind")"
    {
        advisory GHSA-0000-0000-0018 lodash high '<4.17.21' 4.17.20 lodash
        advisory GHSA-0000-0000-0019 @babel/traverse critical '<7.23.2' 7.22.0 vite
    } | jq -s 'add | {advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" 'lodash@<4.17.21' '^4.17.21' '@babel/traverse@<7.23.2' '^7.23.2'
    echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
    run_fix "$p" >"$p/out.log" 2>&1 || {
        cat "$p/out.log"
        fail "two-$kind: exited non-zero"
    }
    expect_keys "$p" "two-$kind" 'lodash@4=>=4.17.21 <5' '@babel/traverse@7=>=7.23.2 <8'
    expect_below_marker "$p" "two-$kind" lodash@4
    expect_below_marker "$p" "two-$kind" @babel/traverse@7
    pass "two-$kind: two floors in one run both land below the marker; the block is byte-identical"

    # Idempotent: a second run on the remediated file changes nothing.
    before="$(snapshot_of "$p")"
    run_fix "$p" >"$p/out2.log" 2>&1 || fail "two-$kind: second run exited non-zero"
    [ "$(snapshot_of "$p")" = "$before" ] || fail "two-$kind: second run changed bytes"
    pass "idempotent-$kind: a second run is a byte-identical no-op"

    # A template-owned key is refused, never edited.
    p="$(new_variant "owned-$kind" "$kind")"
    advisory GHSA-0000-0000-0020 source-map-js high '<1.2.3' 1.2.2 postcss | jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" 'source-map-js@<1.2.3' '^1.2.3'
    expect_refused "$p" "owned-$kind" 'template-owned floor'
    pass "owned-$kind: a key between the markers is template-owned and refused"
done

# The script's own advisory comment is tagged, so a rewrite replaces only it
# (r4 finding 5): an older tagged line goes, a consumer line stays.
p="$(new_project tagged-replace)"
awk '/^  # left-pad@1: GHSA-0000-0000-0001\.$/ { print; print "  # security-audit-fix: left-pad@1 — GHSA-0000-0000-0099"; next } { print }' \
    "$p/pnpm-workspace.yaml" >"$p/ws.tmp" && mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0021 left-pad high '<1.3.4' 1.3.1 left-pad | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'left-pad@<1.3.4' '^1.3.4'
echo "left-pad@1: '>=1.3.4 <2'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "tagged-replace: exited non-zero"
}
! grep -qF 'GHSA-0000-0000-0099' "$p/pnpm-workspace.yaml" || fail "tagged-replace: the old tagged comment was kept"
grep -qF '# left-pad@1: GHSA-0000-0000-0001.' "$p/pnpm-workspace.yaml" || fail "tagged-replace: the consumer comment was dropped"
grep -qF '# security-audit-fix: left-pad@1 — GHSA-0000-0000-0021' "$p/pnpm-workspace.yaml" || fail "tagged-replace: new tagged comment missing"
expect_below_marker "$p" tagged-replace left-pad@1
pass "tagged-replace: only the script's own tagged comment is replaced"

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

# ── 11. challenge round 5 shapes ──────────────────────────────────────

# Nested advisories (r5 finding 1): pnpm prunes the advisory another one on
# the same package already covers, so --fix emits ONE override for two.
# Matching by package and coverage fixes both with one canonical floor.
p="$(new_project nested)"
{
    advisory GHSA-35jh-r3h4-6jhm lodash high '<4.17.21' 4.17.20 lodash '>=4.17.21'
    advisory GHSA-r5fr-rjxr-66jc lodash high '>=4.0.0 <=4.17.23' 4.17.20 lodash '>=4.18.1'
} | jq -s 'add | {advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@>=4.0.0 <=4.17.23' '^4.18.1'
echo "lodash@4: '>=4.18.1 <5'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "nested: exited non-zero (a covered advisory must not be refused)"
}
expect_keys "$p" nested 'lodash@4=>=4.18.1 <5'
for id in GHSA-35jh-r3h4-6jhm GHSA-r5fr-rjxr-66jc; do
    grep -qF "| $id | \`lodash\` | high | 4.17.20 | floor \`lodash@4: '>=4.18.1 <5'\` |" "$p/report.md" ||
        fail "nested: $id is not reported as fixed by the one floor"
done
[ "$(head_comment_of "$p" lodash@4)" = 'security-audit-fix: lodash@4 — GHSA-35jh-r3h4-6jhm, GHSA-r5fr-rjxr-66jc' ] ||
    fail "nested: the floor's comment does not name both advisories"
pass "nested: one pruned proposal covers two nested advisories — one canonical floor, both fixed"

# A patched release younger than pnpm's cooldown (r5 finding 2): --fix also
# adds it to minimumReleaseAgeExclude, and the re-resolve needs it, so the
# entry is carried through the byte restore with yq and reported.
p="$(new_project cooldown)"
advisory GHSA-0000-0000-0022 lodash high '<4.17.21' 4.17.20 lodash '>=4.17.21' | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
yq -i '.minimumReleaseAgeExclude = ["lodash@4.17.21"]' "$p/.stub/fixed.yaml"
echo 'lodash@4.17.21' >"$p/.stub/requires-exclude"
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "cooldown: exited non-zero (the exclusion pnpm added was dropped)"
}
[ "$(yq -o=json -I=0 '.minimumReleaseAgeExclude' "$p/pnpm-workspace.yaml")" = '["lodash@4.17.21"]' ] ||
    fail "cooldown: minimumReleaseAgeExclude was not carried through"
expect_keys "$p" cooldown 'lodash@4=>=4.17.21 <5'
expect_below_marker "$p" cooldown lodash@4
grep -qF -- '- `lodash@4.17.21`' "$p/report.md" || fail "cooldown: the carried exclusion is not reported"
pass "cooldown: pnpm's minimumReleaseAgeExclude addition survives the restore and is reported"

# An advisory with an empty github_advisory_id (r5 finding 3) gets the
# synthetic npm-<number>; the row keeps its columns.
p="$(new_project empty-id)"
jq -n '{advisories: {"1097678": {id: 1097678, github_advisory_id: "", module_name: "lodash",
    severity: "high", vulnerable_versions: "<4.17.21", patched_versions: ">=4.17.21",
    findings: [{version: "4.17.20", paths: [".>lodash"]}]}}}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21'
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "empty-id: exited non-zero"
}
expect_keys "$p" empty-id 'lodash@4=>=4.17.21 <5'
[ "$(head_comment_of "$p" lodash@4)" = 'security-audit-fix: lodash@4 — npm-1097678' ] || fail "empty-id: comment lacks the synthetic id"
grep -qF "| npm-1097678 | \`lodash\` | high | 4.17.20 | floor \`lodash@4: '>=4.17.21 <5'\` |" "$p/report.md" ||
    fail "empty-id: the report row is missing or misaligned"
pass "empty-id: an advisory without a GHSA id is reported and commented as npm-<number>"

# ── 12. challenge round 6 shapes ──────────────────────────────────────

# A (r6 finding 2): pnpm re-emits an override identical to one already in the
# file (a raw `--fix` entry from before, with a stale lockfile). The proposal
# is the post-fix map, not its difference from the original, so the advisory
# is still fixed and the floor is written in the canonical shape.
# The stale entry sits BEFORE left-pad@1: one after it would outrank the
# rewritten key (last match wins) and is refused instead — see sel-after.
p="$(new_project identical)"
awk '/^  # left-pad@1: / { print "  left-pad@<1.3.4: ^1.3.4" } { print }' "$p/pnpm-workspace.yaml" >"$p/ws.tmp" &&
    mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0023 left-pad high '<1.3.4' 1.3.1 left-pad '>=1.3.4' | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'left-pad@<1.3.4' '^1.3.4'
echo "left-pad@1: '>=1.3.4 <2'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "identical: exited non-zero (an identical re-emitted proposal was ignored)"
}
expect_keys "$p" identical 'left-pad@1=>=1.3.4 <2'
expect_below_marker "$p" identical left-pad@1
pass "identical: a proposal identical to an existing entry still fixes the advisory, in the canonical shape"

# B (r6 finding 1): under --skip-refused, pnpm's cooldown exclusion for a
# REFUSED fix is dropped and reported; the applied fix's exclusion is carried.
p="$(new_project exclusion-refused)"
{
    advisory GHSA-0000-0000-0024 lodash high '<4.17.21' 4.17.20 lodash '>=4.17.21'
    advisory GHSA-8cf7-32gw-wr33 jsonwebtoken high '<=8.5.1' 8.5.1 jsonwebtoken '>=9.0.0'
} | jq -s 'add | {advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'lodash@<4.17.21' '^4.17.21' 'jsonwebtoken@<=8.5.1' '^9.0.0'
yq -i '.minimumReleaseAgeExclude = ["lodash@4.17.21", "jsonwebtoken@9.0.0"]' "$p/.stub/fixed.yaml"
echo 'lodash@4.17.21' >"$p/.stub/requires-exclude"
echo "lodash@4: '>=4.17.21 <5'" >"$p/.stub/cleared-by"
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "exclusion-refused: exited non-zero"
}
[ "$(yq -o=json -I=0 '.minimumReleaseAgeExclude' "$p/pnpm-workspace.yaml")" = '["lodash@4.17.21"]' ] ||
    fail "exclusion-refused: carried $(yq -o=json -I=0 '.minimumReleaseAgeExclude' "$p/pnpm-workspace.yaml"), expected only the applied fix's entry"
grep -qF -- '- `jsonwebtoken@9.0.0`' "$p/report.md" && grep -qF 'Dropped from' "$p/report.md" ||
    fail "exclusion-refused: the dropped exclusion is not reported"
grep -qF '**refused:** the fix (9.0.0) crosses from major 8 to major 9' "$p/report.md" ||
    fail "exclusion-refused: the refusal behind the dropped exclusion is not reported"
pass "exclusion-refused: only the applied fix's cooldown exclusion is carried; the refused one is reported as dropped"

# C (r6 finding 3): a patched range with one alternative per release line uses
# the alternative on the installed major — 2.0.1 needs 2.1.5, so a ^2.0.3
# proposal (another advisory's) does not count as fixing it.
p="$(new_project multi-range)"
{
    advisory GHSA-xxxx-xxxx-xxxx pkgz high '<1.3.4 || >=2.0.0 <2.1.5' 2.0.1 direct '>=1.3.4 <2.0.0 || >=2.1.5'
    advisory GHSA-yyyy-yyyy-yyyy pkgz high '<2.0.3' 2.0.1 direct '>=2.0.3'
} | jq -s 'add | {advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@<1.3.4 || >=2.0.0 <2.1.5' '^2.1.5' 'pkgz@<2.0.3' '^2.0.3'
echo "pkgz@2: '>=2.1.5 <3'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "multi-range: exited non-zero"
}
expect_keys "$p" multi-range 'pkgz@2=>=2.1.5 <3'
grep -qF "| GHSA-xxxx-xxxx-xxxx | \`pkgz\` | high | 2.0.1 | floor \`pkgz@2: '>=2.1.5 <3'\` |" "$p/report.md" ||
    fail "multi-range: the multi-range advisory is not fixed by the in-major floor"
pass "multi-range: the patched alternative on the installed major sets the need (2.1.5, not 1.3.4)"

# pnpm may propose only another patched line. The advisory's concrete patch
# on the installed line supplies the floor; it still needs lockfile and audit
# proof, and the report must associate it with the advisory it cleared.
p="$(new_project multi-range-other)"
advisory GHSA-xxxx-xxxx-xxxx pkgz high '<1.3.4 || >=2.0.0 <2.1.5' 2.0.1 direct '>=1.3.4 <2.0.0 || >=2.1.5' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@<1.3.4 || >=2.0.0 <2.1.5' '^1.3.4'
echo "pkgz@2: '>=2.1.5 <3'" >"$p/.stub/cleared-by"
: >"$p/.stub/needs-relock"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "multi-range-other: exited non-zero"
}
expect_keys "$p" multi-range-other 'pkgz@2=>=2.1.5 <3'
expect_below_marker "$p" multi-range-other pkgz@2
grep -qF "| GHSA-xxxx-xxxx-xxxx | \`pkgz\` | high | 2.0.1 | floor \`pkgz@2: '>=2.1.5 <3'\` |" "$p/report.md" ||
    fail "multi-range-other: the fallback floor is not reported"
grep -qx 'pnpm install --lockfile-only --ignore-scripts' "$p/.stub/calls" ||
    fail "multi-range-other: fallback skipped lockfile re-resolve"
[ "$(grep -c 'pnpm audit --audit-level=high --json' "$p/.stub/calls")" -eq 2 ] ||
    fail "multi-range-other: fallback skipped re-audit"
pass "multi-range-other: another-line proposal falls back to the installed patch, re-resolved and re-audited"

# An unaffected older line contributes only an upper bound to the union.
# Publication must be proved by the selected 2.x alternative, not by the
# whole range's lowest bound (0.0.0).
p="$(new_project multi-range-upper-only)"
advisory GHSA-xxxx-xxxx-xxxx pkgz high '>=2.0.0 <2.1.5' 2.0.1 direct '<2.0.0 || >=2.1.5' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@>=2.0.0 <2.1.5' '^1.3.4'
echo "pkgz@2: '>=2.1.5 <3'" >"$p/.stub/cleared-by"
: >"$p/.stub/needs-relock"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "multi-range-upper-only: exited non-zero"
}
expect_keys "$p" multi-range-upper-only 'pkgz@2=>=2.1.5 <3'
expect_below_marker "$p" multi-range-upper-only pkgz@2
grep -qx 'pnpm install --lockfile-only --ignore-scripts' "$p/.stub/calls" ||
    fail "multi-range-upper-only: fallback skipped lockfile re-resolve"
[ "$(grep -c 'pnpm audit --audit-level=high --json' "$p/.stub/calls")" -eq 2 ] ||
    fail "multi-range-upper-only: fallback skipped re-audit"
pass "multi-range-upper-only: the selected alternative supplies a published patch despite another line's zero lower bound"

# Integration cycle 1: choose the lowest plain patch strictly ABOVE the
# installed version. Old patched intervals and too-low in-major proposals
# must not hide a later fix; alternative order must not decide the floor.
for patch_case in gap-on-line gap-after-second lowest-unordered single-line-crossing; do
    case "$patch_case" in
    gap-on-line)
        installed=2.1.5 patched='>=2.0.0 <2.1.0 || >=2.2.0' proposal='^2.0.0' patch_floor=2.2.0
        ;;
    gap-after-second)
        installed=2.3.0 patched='>=1.9.0 <2.0.0 || >=2.1.0 <2.2.0 || >=2.4.0' proposal='^2.1.0' patch_floor=2.4.0
        ;;
    lowest-unordered)
        installed=2.1.5 patched='>=2.4.0 || >=2.2.0 || >=2.0.0 <2.1.0' proposal='^2.0.0' patch_floor=2.2.0
        ;;
    single-line-crossing)
        installed=2.0.1 patched='>=2.1.5' proposal='^3.0.0' patch_floor=2.1.5
        ;;
    esac
    p="$(new_project "$patch_case")"
    advisory GHSA-xxxx-xxxx-xxxx pkgz high "<$patch_floor" "$installed" direct "$patched" |
        jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" "pkgz@<$patch_floor" "$proposal"
    echo "pkgz@2: '>=${patch_floor} <3'" >"$p/.stub/cleared-by"
    : >"$p/.stub/needs-relock"
    run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
        cat "$p/out.log"
        fail "$patch_case: exited non-zero"
    }
    expect_keys "$p" "$patch_case" "pkgz@2=>=${patch_floor} <3"
    expect_below_marker "$p" "$patch_case" pkgz@2
    grep -qx 'pnpm install --lockfile-only --ignore-scripts' "$p/.stub/calls" ||
        fail "$patch_case: skipped lockfile re-resolve"
    [ "$(grep -c 'pnpm audit --audit-level=high --json' "$p/.stub/calls")" -eq 2 ] ||
        fail "$patch_case: skipped re-audit"
    pass "$patch_case: installed $installed gets published floor $patch_floor, relocked and re-audited"
done

# A suffix is not proof that its normalized release was published. Neither
# a prerelease nor a build-suffixed lower bound authorizes the union fallback.
suffix_iteration=0
for suffix_patch in '>=2.1.5-beta.1 <2.1.5' '>=2.1.5+build'; do
    suffix_iteration=$((suffix_iteration + 1))
    p="$(new_project "suffix-patch-$suffix_iteration")"
    advisory GHSA-xxxx-xxxx-xxxx pkgz high '<2.1.5' 2.0.1 direct "$suffix_patch || >=3.0.0" |
        jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" 'pkgz@<2.1.5' '^2.1.5'
    expect_refused "$p" suffix-patch 'no patched range on major 2'
    if grep -q 'install' "$p/.stub/calls"; then
        fail "suffix-patch: an unpublished plain release authorized a relock"
    fi
    pass "suffix-patch: $suffix_patch is not a published plain patch on major 2"
done

# A fallback that fails its audit proof rolls back all project bytes.
p="$(new_project multi-range-not-cleared)"
advisory GHSA-xxxx-xxxx-xxxx pkgz high '<1.3.4 || >=2.0.0 <2.1.5' 2.0.1 direct '>=1.3.4 <2.0.0 || >=2.1.5' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@<1.3.4 || >=2.0.0 <2.1.5' '^1.3.4'
before="$(snapshot_of "$p")"
rc=0
run_fix "$p" >"$p/out.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "multi-range-not-cleared: expected exit 1, got $rc"
[ "$(snapshot_of "$p")" = "$before" ] || fail "multi-range-not-cleared: fallback did not roll back"
grep -qx 'pnpm install --lockfile-only --ignore-scripts' "$p/.stub/calls" ||
    fail "multi-range-not-cleared: fallback never reached lockfile re-resolve"
pass "multi-range-not-cleared: an uncleared fallback rolls back every byte"

# A concrete patch on a different major is not an installed-line fallback.
# With no covering proposal, distinguish that from no patch being published.
p="$(new_project no-proposal-on-major)"
advisory GHSA-xxxx-xxxx-xxxx pkgz high '<3.1.5' 2.0.1 direct '>=3.1.5' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@<3.1.5' '^1.3.4'
expect_refused "$p" no-proposal-on-major 'no proposal on major 2'
pass "no-proposal-on-major: a published patch without a covering proposal names the installed line"

p="$(new_project no-patch-published)"
advisory GHSA-xxxx-xxxx-xxxx pkgz high '*' 2.0.1 direct '<0.0.0' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'unrelated@<1.3.4' '^1.3.4'
expect_refused "$p" no-patch-published 'no patched version published'
pass "no-patch-published: an advisory with no concrete patch remains refused"

# An inferred vulnerable-range boundary is not a published patch, even
# when it is concrete and belongs to the installed line.
inferred_iteration=0
for unpublished in '<0.0.0' ''; do
    inferred_iteration=$((inferred_iteration + 1))
    p="$(new_project "inferred-only-$inferred_iteration")"
    advisory GHSA-xxxx-xxxx-xxxx pkgz high '<2.1.5' 2.0.1 direct "$unpublished" |
        jq '{advisories: .}' >"$p/.stub/audit.json"
    fix_adds "$p" 'unrelated@<1.3.4' '^1.3.4'
    expect_refused "$p" inferred-only 'no patched version published'
    if grep -qF '(patched: )' "$p/out.log"; then
        fail "inferred-only: an absent patch printed empty patched metadata"
    fi
    if grep -q 'install' "$p/.stub/calls"; then
        fail "inferred-only: an inferred boundary authorized a floor"
    fi
    pass "inferred-only: patched '$unpublished' refuses with the no-published-patch reason"
done

# ... and an install on a line no alternative covers is refused.
p="$(new_project multi-range-none)"
advisory GHSA-zzzz-zzzz-zzzz pkgz high '<1.3.4 || >=2.0.0 <2.1.5' 0.9.0 direct '>=1.3.4 <2.0.0 || >=2.1.5' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@<1.3.4 || >=2.0.0 <2.1.5' '^1.3.4'
expect_refused "$p" multi-range-none 'no patched range on major 0.9'
pass "multi-range-none: no patched alternative on the installed line is a refusal"

# Review r1: the exclusion join is per release line, not per package. mm is
# installed on 1.x (the fix crosses to 2.x: refused) and 2.x (floored); pnpm
# adds a young-release exclusion for each line's patched release, and only
# the floored line's survives.
p="$(new_project exclusion-lines)"
jq -n '{advisories: {"GHSA-llll-llll-llll": {github_advisory_id: "GHSA-llll-llll-llll", module_name: "mm",
    severity: "high", vulnerable_versions: "<2.5.0", patched_versions: ">=2.5.0",
    findings: [{version: "1.9.0", paths: [".>old-dep>mm"]}, {version: "2.4.0", paths: [".>new-dep>mm"]}]}}}' >"$p/.stub/audit.json"
jq -n '{advisories: {"GHSA-llll-llll-llll": {github_advisory_id: "GHSA-llll-llll-llll", module_name: "mm",
    severity: "high", vulnerable_versions: "<2.5.0", patched_versions: ">=2.5.0",
    findings: [{version: "1.9.0", paths: [".>old-dep>mm"]}]}}}' >"$p/.stub/audit-after.json"
fix_adds "$p" 'mm@<2.5.0' '^2.5.0'
yq -i '.minimumReleaseAgeExclude = ["mm@1.9.9", "mm@2.5.0"]' "$p/.stub/fixed.yaml"
echo 'mm@2.5.0' >"$p/.stub/requires-exclude"
echo "mm@2: '>=2.5.0 <3'" >"$p/.stub/cleared-by"
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "exclusion-lines: exited non-zero"
}
[ "$(yq -o=json -I=0 '.minimumReleaseAgeExclude' "$p/pnpm-workspace.yaml")" = '["mm@2.5.0"]' ] ||
    fail "exclusion-lines: carried $(yq -o=json -I=0 '.minimumReleaseAgeExclude' "$p/pnpm-workspace.yaml"), expected only the floored line's entry"
grep -qF -- '- `mm@1.9.9`' "$p/report.md" && grep -qF 'Dropped from' "$p/report.md" ||
    fail "exclusion-lines: the refused line's exclusion is not reported as dropped"
expect_keys "$p" exclusion-lines 'mm@2=>=2.5.0 <3'
pass "exclusion-lines: a cooldown exclusion is carried only for the release line that was floored"

# ── 13. integration cycle 1 shapes ────────────────────────────────────

# A local cap below the next major (Codex 4242265056) is kept when the new
# floor still fits under it…
p="$(existing_floor narrow-cap "'>=1.3.0 <1.8.0'")"
echo "left-pad@1: '>=1.3.4 <1.8.0'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "narrow-cap: exited non-zero"
}
expect_keys "$p" narrow-cap 'left-pad@1=>=1.3.4 <1.8.0'
expect_below_marker "$p" narrow-cap left-pad@1
grep -qF "floor \`left-pad@1: '>=1.3.4 <1.8.0'\`" "$p/report.md" || fail "narrow-cap: report does not name the kept cap"
pass "narrow-cap: a local upper bound below the next major is kept above the raised floor"

# … and refused when the patched version is at or above it, with the package
# and the override in code spans so a scoped name is not a mention (#1635).
p="$(existing_floor cap-below-patch "'>=1.3.0 <1.3.4'")"
expect_refused "$p" cap-below-patch "the local override \`left-pad@1: '>=1.3.0 <1.3.4'\` caps \`left-pad\` below the patched version 1.3.4"
pass "cap-below-patch: a local cap at or below the patched version is refused, nothing written"

# ── 14. #1635: prove the cap or refuse ────────────────────────────────

# An existing override whose cap is implicit is never widened to <next-major:
# the script reads only comparators and `^` on major 1+, and refuses every
# other shape, naming the override and writing nothing.
for spec in \
    "pin-exact|1.3.9" \
    "pin-eq|'=1.3.9'" \
    "pin-eq-space|'= 1.3.8'" \
    "tilde|'~1.3.0'" \
    "x-range|1.3.x" \
    "partial|'1.3'" \
    "hyphen|'1.3.8 - 1.9.0'" \
    "or-range|'>=1.5.0 <2 || >=1.3.8 <1.4.0'" \
    "x-comparator|'>=1.3.x <2'" \
    "or-unspaced|'>=1.3.0 <1.8.0-beta.1||>=2.0.0 <3'" \
    "prerelease-cap|'<1.8.0-beta.1'" \
    "build-suffix|'>=1.3.0+build'" \
    "v-prefix|v1.3.0"; do
    name="${spec%%|*}" val="${spec#*|}"
    p="$(existing_floor "unreadable-$name" "$val")"
    shown="$(yq '.overrides["left-pad@1"]' "$p/pnpm-workspace.yaml")"
    expect_refused "$p" "unreadable-$name" "the local override \`left-pad@1: '$shown'\` has a cap the script cannot read"
    pass "unreadable-$name: an override with an implicit cap ($shown) is refused, bytes unchanged"
done

# … and listed, not applied, under --skip-refused.
p="$(existing_floor unreadable-skip "'~1.3.0'")"
before="$(snapshot_of "$p")"
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "unreadable-skip: exited non-zero"
}
[ "$(snapshot_of "$p")" = "$before" ] || fail "unreadable-skip: the refused key was written"
grep -qF "| GHSA-0000-0000-0005 | \`left-pad\` | high | 1.3.1 | **refused:** the local override \`left-pad@1: '~1.3.0'\` has a cap" "$p/report.md" ||
    fail "unreadable-skip: the refusal is not listed in the report"
pass "unreadable-skip: --skip-refused lists the unreadable-cap refusal and writes nothing for it"

# A 0.x caret caps at the next minor or patch: not read, refused.
p="$(new_project unreadable-caret-zero)"
awk '/^  left-pad@1: / { print; print "  tiny@0.4: '"'"'^0.4.0'"'"'"; next } { print }' "$p/pnpm-workspace.yaml" >"$p/ws.tmp" &&
    mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
advisory GHSA-0000-0000-0040 tiny high '<0.4.3' 0.4.1 tiny | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  tiny@<0.4.3: ^0.4.3'
expect_refused "$p" unreadable-caret-zero "the local override \`tiny@0.4: '^0.4.0'\` has a cap the script cannot read"
pass "unreadable-caret-zero: a ^0.x override is refused, bytes unchanged"

# add_entry PROJECT KEY VALUE [after] — a `KEY: VALUE` override before
# left-pad@1 (its head comment), or after it with `after`, and the `--fix`
# result recomputed over it.
add_entry() {
    awk -v e="  $2: $3" -v after="${4:-}" '
        after == "" && /^  # left-pad@1: / { print e }
        { print }
        after != "" && /^  left-pad@1: / { print e }' "$1/pnpm-workspace.yaml" >"$1/ws.tmp" &&
        mv "$1/ws.tmp" "$1/pnpm-workspace.yaml"
    fix_writes "$1" '  left-pad@<1.3.4: ^1.3.4'
}

# pnpm 11 applies the LAST matching override in map order (probed on pnpm
# 11.28.5 with `semver` and `semver@7` in both orders), so a bare `pkg` entry
# caps the line as well: an unreadable one is refused…
p="$(existing_floor bare-unreadable "'>=1.3.0 <2'")"
add_entry "$p" left-pad "'1.3.2'"
expect_refused "$p" bare-unreadable "the local override \`left-pad: '1.3.2'\` has a cap the script cannot read"
pass "bare-unreadable: a bare override with an implicit cap is refused, bytes unchanged"

# … and a readable narrow one is kept on the floor this script writes.
p="$(existing_floor bare-narrow "'>=1.3.0 <2'")"
add_entry "$p" left-pad "'>=1.0.0 <1.8.0'"
echo "left-pad@1: '>=1.3.4 <1.8.0'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "bare-narrow: exited non-zero"
}
expect_keys "$p" bare-narrow 'left-pad@1=>=1.3.4 <1.8.0'
[ "$(yq -r '.overrides | keys | .[]' "$p/pnpm-workspace.yaml" | grep -n '^left-pad' | tr '\n' ' ')" = '2:left-pad 3:left-pad@1 ' ] ||
    fail "bare-narrow: the bare entry no longer precedes the rewritten key"
pass "bare-narrow: a bare override's narrower cap is kept on the written floor"

# A bare entry AFTER the existing key outranks it (last match wins), so the
# rewrite would not be what pnpm applies: refused, even when its cap is readable.
p="$(existing_floor bare-after-keyed "'>=1.3.0 <2'")"
add_entry "$p" left-pad "'>=1.0.0 <1.8.0'" after
echo "left-pad@1: '>=1.3.4 <1.8.0'" >"$p/.stub/cleared-by"
expect_refused "$p" bare-after-keyed "a later \`left-pad\` override for \`left-pad\` takes precedence over \`left-pad@1\` — reorder or remove it deliberately"
pass "bare-after-keyed: a bare override after the keyed one is refused, bytes unchanged"

# A bare entry with no `pkg@<major>` key yet: the key is appended after it, and
# the bare entry's cap is honoured on the written floor…
# no_key PROJECT BARE — drop the fixture's left-pad@1 entry (and its comment)
# for a bare `left-pad: BARE`.
no_key() {
    awk -v e="  left-pad: $2" '/^  # left-pad@1: / { print e; next } /^  left-pad@1: / { next } { print }' \
        "$1/pnpm-workspace.yaml" >"$1/ws.tmp" && mv "$1/ws.tmp" "$1/pnpm-workspace.yaml"
    fix_writes "$1" '  left-pad@<1.3.4: ^1.3.4'
}
p="$(existing_floor bare-no-key "'>=1.3.0 <2'")"
no_key "$p" "'>=1.0.0 <1.8.0'"
echo "left-pad@1: '>=1.3.4 <1.8.0'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "bare-no-key: exited non-zero"
}
expect_keys "$p" bare-no-key 'left-pad@1=>=1.3.4 <1.8.0'
[ "$(yq -r '.overrides | keys | .[]' "$p/pnpm-workspace.yaml" | grep -n '^left-pad' | tr '\n' ' ')" = '2:left-pad 3:left-pad@1 ' ] ||
    fail "bare-no-key: the new key is not appended after the bare entry"
pass "bare-no-key: with no keyed entry, the floor is appended after the bare one and keeps its cap"

# … or the row refused when that cap sits at or below the patched version.
p="$(existing_floor bare-no-key-low "'>=1.3.0 <2'")"
no_key "$p" "'>=1.0.0 <1.3.2'"
expect_refused "$p" bare-no-key-low "the local override \`left-pad: '>=1.0.0 <1.3.2'\` caps \`left-pad\` below the patched version 1.3.4"
pass "bare-no-key-low: a bare cap below the patched version is refused with no keyed entry, bytes unchanged"

# Every override that targets the package counts, not just bare and major
# keys (Claude 6113822819): pnpm applies the last match in map order to
# selector keys too (probed: `semver@<7.6.0` after `semver@7` wins, before it
# loses). A selector before the key caps the floor…
p="$(existing_floor sel-before "'>=1.3.0 <2'")"
add_entry "$p" 'left-pad@<1.9.0' "'>=1.0.0 <1.8.0'"
echo "left-pad@1: '>=1.3.4 <1.8.0'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "sel-before: exited non-zero"
}
expect_keys "$p" sel-before 'left-pad@1=>=1.3.4 <1.8.0'
pass "sel-before: a selector override's narrower cap is kept on the written floor"

# Only the written key's own entry raises the lower bound (Codex 4243949546):
# a selector's lower bound need not apply to the installed version, so
# `left-pad@>=1.8.0` with 1.3.1 installed leaves the floor at 1.3.4.
p="$(existing_floor sel-lower "'>=1.3.0 <2'")"
add_entry "$p" 'left-pad@>=1.8.0' "'>=1.8.0 <2'"
echo "left-pad@1: '>=1.3.4 <2'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "sel-lower: exited non-zero"
}
expect_keys "$p" sel-lower 'left-pad@1=>=1.3.4 <2'
pass "sel-lower: a selector's lower bound does not raise the written floor"

# … nor with no `left-pad@1` key: the floor is appended at the patched
# version, last in the map, so it supersedes the selector's lower bound.
p="$(existing_floor sel-lower-no-key "'>=1.3.0 <2'")"
awk '/^  # left-pad@1: / { next } /^  left-pad@1: / { print "  left-pad@>=1.0.0: '"'"'>=1.8.0'"'"'"; next } { print }' \
    "$p/pnpm-workspace.yaml" >"$p/ws.tmp" && mv "$p/ws.tmp" "$p/pnpm-workspace.yaml"
fix_writes "$p" '  left-pad@<1.3.4: ^1.3.4'
echo "left-pad@1: '>=1.3.4 <2'" >"$p/.stub/cleared-by"
run_fix "$p" --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "sel-lower-no-key: exited non-zero"
}
expect_keys "$p" sel-lower-no-key 'left-pad@1=>=1.3.4 <2'
[ "$(yq -r '.overrides | keys | .[-1]' "$p/pnpm-workspace.yaml")" = left-pad@1 ] ||
    fail "sel-lower-no-key: the appended left-pad@1 key is not last"
pass "sel-lower-no-key: with no keyed entry, the floor is appended last at the patched version"

# … or refuses it when the cap sits at or below the patched version…
p="$(existing_floor sel-before-low "'>=1.3.0 <2'")"
add_entry "$p" 'left-pad@<1.5.0' "'>=1.0.0 <1.3.2'"
expect_refused "$p" sel-before-low "the local override \`left-pad@<1.5.0: '>=1.0.0 <1.3.2'\` caps \`left-pad\` below the patched version 1.3.4"
pass "sel-before-low: a selector cap below the patched version is refused, bytes unchanged"

# … an unreadable selector-scoped value (a pin) is refused, as is a
# parent-scoped one…
p="$(existing_floor sel-unreadable "'>=1.3.0 <2'")"
add_entry "$p" 'left-pad@<1.5.0' "1.4.2"
expect_refused "$p" sel-unreadable "the local override \`left-pad@<1.5.0: '1.4.2'\` has a cap the script cannot read"
pass "sel-unreadable: a selector override pinning the package is refused, bytes unchanged"

# A parent-scoped override outranks `pkg@<major>` for that parent's
# dependency in EITHER map order (probed on pnpm 11.28.5: `make-dir>semver`
# beat `semver@7` both ways), so the written floor is not provably effective:
# refused wherever the entry sits, even with a readable cap…
p="$(existing_floor parent-before "'>=1.3.0 <2'")"
add_entry "$p" 'some-parent>left-pad' "'>=1.3.0 <2'"
expect_refused "$p" parent-before "a parent-scoped \`some-parent>left-pad\` override for \`left-pad\` outranks \`left-pad@1\` — remove it deliberately"
pass "parent-before: an earlier parent-scoped override is refused, bytes unchanged"
p="$(existing_floor parent-after "'>=1.3.0 <2'")"
add_entry "$p" 'some-parent>left-pad' "'>=1.3.0 <2'" after
echo "left-pad@1: '>=1.3.0 <2'" >"$p/.stub/cleared-by"
rm -f "$p/.stub/needs-relock" # so only the parent-scoped key can keep it open
(cd "$p" && STUB_DIR="$p/.stub" pnpm audit --audit-level=high --json || true) >"$p/stub-audit.json"
cmp -s "$p/stub-audit.json" "$p/.stub/audit.json" || fail "parent-after: the stub cleared an advisory a parent-scoped key outranks"
expect_refused "$p" parent-after "a parent-scoped \`some-parent>left-pad\` override for \`left-pad\` outranks \`left-pad@1\`"
pass "parent-after: a later parent-scoped override is refused, bytes unchanged"

# … and listed, not applied, under --skip-refused.
p="$(existing_floor parent-skip "'>=1.3.0 <2'")"
add_entry "$p" 'some-parent>left-pad' "'>=1.3.0 <2'"
before="$(snapshot_of "$p")"
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "parent-skip: exited non-zero"
}
[ "$(snapshot_of "$p")" = "$before" ] || fail "parent-skip: the refused key was written"
grep -qF "**refused:** a parent-scoped \`some-parent>left-pad\` override for \`left-pad\` outranks" "$p/report.md" ||
    fail "parent-skip: the refusal is not listed in the report"
pass "parent-skip: --skip-refused lists the parent-scoped refusal and writes nothing for it"

# … and one placed after the key outranks the rewrite: refused. The stub's
# last-match-wins resolution sees it too: with the floor in place and the
# selector after it, the advisory stays open.
p="$(existing_floor sel-after "'>=1.3.0 <2'")"
add_entry "$p" 'left-pad@^1.2.0' "'>=1.3.0 <2'" after
echo "left-pad@1: '>=1.3.0 <2'" >"$p/.stub/cleared-by"
rm -f "$p/.stub/needs-relock" # so only the ordering can keep it open
(cd "$p" && STUB_DIR="$p/.stub" pnpm audit --audit-level=high --json || true) >"$p/stub-audit.json"
cmp -s "$p/stub-audit.json" "$p/.stub/audit.json" || fail "sel-after: the stub cleared an advisory a later selector key outranks"
expect_refused "$p" sel-after "a later \`left-pad@^1.2.0\` override for \`left-pad\` takes precedence over \`left-pad@1\` — reorder or remove it deliberately"
pass "sel-after: a selector override after the keyed one is refused, bytes unchanged"

# An entry keyed by another line's exact `pkg@<major-key>` is exempt by its
# key (Claude
# 6114558857): a package the script floored on two lines raises either line,
# in either map order…
p="$(existing_floor two-lines-1 "'>=1.3.0 <2'")"
add_entry "$p" left-pad@2 "'>=2.0.5 <3'" after
echo "left-pad@1: '>=1.3.4 <2'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "two-lines-1: a later left-pad@2 key blocked the left-pad@1 raise"
}
expect_keys "$p" two-lines-1 'left-pad@1=>=1.3.4 <2'
pass "two-lines-1: left-pad@1 is raised past a later left-pad@2 key"

p="$(existing_floor two-lines-2 "'>=1.3.0 <2'")"
add_entry "$p" left-pad@2 "'>=2.0.0 <3'"
advisory GHSA-0000-0000-0050 left-pad high '<2.0.5' 2.0.1 left-pad | jq '{advisories: .}' >"$p/.stub/audit.json"
fix_writes "$p" '  left-pad@<2.0.5: ^2.0.5'
echo "left-pad@2: '>=2.0.5 <3'" >"$p/.stub/cleared-by"
run_fix "$p" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "two-lines-2: a later left-pad@1 key blocked the left-pad@2 raise"
}
expect_keys "$p" two-lines-2 'left-pad@2=>=2.0.5 <3'
pass "two-lines-2: left-pad@2 is raised past a later left-pad@1 key"

# … while a selector that can reach the line, placed after the key, still
# outranks it.
p="$(existing_floor sel-after-ge "'>=1.3.0 <2'")"
add_entry "$p" 'left-pad@>=1' "'>=1.3.0 <2'" after
expect_refused "$p" sel-after-ge "a later \`left-pad@>=1\` override for \`left-pad\` takes precedence over \`left-pad@1\`"
pass "sel-after-ge: a later left-pad@>=1 key still refuses the left-pad@1 rewrite"

# targets_of, the reader every rule above runs on: which keys target a
# package (Codex 4243577341, Gemini 4243510179 — digit-led names).
# eval, not `. <(…)`: bash 3.2 reads a sourced process substitution as empty.
eval "$(sed -n '/^targets_of() {/,/^}/p' "$REPO_ROOT/$HELPER")"
got="$(printf '%s\tv\n' pkg pkg@1 'pkg@>=1.2.0' 'parent>pkg' 'a>b>pkg' 'pkg@<1||>2' 'pkg-other' 'pkg>child' '@s/p@1' | targets_of pkg | cut -f2 | tr '\n' ' ')"
[ "$got" = 'pkg pkg@1 pkg@>=1.2.0 parent>pkg a>b>pkg pkg@<1||>2 ' ] || fail "targets-table: pkg: got '$got'"
got="$(printf '%s\tv\n' 7zip-bin 'parent>7zip-bin' 'parent@1>7zip-bin@2' 'x7zip-bin' | targets_of 7zip-bin | cut -f2 | tr '\n' ' ')"
[ "$got" = '7zip-bin parent>7zip-bin parent@1>7zip-bin@2 ' ] || fail "targets-table: 7zip-bin: got '$got'"
got="$(printf '%s\tv\n' '@s/p' '@s/p@1' 'x>@s/p' '@s/p>q' 'p' | targets_of @s/p | cut -f2 | tr '\n' ' ')"
[ "$got" = '@s/p @s/p@1 x>@s/p ' ] || fail "targets-table: @s/p: got '$got'"
got="$(printf '%s\tv\n' pkg@1 pkg@2 pkg@0.4 pkg@0 'pkg@>=1' pkg@1.x | targets_of pkg pkg@1 | cut -f2 | tr '\n' ' ')"
[ "$got" = 'pkg@1 pkg@0 pkg@>=1 pkg@1.x ' ] || fail "targets-table: disjoint lines: got '$got'"
pass "targets-table: bare, @major, selectors, parent-scoped (digit-led too), scoped names, disjoint major keys"

# Table-safe report cells (Claude #4): a refusal reason carrying a `||`
# patched range must not split its row.
p="$(new_project table-cells)"
advisory GHSA-zzzz-zzzz-zzzz pkgz high '<1.3.4 || >=2.0.0 <2.1.5' 0.9.0 direct '>=1.3.4 <2.0.0 || >=2.1.5' |
    jq '{advisories: .}' >"$p/.stub/audit.json"
fix_adds "$p" 'pkgz@<1.3.4 || >=2.0.0 <2.1.5' '^1.3.4'
run_fix "$p" --skip-refused --report "$p/report.md" >"$p/out.log" 2>&1 || {
    cat "$p/out.log"
    fail "table-cells: exited non-zero"
}
row="$(grep -F '| GHSA-zzzz-zzzz-zzzz |' "$p/report.md")" || fail "table-cells: the refusal row is missing"
[ "$(printf '%s' "$row" | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')" -eq 6 ] ||
    fail "table-cells: the row does not have exactly 5 cells: $row"
grep -qF '>=1.3.4 <2.0.0 \|\| >=2.1.5' <<<"$row" || fail "table-cells: the || range was not escaped: $row"
pass "table-cells: a || range in a refusal reason is escaped and the row keeps 5 cells"

# ── 15. publish: one rolling draft PR, scope-checked patch ─────────────
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
git --git-dir="$ORIGIN" show "refs/heads/$FIX_BRANCH:pnpm-workspace.yaml" | grep -F "lodash@4: '>=4.18.1 <5'" >/dev/null ||
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

# The staged result is checked too (Claude #1): a rename of the workspace
# file, and a mode change the numstat cannot see, are both refused.
(cd "$p" && git checkout -q main && git mv pnpm-workspace.yaml elsewhere.yaml &&
    git diff --cached -M >out/changes.patch && git reset -q --hard)
rc=0
publish >"$p/out/4.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "publish: a patch renaming the workspace file was accepted"
pass "publish: a patch renaming the workspace file is refused"

(cd "$p" && git checkout -q main && chmod +x pnpm-workspace.yaml && git diff >out/changes.patch && chmod -x pnpm-workspace.yaml)
grep -q '^new mode 100755' "$p/out/changes.patch" || fail "publish: fixture did not produce a mode-change patch"
rc=0
publish >"$p/out/5.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || ! grep -q 'only in-place modifications' "$p/out/5.log"; then
    cat "$p/out/5.log"
    fail "publish: a mode change staged on the workspace file was accepted"
fi
pass "publish: the staged result is checked — a mode change on the workspace file is refused"

# Head replication lag (Gemini 4242195103 / Claude #3): the PR reports the old
# head once after the push; the check polls instead of failing.
(
    cd "$p" && git reset -q --hard && git checkout -q main
    printf "  # minimist@1: GHSA-y.\n  minimist@1: '>=1.2.6 <2'\n" >>pnpm-workspace.yaml
    echo '# relocked again' >>pnpm-lock.yaml
    git diff --binary >out/changes.patch
    git checkout -q -- .
)
mkdir -p "$p/.stub/fastbin"
printf '#!/bin/sh\necho "sleep $*" >>"$STUB_DIR/calls"\n' >"$p/.stub/fastbin/sleep"
chmod +x "$p/.stub/fastbin/sleep"
rm -f "$p/.stub/views"
echo 2 >"$p/.stub/lag-at"
rc=0
(cd "$p" && PATH="$p/.stub/fastbin:$PATH" STUB_DIR="$p/.stub" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    ./scripts/security-audit-fix.sh publish "$p/out") >"$p/out/6.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
    cat "$p/out/6.log"
    fail "publish: a one-read head lag after the push failed the run"
}
grep -q '^sleep 5$' "$p/.stub/calls" || fail "publish: the head check did not poll"
pass "publish: a head that lags the push for one read is polled, not failed"

# Publish only the audited commit (#1635): when the base moved past
# GITHUB_SHA between the audit and publish jobs, nothing is pushed and the run
# exits 0; on the audited commit itself the publish proceeds.
(
    cd "$p" && git reset -q --hard && git checkout -q main
    printf "  # qs@6: GHSA-z.\n  qs@6: '>=6.14.1 <7'\n" >>pnpm-workspace.yaml
    echo '# relocked for qs' >>pnpm-lock.yaml
    git diff --binary >out/changes.patch
    git checkout -q -- .
)
before_head="$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$FIX_BRANCH")"
before_calls="$(wc -l <"$p/.stub/calls")"
rc=0
(cd "$p" && GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 STUB_DIR="$p/.stub" \
    ./scripts/security-audit-fix.sh publish "$p/out") >"$p/out/7.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
    cat "$p/out/7.log"
    fail "publish-moved: a moved base must exit 0, got $rc"
}
grep -q 'main moved since the audit' "$p/out/7.log" || fail "publish-moved: no notice that main moved"
! grep -q '^::notice::' "$p/out/7.log" || fail "publish-moved: an Actions annotation outside Actions"
[ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$FIX_BRANCH")" = "$before_head" ] || fail "publish-moved: the bot branch was pushed"
[ "$(wc -l <"$p/.stub/calls")" -eq "$before_calls" ] || fail "publish-moved: gh was called"
[ "$(cd "$p" && git rev-parse --abbrev-ref HEAD)" = main ] && [ -z "$(cd "$p" && git status --porcelain)" ] ||
    fail "publish-moved: the checkout was left changed"
pass "publish-moved: a base that moved past GITHUB_SHA publishes nothing and exits 0"

# Under Actions the skip is also a run annotation.
rc=0
(cd "$p" && GITHUB_ACTIONS=true GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 STUB_DIR="$p/.stub" \
    ./scripts/security-audit-fix.sh publish "$p/out") >"$p/out/7b.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
    cat "$p/out/7b.log"
    fail "publish-moved-actions: exited $rc"
}
grep -q '^::notice::security-audit-fix: main moved since the audit' "$p/out/7b.log" ||
    fail "publish-moved-actions: no ::notice:: annotation"
[ "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$FIX_BRANCH")" = "$before_head" ] || fail "publish-moved-actions: the bot branch was pushed"
pass "publish-moved-actions: under GITHUB_ACTIONS the moved-base skip is a ::notice:: annotation"

audited="$(cd "$p" && git rev-parse HEAD)"
rc=0
(cd "$p" && GITHUB_SHA="$audited" STUB_DIR="$p/.stub" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
    ./scripts/security-audit-fix.sh publish "$p/out") >"$p/out/8.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
    cat "$p/out/8.log"
    fail "publish-audited: publishing on the audited commit failed"
}
git --git-dir="$ORIGIN" show "refs/heads/$FIX_BRANCH:pnpm-workspace.yaml" | grep -F "qs@6: '>=6.14.1 <7'" >/dev/null ||
    fail "publish-audited: the bot branch lacks the floors"
pass "publish-audited: on the audited commit (HEAD = GITHUB_SHA) the floors are published"

echo "test-security-audit-fix: $cases cases passed"
