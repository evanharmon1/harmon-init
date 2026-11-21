#!/usr/bin/env bash
# Hermetic tests for audit-fleet-rulesets.sh (stubbed gh, no network), plus the
# guard that keeps docs/architecture/branch-protection.md's per-profile
# required-check record in step with the template ruleset it describes.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd -P)"
audit="$root/scripts/audit-fleet-rulesets.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/harmon-init-test-fleet-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ── Record parity: every context the template ruleset can emit is a row of the
# per-profile section, naming the copier answer that emits it ──────────────────
echo "==> per-profile record names every ruleset context and its answer"
jinja="template/.github/Branch Protection Ruleset - Protect Main.json.jinja"
doc="docs/architecture/branch-protection.md"
# context<TAB>answer for each context in the required_status_checks list; a
# context outside any [% if %] is "always". Nested or else-branch conditions are
# a structure this parser does not model, so they fail rather than misreport.
awk '
    /"required_status_checks": \[/ { inside = 1; cond = "always"; next }
    inside && /^\[% if [a-z_]+ %\]$/ { if (cond != "always") { print "NESTED"; exit }
                                       cond = $3; next }
    inside && /^\[% (else|elif)/ { print "NESTED"; exit }
    inside && /^\[% endif %\]$/ { cond = "always"; next }
    inside && /"context":/ { match($0, /"context": "[^"]+"/)
                             c = substr($0, RSTART + 12, RLENGTH - 13)
                             print c "\t" cond }
    inside && /^ *\]$/ { inside = 0 }
' "$jinja" >"$tmp_dir/template-contexts.tsv"
grep -q NESTED "$tmp_dir/template-contexts.tsv" && fail "unsupported conditional structure in $jinja"
[ "$(wc -l <"$tmp_dir/template-contexts.tsv")" -eq "$(grep -c '"context":' "$jinja")" ] ||
    fail "parsed context count differs from the contexts in $jinja"
[ -s "$tmp_dir/template-contexts.tsv" ] || fail "no context parsed from $jinja"
grep -q '\[\[' <(grep '"context":' "$jinja") && fail "a templated context name cannot be enumerated"

# The record's rows: | `context` | answer | reasoning |, answer unquoted.
awk -F '|' '
    function cell(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/`/, "", s); return s }
    /^## Required-check set per copier profile$/ { s = 1; next }
    s && /^## / { exit }
    s && /^\| `[a-z0-9-]+` \|/ { print cell($2) "\t" cell($3) }
' "$doc" >"$tmp_dir/record.tsv"
[ -s "$tmp_dir/record.tsv" ] || fail "no rows in $doc § Required-check set per copier profile"

while IFS="$(printf '\t')" read -r context answer; do
    got="$(awk -F '\t' -v c="$context" '$1 == c { print $2 }' "$tmp_dir/record.tsv")"
    [ -n "$got" ] || fail "record does not list template context $context"
    [ "$got" = "$answer" ] || fail "record names '$got' for $context; the template emits it under '$answer'"
done <"$tmp_dir/template-contexts.tsv"

jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' \
    ".github/Branch Protection Ruleset - Protect Main.json" >"$tmp_dir/root-contexts"
while read -r context; do
    awk -F '\t' -v c="$context" '$1 == c { f = 1 } END { exit !f }' "$tmp_dir/record.tsv" ||
        fail "record does not list root ruleset context $context"
done <"$tmp_dir/root-contexts"

while IFS="$(printf '\t')" read -r context answer; do
    if awk -F '\t' -v c="$context" '$1 == c { f = 1 } END { exit !f }' "$tmp_dir/template-contexts.tsv"; then
        continue
    fi
    grep -qx "$context" "$tmp_dir/root-contexts" && [ "$answer" = "root only" ] ||
        fail "record row $context ($answer) is neither a template context nor a root-only one"
done <"$tmp_dir/record.tsv"

# ── Fleet audit against a stubbed gh ─────────────────────────────────────────
fixtures="$tmp_dir/fixtures"
stub_bin="$tmp_dir/bin"
calls="$tmp_dir/calls"
mkdir -p "$fixtures" "$stub_bin"
: >"$calls"

key() { printf '%s' "$1" | tr '/?&=%' '_____'; }
ok() { printf '%s\n' "$2" >"$fixtures/$(key "$1").json"; }
missing() { : >"$fixtures/$(key "$1").404"; }
broken() { : >"$fixtures/$(key "$1").500"; }

cat >"$stub_bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FLEET_STUB_CALLS"
[ "${1:-}" = api ] || { echo "stub: not an api call" >&2; exit 1; }
endpoint="$2"
shift 2
for arg in "$@"; do
    case "$arg" in
    -X | --method | -f | -F | --field | --raw-field | --input) echo "stub: write option $arg" >&2; exit 1 ;;
    esac
done
key="$(printf '%s' "$endpoint" | tr '/?&=%' '_____')"
if [ -f "$FLEET_STUB_DIR/$key.json" ]; then cat "$FLEET_STUB_DIR/$key.json"; exit 0; fi
if [ -f "$FLEET_STUB_DIR/$key.404" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
if [ -f "$FLEET_STUB_DIR/$key.500" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
echo "stub: unmapped endpoint $endpoint" >&2
exit 1
EOF
chmod +x "$stub_bin/gh"

ruleset() { # ruleset NAME ENFORCEMENT CONTEXT... — a minimal checked-in ruleset
    local name="$1" enforcement="$2"
    shift 2
    jq -nc --arg name "$name" --arg enforcement "$enforcement" '$ARGS.positional as $c |
        {name: $name, target: "branch", source_type: "Repository", source: "acme/x", enforcement: $enforcement,
         rules: [{type: "deletion"}, {type: "required_status_checks",
           parameters: {strict_required_status_checks_policy: true,
             required_status_checks: [$c[] | {context: ., integration_id: 15368}]}}]}' --args "$@"
}
live() { jq -c --argjson id "$1" '. + {id: $id, node_id: "RRS_x", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", _links: {}}'; }
summary() { jq -c --argjson id "$1" --arg name "$2" -n '[{id: $id, name: $name, source_type: "Repository"}]'; }
contents() { printf 'repos/acme/%s/contents/%s?ref=main' "$1" "$2"; }
rs_path=".github/Branch%20Protection%20Ruleset%20-%20Protect%20Main.json"
std="$(ruleset "Protect Main" active verify security closing-keywords)"

# Owner listing: an organization with two filtered repositories.
ok users/acme '{"login":"acme","type":"Organization"}'
ok 'orgs/acme/repos?type=all&per_page=100&page=1' "$(jq -nc '[
    {full_name:"acme/gated",default_branch:"main",fork:false,archived:false,owner:{login:"acme"}},
    {full_name:"acme/noruleset",default_branch:"main",fork:false,archived:false,owner:{login:"acme"}},
    {full_name:"acme/zero",default_branch:"main",fork:false,archived:false,owner:{login:"acme"}},
    {full_name:"acme/drift",default_branch:"main",fork:false,archived:false,owner:{login:"acme"}},
    {full_name:"acme/plain",default_branch:"main",fork:false,archived:false,owner:{login:"acme"}},
    {full_name:"acme/broken",default_branch:"main",fork:false,archived:false,owner:{login:"acme"}},
    {full_name:"acme/forked",default_branch:"main",fork:true,archived:false,owner:{login:"acme"}},
    {full_name:"acme/old",default_branch:"main",fork:false,archived:true,owner:{login:"acme"}}]')"
for repo in gated noruleset zero drift plain broken; do
    ok "repos/acme/$repo" "{\"full_name\":\"acme/$repo\",\"default_branch\":\"main\"}"
done

# managed + gated: live equals the checked-in set.
ok "$(contents gated .copier-answers.yml)" '_commit: v5.20.0'
ok "$(contents gated "$rs_path")" "$std"
ok 'repos/acme/gated/rulesets?includes_parents=false&per_page=100&page=1' "$(summary 7 "Protect Main")"
ok repos/acme/gated/rulesets/7 "$(live 7 <<<"$std")"

# managed, no ruleset of that name (another ruleset exists).
ok "$(contents noruleset .copier-answers.yml)" '_commit: v5.20.0'
ok "$(contents noruleset "$rs_path")" "$std"
ok 'repos/acme/noruleset/rulesets?includes_parents=false&per_page=100&page=1' "$(summary 8 "Tags")"

# managed, ruleset present with zero required checks.
ok "$(contents zero .copier-answers.yml)" '_commit: v5.20.0'
ok "$(contents zero "$rs_path")" "$std"
ok 'repos/acme/zero/rulesets?includes_parents=false&per_page=100&page=1' "$(summary 9 "Protect Main")"
ok repos/acme/zero/rulesets/9 "$(ruleset "Protect Main" active | live 9)"

# managed, drift: missing closing-keywords + devcontainer-verify, extra codeql-verify.
ok "$(contents drift .copier-answers.yml)" '_commit: v5.20.0'
ok "$(contents drift "$rs_path")" "$(ruleset "Protect Main" active verify security closing-keywords devcontainer-verify)"
ok 'repos/acme/drift/rulesets?includes_parents=false&per_page=100&page=1' "$(summary 10 "Protect Main")"
ok repos/acme/drift/rulesets/10 "$(ruleset "Protect Main" active verify security codeql-verify | live 10)"

# unmanaged: no answers file, no checked-in ruleset, no ruleset.
missing "$(contents plain .copier-answers.yml)"
missing "$(contents plain "$rs_path")"
ok 'repos/acme/plain/rulesets?includes_parents=false&per_page=100&page=1' '[]'

# API failure on the ruleset listing → unknown.
ok "$(contents broken .copier-answers.yml)" '_commit: v5.20.0'
ok "$(contents broken "$rs_path")" "$std"
broken 'repos/acme/broken/rulesets?includes_parents=false&per_page=100&page=1'

run_audit() {
    env PATH="$stub_bin:$PATH" FLEET_STUB_DIR="$fixtures" FLEET_STUB_CALLS="$calls" \
        GH_REST_HOST= GH_REPO= GH_REST_TIMEOUT= "$audit" "$@"
}
expect_exit() { # expect_exit CODE ARGS... — run, keep stdout in $tmp_dir/out
    local want="$1" status=0
    shift
    run_audit "$@" >"$tmp_dir/out" 2>"$tmp_dir/stderr" || status=$?
    [ "$status" -eq "$want" ] || {
        cat "$tmp_dir/out" "$tmp_dir/stderr" >&2
        fail "audit $* exited $status, expected $want"
    }
}
status_of() { jq -r --arg r "$1" '.repositories[] | select(.repo == $r) | .status' "$tmp_dir/out"; }

echo "==> managed + gated repository is clean"
expect_exit 0 --json acme/gated
[ "$(status_of acme/gated)" = gated ] || fail "acme/gated not gated"
jq -e '.repositories[0] | .managed == "yes" and .ruleset == "present" and .policy == "clean"
    and .missing == [] and .extra == []' "$tmp_dir/out" >/dev/null || fail "acme/gated record wrong"

echo "==> managed without a ruleset is ungated"
expect_exit 1 --json acme/noruleset
jq -e '.repositories[0] | .status == "ungated" and .ruleset == "absent" and .required == null
    and (.reason | test("other rulesets: Tags"))' "$tmp_dir/out" >/dev/null || fail "acme/noruleset record wrong"

echo "==> ruleset with zero required checks is ungated"
expect_exit 1 --json acme/zero
jq -e '.repositories[0] | .status == "ungated" and .required == [] and .policy == "drift"' \
    "$tmp_dir/out" >/dev/null || fail "acme/zero record wrong"

echo "==> drift names missing and extra contexts"
expect_exit 1 --json acme/drift
jq -e '.repositories[0] | .status == "drift" and .missing == ["closing-keywords","devcontainer-verify"]
    and .extra == ["codeql-verify"] and .policy == "drift"' "$tmp_dir/out" >/dev/null || fail "acme/drift record wrong"

echo "==> unmanaged repository is informational"
expect_exit 0 --json acme/plain
jq -e '.repositories[0] | .status == "unmanaged" and .managed == "no" and .expected == null
    and .ruleset == "absent"' "$tmp_dir/out" >/dev/null || fail "acme/plain record wrong"

echo "==> API failure is unknown, never a pass"
expect_exit 2 --json acme/broken
jq -e '.repositories[0] | .status == "unknown" and .ruleset == "unknown" and (.reason | test("HTTP 500"))' \
    "$tmp_dir/out" >/dev/null || fail "acme/broken record wrong"

echo "==> unreadable repository is unknown"
expect_exit 2 --json acme/ghost
jq -e '.repositories[0] | .status == "unknown" and (.reason | test("unmapped|request failed"))' \
    "$tmp_dir/out" >/dev/null || fail "acme/ghost record wrong"

echo "==> owner scan filters forks and archives, table form"
expect_exit 2 acme
for repo in gated noruleset zero drift plain broken; do
    grep -q "^acme/$repo " "$tmp_dir/out" || fail "table lacks acme/$repo"
done
grep -q 'acme/forked\|acme/old' "$tmp_dir/out" && fail "fork or archived repository was audited"
grep -qx 'summary: drift=1 gated=1 ungated=2 unknown=1 unmanaged=1' "$tmp_dir/out" ||
    fail "summary line wrong: $(tail -n 1 "$tmp_dir/out")"

echo "==> unlistable owner is unknown"
broken users/nobody
expect_exit 2 --json nobody
[ "$(status_of 'nobody/*')" = unknown ] || fail "unlistable owner not unknown"

echo "==> usage errors"
expect_exit 2 --bogus
expect_exit 2 a/b/c

echo "==> every call was a read-only gh api GET"
[ -s "$calls" ] || fail "stub saw no call"
if grep -v '^api ' "$calls" | grep -q .; then fail "non-api gh call"; fi
if grep -E -- '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)' "$calls" | grep -q .; then
    fail "write option passed to gh"
fi

echo "PASS: audit-fleet-rulesets fixtures behave"
