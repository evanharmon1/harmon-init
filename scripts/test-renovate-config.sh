#!/usr/bin/env bash
# test-renovate-config.sh — strictly validate rendered Renovate configuration
# for one template profile or the complete profile matrix.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

requested="${1:-all}"
case "$requested" in
all)
    profiles=(minimal web webapp iac full meta update)
    ;;
minimal | web | webapp | iac | full | meta | update)
    profiles=("$requested")
    ;;
*)
    echo "Unknown profile: ${requested}" >&2
    exit 2
    ;;
esac

if ! command -v npx >/dev/null 2>&1; then
    echo "FAIL: required tool 'npx' is not installed for strict Renovate configuration validation" >&2
    exit 1
fi

# Validate the dogfood layer once before rendering the template profiles.
# renovate: datasource=npm depName=renovate
RENOVATE_VALIDATOR_VERSION=44.110.0
npx --yes --package "renovate@${RENOVATE_VALIDATOR_VERSION}" -- \
    renovate-config-validator --strict renovate.json

for profile in "${profiles[@]}"; do
    if [ "$profile" = "update" ]; then
        ./scripts/test-template-update.sh renovate-config
    else
        ./scripts/test-template.sh "$profile" renovate-config
    fi
done
