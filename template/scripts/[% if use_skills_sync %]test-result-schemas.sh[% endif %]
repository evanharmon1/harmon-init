#!/usr/bin/env bash
set -euo pipefail

schema_dir="ai/schemas"
manifest=".skills-sync.yaml"
fixtures="$schema_dir/fixtures"
oneshot="$fixtures/run.schema/valid/oneshot.json"

[ -f "$manifest" ] || {
    echo "FAIL: skills sync manifest is missing: $manifest" >&2
    exit 1
}
command -v yq >/dev/null 2>&1 || {
    echo "FAIL: yq is required to read $manifest" >&2
    exit 1
}

assert_safe_dest() {
    case "$1" in
    "" | "/" | "." | "..")
        echo "FAIL: unsafe $2 destination in $manifest: '$1'" >&2
        exit 1
        ;;
    /*)
        echo "FAIL: absolute $2 destination in $manifest: '$1'" >&2
        exit 1
        ;;
    ../* | */../* | */..)
        echo "FAIL: traversing $2 destination in $manifest: '$1'" >&2
        exit 1
        ;;
    esac
}

skills_dest="$(yq -r '.dest // ""' "$manifest")"
agents_dest="$(yq -r '.agents.dest // ""' "$manifest")"
assert_safe_dest "$skills_dest" "skills"
[ -z "$agents_dest" ] || assert_safe_dest "$agents_dest" "agents"

vendored_package="$skills_dest/dev-flow-support"
vendored_assets="$vendored_package/assets"
validator="$vendored_assets/validate-result-schemas.mjs"
bundled_schemas="$vendored_assets/schemas"
skills_provenance="$skills_dest/.SKILLS_PROVENANCE"
agents_provenance="${agents_dest:+$agents_dest/.AGENTS_PROVENANCE}"

