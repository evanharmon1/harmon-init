#!/usr/bin/env bash
# setup-github-labels.sh — idempotently create/update this repo's starter label
# set (docs/project-management.md). Colors are grouped by family (concerns=purple,
# source=pink, workflow=orange, layer=blue, domain=yellow).
#
# Labels are REPO-level in GitHub — there's no shared org label pool. Run this in
# each repo; org "default labels" (Settings → Repository, UI-only, no API) only
# seed NEW repos and don't touch existing ones. Non-destructive: `--force`
# creates-or-updates and it never deletes labels, so GitHub's defaults stay unless
# you prune them yourself.
#
# Usage: setup-github-labels.sh --repo <owner/repo>
# Needs: gh authed with repo write.
#
# NOTE: hits the live GitHub API, so it is not exercised by `task test:template`
# (guarded by shellcheck + shfmt only). Test it against a scratch repo.
set -euo pipefail

repo=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        repo="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "Usage: $0 --repo <owner/repo>" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Required tool not found: gh" >&2
    exit 1
fi

# name|hex-color|description — one per line. Color encodes the family.
labels="
sec|5319E7|Security concern
a11y|5319E7|Accessibility concern
perf|5319E7|Performance concern
tech-debt|5319E7|Technical debt
i18n|5319E7|Internationalization
l10n|5319E7|Localization
customer-request|EC4899|Requested by a customer
ai-generated|EC4899|Created or authored by an AI agent
needs-triage|E36209|Awaiting triage
needs-requirements|E36209|Requirements not yet defined
blocked|E36209|Blocked by a non-issue dependency (reason in a comment)
waiting|E36209|Waiting on an external party
needs-decision|E36209|Needs a decision before it can proceed
needs-response|E36209|Awaiting a response
needs-communication|E36209|An update needs to be communicated out
layer:frontend|1D76DB|Frontend
layer:backend|1D76DB|Backend
layer:infra|1D76DB|Infrastructure
domain:auth|FBCA04|Authentication and authorization
domain:billing|FBCA04|Billing and payments
"

printf '%s\n' "$labels" | while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    echo "==> label: $name"
    gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force
done

echo "==> Done — starter labels on $repo (existing labels left as-is)"
