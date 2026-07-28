#!/usr/bin/env bash
# test-setup-github-project.sh — unit-test setup-github-project.sh's field
# reconciliation against a stubbed `gh`; no live API calls, so it is safe in CI.
# Run via `task test:setup-github-project`.
#
# The invariant worth a test: `updateProjectV2Field` REPLACES the whole
# singleSelectOptions array, and per GitHub's schema an existing option re-sent
# WITHOUT its `id` is destroyed and recreated — silently blanking that field on
# every board item already assigned to it. Appending is therefore only safe while
# every pre-existing option goes back with its id, and nothing else in `verify`
# executes this path (the script talks to the live API, so lint is its only other
# gate). A future edit that drops the ids would otherwise pass every check and
# lose data on the next re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/scripts/setup-github-project.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    [ -f "$tmp/out" ] && sed 's/^/    /' "$tmp/out" >&2
    exit 1
}

# A fake `gh` on PATH: canned reads, and every field mutation appended to
# $MUTATIONS instead of sent. The fields-snapshot case must come first — that
# query also mentions ProjectV2Field* types.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
q=""
for a in "$@"; do case "$a" in query=*) q="${a#query=}" ;; esac; done
case "$q" in
*"fields(first:50)"*)
    if [ -s "${STUB_FIELDS_FILE2:-}" ] && [ -f "$tmp_seen" ]; then
        cat "$STUB_FIELDS_FILE2"
    else
        : >"$tmp_seen"
        cat "$STUB_FIELDS_FILE"
    fi
    ;;
*repositoryOwner*__typename*) echo '{"data":{"repositoryOwner":{"__typename":"User","id":"U_1"}}}' ;;
*projectsV2*) echo '{"data":{"repositoryOwner":{"projectsV2":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"P_1","number":7,"title":"Test Project"}]}}}}' ;;
*ProjectV2Field*) printf '%s\n' "$q" >>"$MUTATIONS"; echo '{"data":{}}' ;;
*) echo "fake gh: unexpected query: $q" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
tmp_seen="$tmp/seen"
export tmp_seen
PATH="$tmp/bin:$PATH"
export PATH

MUTATIONS="$tmp/mutations"
STUB_FIELDS_FILE="$tmp/fields.json"
STUB_FIELDS_FILE2="$tmp/fields2.json"
export MUTATIONS STUB_FIELDS_FILE STUB_FIELDS_FILE2

# run_with FIELDS_JSON — run the script against that project snapshot.
run_with() {
    printf '%s' "$1" >"$STUB_FIELDS_FILE"
    printf '%s' "${2:-}" >"$STUB_FIELDS_FILE2"
    rm -f "$tmp_seen"
    : >"$MUTATIONS"
    "$script" --owner someuser --title "Test Project" >"$tmp/out" 2>&1 ||
        fail "script exited non-zero"
}

updates() { grep -c updateProjectV2Field "$MUTATIONS" || true; }

# A project already carrying every starter value.
complete='{"data":{"node":{"fields":{"nodes":[
 {"id":"F_status","name":"Status","dataType":"SINGLE_SELECT","options":[
   {"id":"s1","name":"Inbox","color":"GRAY","description":"Newly landed, unsorted"},
   {"id":"s2","name":"Icebox","color":"GRAY","description":"Real, but not now"},
   {"id":"s3","name":"Next","color":"PINK","description":"Will pull in soon"},
   {"id":"s4","name":"Todo","color":"BLUE","description":"Committed, not started"},
   {"id":"s5","name":"Shaping","color":"BLUE","description":"Problem/approach being defined"},
   {"id":"s6","name":"Ready","color":"BLUE","description":"Shaped, ready to pick up"},
   {"id":"s7","name":"Agent Queue","color":"BLUE","description":"Queued for an AI agent"},
   {"id":"s8","name":"In Progress","color":"YELLOW","description":"Actively being worked"},
   {"id":"s9","name":"Verifying","color":"ORANGE","description":"CI/checks running"},
   {"id":"s10","name":"In Review","color":"GREEN","description":"Under human review"},
   {"id":"s11","name":"Ready to Merge","color":"GREEN","description":"Approved, awaiting merge"},
   {"id":"s12","name":"Done","color":"PURPLE","description":"Merged/shipped"},
   {"id":"s13","name":"Deployed","color":"PURPLE","description":"Deployed"},
   {"id":"s14","name":"Accepted","color":"PURPLE","description":"Smoke/QA/manual check passed"}]},
 {"id":"F_size","name":"Size","dataType":"NUMBER"},
 {"id":"F_prod","name":"Product","dataType":"TEXT"},
 {"id":"F_pri","name":"Priority","dataType":"SINGLE_SELECT","options":[
   {"id":"p1","name":"Urgent","color":"RED","description":""},
   {"id":"p2","name":"High","color":"ORANGE","description":""},
   {"id":"p3","name":"Medium","color":"YELLOW","description":""},
   {"id":"p4","name":"Low","color":"GRAY","description":""}]},
 {"id":"F_agt","name":"Agent","dataType":"SINGLE_SELECT","options":[
   {"id":"a1","name":"Claude Code","color":"ORANGE","description":""},
   {"id":"a2","name":"Codex","color":"BLUE","description":""},
   {"id":"a3","name":"Gemini CLI","color":"PURPLE","description":""},
   {"id":"a4","name":"Qwen Code","color":"GREEN","description":""},
   {"id":"a5","name":"DeepSeek","color":"RED","description":""},
   {"id":"a6","name":"Kimi K2","color":"YELLOW","description":""},
   {"id":"a7","name":"GLM","color":"PINK","description":""},
   {"id":"a8","name":"GitHub Copilot","color":"GRAY","description":""}]},
 {"id":"F_dom","name":"Domain","dataType":"SINGLE_SELECT","options":[
   {"id":"d1","name":"auth","color":"PURPLE","description":"Authentication and authorization"},
   {"id":"d2","name":"billing","color":"GREEN","description":"Billing and payments"},
   {"id":"d3","name":"platform","color":"GRAY","description":"CI, build, test infra, and tooling in this repo"}]},
 {"id":"F_lay","name":"Layer","dataType":"SINGLE_SELECT","options":[
   {"id":"l1","name":"ui","color":"BLUE","description":"Components, styling, interaction, tokens, a11y. No data change"},
   {"id":"l2","name":"logic","color":"GREEN","description":"Business rules, handlers, calculation"},
   {"id":"l3","name":"data","color":"YELLOW","description":"Schema, indexes, validators, migrations"},
   {"id":"l4","name":"integration","color":"ORANGE","description":"External boundary: webhooks, API clients, credentials"}]}
]}}}}'