provenance_manages_devflow() {
    awk -F ': ' '
        /^# managed: / {
            count = split($2, managed, /[[:space:]]*,[[:space:]]*/)
            for (i = 1; i <= count; i++) if (managed[i] == "dev-flow-support") found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

manifest_requests_universal() {
    yq -e '.categories[] | select(. == "universal")' "$manifest" >/dev/null 2>&1
}

if [ ! -f "$skills_provenance" ]; then
    if [ -n "$agents_provenance" ] && [ -f "$agents_provenance" ] && manifest_requests_universal; then
        echo "FAIL: canonical result validator is missing from an incomplete skills sync: $validator" >&2
        exit 1
    fi
    echo "SKIP: canonical result validator is not vendored; run 'task sync:skills' after enabling the universal skill category"
    exit 0
fi
if ! provenance_manages_devflow "$skills_provenance"; then
    echo "SKIP: canonical result validator was not selected by the synced skills package"
    exit 0
fi
[ -f "$validator" ] || {
    echo "FAIL: canonical result validator is missing from an already-synced skills package: $validator" >&2
    exit 1
}
[ -d "$bundled_schemas" ] || {
    echo "FAIL: canonical result validator is missing its bundled schemas: $bundled_schemas" >&2
    exit 1
}

tmp="$(mktemp)"
tmp2="$(mktemp)"
tmp3="$(mktemp)"
tmp4="$(mktemp)"
known_ids="$(mktemp)"
trap 'rm -f "$tmp" "$tmp2" "$tmp3" "$tmp4" "$known_ids"' EXIT
printf '[]\n' >"$known_ids"

stale_validator_path='scripts/validate-result-''schemas.mjs'
for stale_validator in "$stale_validator_path" "template/$stale_validator_path"; do
    [ ! -e "$stale_validator" ] || {
        echo "FAIL: stale repository-owned result validator returned: $stale_validator" >&2
        exit 1
    }
done
reference_roots=(AGENTS.md ai docs)
[ ! -d template ] || reference_roots+=(template)
if rg -n --fixed-strings "$stale_validator_path" "${reference_roots[@]}"; then
    echo "FAIL: repository-root result validator path is still documented" >&2
    exit 1
fi

accepts() {
    kind="$1"
    file="$2"
    shift 2
    node "$validator" "$kind" "$file" "$@" --schemas-dir "$schema_dir" >/dev/null
}

rejects() {
    name="$1"
    kind="$2"
    file="$3"
    shift 3
    if node "$validator" "$kind" "$file" "$@" --schemas-dir "$schema_dir" >/dev/null 2>&1; then
        echo "FAIL: result validator accepted $name" >&2
        exit 1
    fi
}

# Construct fixture chains explicitly after a test changes a derived field.
# This is not part of accepts/rejects: malformed chains must stay malformed.
build_run_chains() {
    node --input-type=module - "$1" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { canonicalJson } from './scripts/lib/json-schema-subset.mjs'

const file = process.argv[2]
const run = JSON.parse(readFileSync(file, 'utf8'))
function chain(contents) {
  let previous = 'genesis'
  return contents.map((content, seq) => {
    const digest = createHash('sha256')
      .update(canonicalJson({ ...content, prev_digest: previous })).digest('hex')
    const entry = { ...content, seq, prev_digest: previous, digest }
    previous = digest
    return entry
  })
}
const lastTransition = run.stage_transitions.at(-1).entered_at
run.evidence_registrations = chain(run.evidence_comments.map((comment) => ({
  id: comment.id, author_actor_id: comment.author_actor_id, login: comment.login,
  payload_digest: comment.digest, marker: comment.marker,
  registered_at: run.stage_transitions.find((entry) => entry.stage === comment.marker.stage).entered_at
})))
run.pr_bindings = chain(run.pr ? [{ ...run.pr, bound_at: lastTransition }] : [])
run.outcome_transitions = chain(run.outcome ? [{
  outcome: run.outcome, at: run.promotion?.promoted_at ?? lastTransition
}] : [])
writeFileSync(file, JSON.stringify(run, null, 2) + '\n')
NODE
}

for schema in "$schema_dir"/*.schema.json; do
    jq empty "$schema"
done
node scripts/test-result-schema-composition.mjs

# The registry is the dispatcher's contract, including all configured finders.
# These copies ship even when the consumer does not sync shared skills.
# Compare parsed schemas: generated repos format them with Prettier. The
# Schemas are formatted rather than byte-compared against the vendored copies.
# The contract suite runs the vendored validator against these repository-owned
# mirrors, so validator and schemas always move under one release contract.
registry_schemas="$(jq -r '.. | objects | .result_schema? // empty' agent-registry.json | LC_ALL=C sort -u)"
integrator_schema="$(jq -r '.roles[] | select(.slug == "integrator") | .result_schema' agent-registry.json)"
[ "$integrator_schema" = "$schema_dir/result.integrator.schema.json" ] || {
    echo "FAIL: integrator registry schema path differs from shipped contract" >&2
    exit 1
}
for schema in $registry_schemas "$schema_dir/brief.envelope.schema.json" "$schema_dir/plan.schema.json"; do
    [ -f "$schema" ] || {
        echo "FAIL: missing registry-named schema: $schema" >&2
        exit 1
    }
    bundled_schema="$bundled_schemas/${schema##*/}"
    [ -f "$bundled_schema" ] || {
        echo "FAIL: canonical result validator is missing bundled schema: $bundled_schema" >&2
        exit 1
    }
    jq -S . "$schema" >"$tmp"
    jq -S . "$bundled_schema" >"$tmp2"
    cmp "$tmp" "$tmp2" || {
        echo "FAIL: registry-named schema drifted from pinned dev-flow-support: $schema" >&2
        exit 1
    }
done

# Advertised standalone modes must work with the repository's shipped schemas.
accepts brief "$fixtures/brief.envelope/valid/minimal.md"
accepts plan "$fixtures/plan/valid/interactive.json"

