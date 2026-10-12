#!/usr/bin/env bash
set -euo pipefail

schema_dir="ai/schemas"
validator="scripts/validate-result-schemas.mjs"
fixtures="$schema_dir/fixtures"
oneshot="$fixtures/run.schema/valid/oneshot.json"
tmp="$(mktemp)"
tmp2="$(mktemp)"
tmp3="$(mktemp)"
tmp4="$(mktemp)"
known_ids="$(mktemp)"
trap 'rm -f "$tmp" "$tmp2" "$tmp3" "$tmp4" "$known_ids"' EXIT
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

expected_inventory="$({
    find "$fixtures" -type f -name '*.json' |
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
rejects adjudication-p1-defer adjudication "$tmp"

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
    rejects split-unrecorded-terminal-run run "$tmp2" --adjudication "$split_adjudication" --receipt
done
jq '
    .stage_transitions[-1].exit = "green"
    | .stage_transitions += [{stage: "integration", entered_at: "2026-09-05T00:06:00Z", exit: "ready"}]
    | .outcome = "ready-for-review"
    | .pr = {number: 1, url: "https://example.invalid/pr/1"}
    | .promotion = {head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", promoted_at: "2026-09-05T00:07:00Z", gate_fingerprint: "split-test"}
' "$split_run" >"$tmp2"
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
jq '
    .settlements = [{
        finding_id: "challenge-r1-contract-1",
        disposition: "file",
        settled_at: "2026-09-03T00:07:00Z",
        reference: {type: "issue_number", value: "evanharmon1/harmon-devkit#1617"}
    }]
' "$tmp2" >"$tmp"
accepts run "$tmp"
jq '.evidence_comments = []' "$tmp2" >"$tmp"
rejects run-missing-adjudication-evidence run "$tmp" --adjudication "$adjudication" --receipt
jq '.adjudications[0].finding_id = "integration-r1-human-2"' "$adjudication" >"$tmp3"
cp "$adjudication" "$tmp4"
rejects run-duplicate-adjudication-round run "$tmp2" \
    --adjudication "$tmp3" --adjudication "$tmp4" --receipt

echo "result schema contract tests OK"