echo "==> a re-run against an already-synced project writes nothing"
run_with "$complete"
[ "$(updates)" = 0 ] || fail "expected no mutations on an unchanged project, got $(updates)"
grep -q "leaving it as-is" "$tmp/out" || fail "expected 'leaving it as-is' output"

echo "==> a field missing a starter option gains ONLY that option"
# Domain lacks `billing` and carries an owner-added `crm`.
partial=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Domain" then
            .options = [ .options[] | if .name == "billing"
                then {id: "d9", name: "crm", color: "PINK", description: "owner added"}
                else . end ]
        else . end)')
run_with "$partial"
[ "$(updates)" = 1 ] || fail "expected exactly 1 update mutation, got $(updates)"
mut=$(cat "$MUTATIONS")
case "$mut" in
*'{name:"billing"'*) : ;;
*) fail "the appended option should be sent WITHOUT an id" ;;
esac

echo "==> every pre-existing option is re-sent WITH its id (identity preserved)"
for pair in 'd1:auth' 'd9:crm' 'd3:platform'; do
    case "$mut" in
    *"{id:\"${pair%%:*}\",name:\"${pair##*:}\""*) : ;;
    *) fail "existing option '${pair##*:}' lost its id '${pair%%:*}' — item values would be cleared" ;;
    esac
done

echo "==> an owner-added option survives the append"
case "$mut" in
*'name:"crm"'*) : ;;
*) fail "owner-added option 'crm' was dropped from the replacement list" ;;
esac

echo "==> a field of the wrong data type is warned about, never appended to"
wrong=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Domain" then {id: .id, name: .name, dataType: "TEXT"} else . end)')
run_with "$wrong"
[ "$(updates)" = 0 ] || fail "a wrong-typed field must not receive an option update"
grep -q "already exists as TEXT" "$tmp/out" || fail "expected a data-type warning for Domain"

echo "==> a field at the option cap warns instead of attempting an oversized write"
capped=$(printf '%s' "$complete" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Domain" then
            .options = ([ .options[] | select(.name != "billing") ]
                + [ range(0; 48) | {id: "x\(.)", name: "custom\(.)", color: "GRAY", description: ""} ])
        else . end)')
run_with "$capped"
[ "$(updates)" = 0 ] || fail "an over-capacity append must be skipped, not attempted"
grep -q "cannot fit billing" "$tmp/out" || fail "expected a capacity warning naming the missing option"

echo "==> an option added after the startup snapshot survives the append"
# The re-read immediately before the write is what saves it: the replacement is
# built from the fresh list, not the stale one.
concurrent=$(printf '%s' "$partial" | jq -c '
    .data.node.fields.nodes |= map(
        if .name == "Domain" then
            .options += [{id: "d42", name: "raced-in", color: "BLUE", description: "added concurrently"}]
        else . end)')
run_with "$partial" "$concurrent"
mut=$(cat "$MUTATIONS")
case "$mut" in
*'name:"raced-in"'*) : ;;
*) fail "an option added between the snapshot and the write was deleted — the pre-write re-read is missing" ;;
esac

echo "PASS: setup-github-project.sh field reconciliation"
