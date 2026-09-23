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

for profile in "${profiles[@]}"; do
    if [ "$profile" = "update" ]; then
        ./scripts/test-template-update.sh renovate-config
    else
        ./scripts/test-template.sh "$profile" renovate-config
    fi
done