for fixture in charged-exempt carried; do
    accepts integrator "$fixtures/result.integrator.schema/valid/$fixture.json" \
        --known-ids "$known_ids" --run-id run-4001-verdict-clean --initiated-by human --receipt
    node "$validator" integrator "$fixtures/result.integrator.schema/valid/$fixture.json" \
        --known-ids "$known_ids" --run-id run-4001-verdict-clean --initiated-by human --receipt >/dev/null
done

for mutation in '.payload.codex_cycle.charged = -1' \
    '.payload.codex_cycle.exempt = -1'; do
    jq "$mutation" "$fixtures/result.integrator.schema/valid/charged-exempt.json" >"$tmp"
    rejects integrator-invalid-cycle-accounting integrator "$tmp"
done
for mutation in 'del(.payload.codex_cycle.carried)' \
    '.payload.codex_cycle.carried.attests_head = .payload.codex_cycle.carried.origin_head' \
    '.payload.codex_cycle.accepted.reviewed_commit = .head' \
    'del(.payload.finder_cycles[0].carried)' \
    '.payload.finder_cycles[0].carried.generation = 2'; do
    jq "$mutation" "$fixtures/result.integrator.schema/valid/carried.json" >"$tmp"
    rejects integrator-invalid-carry integrator "$tmp"
done

expected_inventory="$({
    find "$fixtures" -type f \( -name '*.json' -o -name '*.md' \) |
        sed "s#^${fixtures}/##" |
        LC_ALL=C sort |
        sed 's#^#- `#; s#$#`#'
})"
documented_inventory="$({
    sed -n \
        '/<!-- BEGIN GENERATED FIXTURE INVENTORY -->/,/<!-- END GENERATED FIXTURE INVENTORY -->/p' \
        "$schema_dir/README.md" |
        sed '1d;$d'
})"
if [ "$documented_inventory" != "$expected_inventory" ]; then
    echo "FAIL: ai/schemas/README.md generated fixture inventory is stale" >&2
    diff -u <(printf '%s\n' "$documented_inventory") <(printf '%s\n' "$expected_inventory") >&2 || true
    exit 1
fi

accepts implementer "$fixtures/result.implementer.schema/valid/completed.json" \
    --run-id run-0397-omator --initiated-by human --receipt
rejects implementer-empty-summary implementer \
    "$fixtures/result.implementer.schema/invalid/empty-summary-when-completed.json"

accepts challenger "$fixtures/result.challenger.schema/valid/empty-findings.json" \
    --known-ids "$known_ids" --run-id run-4001-empty-findings --initiated-by human --receipt
rejects challenger-empty-attacks challenger \
    "$fixtures/result.challenger.schema/invalid/completed-with-empty-attack-scenarios.json"

accepts reviewer "$fixtures/result.reviewer.schema/valid/empty-findings.json" \
    --known-ids "$known_ids" --run-id run-2151-empty-findings --initiated-by human --receipt
rejects reviewer-counts-mismatch reviewer \
    "$fixtures/result.reviewer.schema/invalid/counts-mismatch-tally.json"

accepts integrator "$fixtures/result.integrator.schema/valid/verdict-clean.json" \
    --known-ids "$known_ids" --run-id run-4001-verdict-clean --initiated-by human --receipt
rejects integrator-bad-verdict integrator \
    "$fixtures/result.integrator.schema/invalid/bad-verdict-enum.json"

adjudication="$fixtures/adjudication.schema/valid/integration-adjudication.json"
adjudication_pass="$fixtures/adjudication.schema/valid/integration-adjudication.pass.json"
accepts adjudication "$adjudication" --pass "$adjudication_pass" \
    --known-adjudicated "$known_ids" --run-id run-6060-integration-adjudication \
    --initiated-by human --receipt
rejects adjudication-duplicate-id adjudication \
    "$fixtures/adjudication.schema/invalid/duplicate-finding-id.json"
