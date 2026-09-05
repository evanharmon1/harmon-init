#!/usr/bin/env bash
set -euo pipefail

schema_dir="ai/schemas"
validator="scripts/validate-result-schemas.mjs"
fixtures="$schema_dir/fixtures"
oneshot="$fixtures/run.schema/valid/oneshot.json"
tmp="$(mktemp)"
tmp2="$(mktemp)"
known_ids="$(mktemp)"
trap 'rm -f "$tmp" "$tmp2" "$known_ids"' EXIT
printf '[]\n' >"$known_ids"

accepts() {
    kind="$1"
    file="$2"
    shift 2
    node "$validator" "$kind" "$file" "$@" >/dev/null
}

rejects() {
    name="$1"
    kind="$2"
    file="$3"
    shift 3
    if node "$validator" "$kind" "$file" "$@" >/dev/null 2>&1; then
        echo "FAIL: result validator accepted $name" >&2
        exit 1
    fi
}

for schema in "$schema_dir"/*.schema.json; do
    jq empty "$schema"
done
node scripts/test-result-schema-composition.mjs

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

accepts run "$oneshot" --no-adjudications --receipt
jq '.stage_transitions[2].stage = "security"' "$oneshot" >"$tmp"
rejects run-invalid-transition run "$tmp" --no-adjudications --receipt
jq '
    .pr = {number: 1, url: "https://example.invalid/pr/1"}
    | .evidence_comments = [{
        id: "comment-1",
        author_actor_id: 1,
        login: "agent",
        digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        marker: {
            run_id: "run-oneshot-transition",
            stage: "implement",
            destination: "pr",
            round: 1,
            sequence: 1
        }
    }]
' "$oneshot" >"$tmp"
rejects run-pr-round-evidence run "$tmp" --no-adjudications --receipt
jq '
    .settlements = [{
        finding_id: "challenge-r1-contract-1",
        disposition: "file",
        settled_at: "2026-09-03T00:03:00Z",
        reference: {type: "issue_number", value: "1"}
    }]
' "$oneshot" >"$tmp"
rejects run-settlement-before-integration run "$tmp"

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
accepts run "$tmp2" --adjudication "$adjudication" --receipt
jq '.evidence_comments = []' "$tmp2" >"$tmp"
rejects run-missing-adjudication-evidence run "$tmp" --adjudication "$adjudication" --receipt

echo "result schema contract tests OK"
