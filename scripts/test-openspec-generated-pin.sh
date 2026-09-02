#!/usr/bin/env bash
# test-openspec-generated-pin.sh — the generated OpenSpec skill/prompt assets
# (`.claude/skills/openspec-*`, `.agents/`, `.opencode/`, `.github/skills/`,
# `.pi/`, `.omp/`) each carry `generatedBy: "<version>"`, OpenSpec's own record
# of which CLI version last regenerated them. Nothing else keeps this synced
# with the pinned Taskfile `OPENSPEC_VERSION`, so a Renovate bump can land with
# every check green while the committed assets still declare (and behave as)
# the previous release, silently skipping the `task spec:update` regeneration
# step AGENTS.md documents as required.
#
# A cheap, fully offline, static check: every committed `generatedBy` value
# must equal the current pin. It cannot prove the generated CONTENT (prose,
# commands) is current — only running `task spec:update` does that — but it
# does catch exactly the "forgot to regenerate after bumping the pin" mistake.
set -euo pipefail
cd "$(dirname "$0")/.."

pinned="$(sed -nE 's/^[[:space:]]*OPENSPEC_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' Taskfile.yml | head -1)"
[ -n "$pinned" ] || {
    echo "FAIL: could not read OPENSPEC_VERSION from Taskfile.yml" >&2
    exit 1
}

fail=0
checked=0
while IFS= read -r f; do
    checked=$((checked + 1))
    found="$(sed -nE 's/^[[:space:]]*generatedBy:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$f" | head -1)"
    if [ "$found" != "$pinned" ]; then
        echo "FAIL: ${f} declares generatedBy \"${found}\", pinned OPENSPEC_VERSION is \"${pinned}\" — run 'task spec:update' after bumping the pin" >&2
        fail=1
    fi
done < <(grep -rl "generatedBy:" .claude .agents .opencode .github .pi .omp 2>/dev/null | sort)

[ "$checked" -gt 0 ] || {
    echo "FAIL: no generatedBy-carrying OpenSpec assets found — did openspec init/update move where it writes them?" >&2
    exit 1
}

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "openspec generated-pin OK: ${checked} generated assets declare generatedBy \"${pinned}\", matching the Taskfile pin"