rejects adjudication-active-run-mismatch adjudication "$adjudication" \
    --pass "$adjudication_pass" --known-adjudicated "$known_ids" \
    --run-id run-that-does-not-match --initiated-by human --receipt
jq '
    .adjudications = [.adjudications[1]]
    | .adjudications[0].disposition = "defer"
' "$fixtures/adjudication.schema/invalid/duplicate-finding-id.json" >"$tmp"
accepts adjudication "$tmp"
jq '
    .adjudications = [.adjudications[0]]
    | .adjudications[0].disposition = "defer"
    | del(.adjudications[0].reference)
' "$fixtures/adjudication.schema/invalid/duplicate-finding-id.json" >"$tmp"
# AGENTS.md Stage Ledger permits an attributable operator override to carry
# open P0/P1 forward unchecked; record validity does not grant a stage exit.
accepts adjudication "$tmp"
jq '.adjudications[0].disposition = "defer"' "$adjudication" >"$tmp"
rejects adjudication-integration-defer adjudication "$tmp"

split_adjudication="$fixtures/adjudication.schema/valid/split.json"
split_run="$fixtures/run.schema/valid/split.json"
cross_split_adjudication="$fixtures/adjudication.schema/valid/cross-repository-split.json"
cross_split_run="$fixtures/run.schema/valid/cross-repository-split.json"
accepts adjudication "$cross_split_adjudication"
accepts run "$cross_split_run" --adjudication "$cross_split_adjudication" --receipt
rejects split-same-number-different-notation run "$split_run" \
    --adjudication "$cross_split_adjudication" --receipt
rejects split-same-number-different-notation-reverse run "$cross_split_run" \
    --adjudication "$split_adjudication" --receipt
accepts adjudication "$split_adjudication"
rejects split-without-reference adjudication \
    "$fixtures/adjudication.schema/invalid/split-without-reference.json"
rejects integration-split adjudication \
    "$fixtures/adjudication.schema/invalid/integration-split.json"
for mutation in '.adjudications[0].reference.type = "sha"' \
    '.adjudications[0].reference.value = "0"'; do
    jq "$mutation" "$split_adjudication" >"$tmp"
    rejects split-invalid-reference adjudication "$tmp"
done
accepts run "$split_run" --adjudication "$split_adjudication" --receipt
rejects split-without-adjudication run "$split_run" --no-adjudications --receipt
for mutation in '.splits += .splits' \
    '.splits[0].milestone = " "' \
    '.splits[0].round = 2' \
    '.splits[0].issue = "1618"' \
    '.splits[0].split_at = "2026-09-04T00:00:00Z"'; do
    jq "$mutation" "$split_run" >"$tmp"
    rejects split-inconsistent-run run "$tmp" --adjudication "$split_adjudication" --receipt
done
jq '.splits = []' "$split_run" >"$tmp"
accepts run "$tmp" --adjudication "$split_adjudication" --receipt
for outcome in capped escalated abandoned; do
    jq --arg outcome "$outcome" '.outcome = $outcome | .stage_transitions[-1].exit = $outcome' "$tmp" >"$tmp2"
    build_run_chains "$tmp2"
    rejects split-unrecorded-terminal-run run "$tmp2" --adjudication "$split_adjudication" --receipt
done
jq '
    .stage_transitions[-1].exit = "green"
    | .stage_transitions += [{stage: "integration", entered_at: "2026-09-05T00:06:00Z", exit: "ready"}]
    | .outcome = "ready-for-review"
    | .pr = {number: 1, url: "https://example.invalid/pr/1"}
    | .promotion = {head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", promoted_at: "2026-09-05T00:07:00Z", gate_fingerprint: "split-test"}
' "$split_run" >"$tmp2"
build_run_chains "$tmp2"
accepts run "$tmp2" --adjudication "$split_adjudication" --receipt
jq '.splits[0].split_at = "2026-09-05T00:08:00Z"' "$tmp2" >"$tmp"
rejects split-after-promotion run "$tmp" --adjudication "$split_adjudication" --receipt
jq '.adjudications[0].disposition = "file"' "$split_adjudication" >"$tmp"
rejects split-with-file-adjudication run "$split_run" --adjudication "$tmp" --receipt

accepts run "$oneshot" --no-adjudications --receipt
accepts run "$fixtures/run.schema/valid/challenge-to-security-when-review-disabled.json" \
    --no-adjudications --receipt
jq '.stage_transitions[2].stage = "security"' "$oneshot" >"$tmp"
rejects run-invalid-transition run "$tmp" --no-adjudications --receipt
jq '
    .run_id = "run-6060-integration-adjudication"
    | .stage_transitions = [
        {stage: "kickoff", entered_at: "2026-09-03T00:00:00Z", exit: "claimed"},
        {stage: "claim", entered_at: "2026-09-03T00:01:00Z", exit: "oneshot"},
        {stage: "implement", entered_at: "2026-09-03T00:02:00Z", exit: "verified"},
        {stage: "verify", entered_at: "2026-09-03T00:03:00Z", exit: "reviewed"},
        {stage: "review", entered_at: "2026-09-03T00:04:00Z", exit: "approved"},
        {stage: "security", entered_at: "2026-09-03T00:05:00Z", exit: "green"},
        {stage: "integration", entered_at: "2026-09-03T00:06:00Z"}
    ]
    | .pr = {number: 1, url: "https://example.invalid/pr/1"}
    | .evidence_comments = [{
        id: "comment-1",
        author_actor_id: 1,
        login: "agent",
        digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        marker: {
            run_id: "run-6060-integration-adjudication",
            stage: "integration",
            destination: "issue",
            round: 1,
            sequence: 1
        }
    }]
' "$oneshot" >"$tmp2"
build_run_chains "$tmp2"
accepts run "$tmp2" --adjudication "$adjudication" --receipt
# Match the pinned only-pr-evidence-marker fixture, with the adjudicated
# round supplied so this fails on its destination, not a premature PR binding.
jq '.evidence_comments[0].marker.destination = "pr"' "$tmp2" >"$tmp"
build_run_chains "$tmp"
rejects run-pr-round-evidence run "$tmp" --adjudication "$adjudication" --receipt
# Match the pinned chronology fixture: the run has entered integration,
# but the settlement timestamp precedes that transition.
jq '
    .settlements = [{
        finding_id: "challenge-r1-contract-1",
        disposition: "file",
        settled_at: "2026-09-03T00:03:00Z",
        reference: {type: "issue_number", value: "1"}
    }]
' "$tmp2" >"$tmp"
rejects run-settlement-before-integration run "$tmp"
jq '
    .settlements = [{
        finding_id: "challenge-r1-contract-1",
        disposition: "file",
        settled_at: "2026-09-03T00:07:00Z",
        reference: {type: "issue_number", value: "evanharmon1/harmon-devkit#1617"}
    }]
' "$tmp2" >"$tmp"
accepts run "$tmp"
# Like the pinned capped-without-issue-marker fixture, make the run terminal:
# a pending run may still be registering the just-adjudicated round's evidence.
jq '.evidence_comments = [] | .outcome = "capped" | .stage_transitions[-1].exit = "capped"' "$tmp2" >"$tmp"
build_run_chains "$tmp"
rejects run-missing-adjudication-evidence run "$tmp" --adjudication "$adjudication" --receipt
jq '.adjudications[0].finding_id = "integration-r1-human-2"' "$adjudication" >"$tmp3"
cp "$adjudication" "$tmp4"
# The pinned record validator accepts disjoint findings in same-round files.
accepts run "$tmp2" \
    --adjudication "$tmp3" --adjudication "$tmp4" --receipt
rejects run-duplicate-adjudication-finding run "$tmp2" \
    --adjudication "$tmp4" --adjudication "$tmp4" --receipt

echo "result schema contract tests OK"
