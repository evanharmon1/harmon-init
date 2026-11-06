#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/renovate" "$tmp/template"
cp "$repo/renovate.json" "$tmp/renovate.json"
cp "$repo/renovate/default.json" "$tmp/renovate/default.json"
cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
lint="$repo/scripts/lint-renovate-holds.sh"
"$lint" "$tmp"

# Mutate every copy so parity alone cannot account for a rejection.
for field in reason upstream removal removal_missing canary; do
    python3 - "$tmp" "$field" <<'PY'
import pathlib, sys
root, field = pathlib.Path(sys.argv[1]), sys.argv[2]
for path in (root / 'renovate.json', root / 'renovate/default.json', root / 'template/renovate.json.jinja'):
    text = path.read_text()
    old, new = {
        'reason': ('Reason: TypeScript 7 requires typescript-eslint support for its native compiler', 'Reason: '),
        'upstream': ('https://github.com/typescript-eslint/typescript-eslint/issues/10940', 'invalid'),
        'removal': ('Remove when: typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7', 'Remove when: '),
        'removal_missing': ('; Remove when: typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7', ''),
        'canary': ('https://github.com/evanharmon1/harmon-init', 'invalid'),
    }[field]
    path.write_text(text.replace(old, new, 1))
PY
    if "$lint" "$tmp" >/dev/null 2>&1; then
        echo "accepted invalid $field" >&2
        exit 1
    fi
    cp "$repo/renovate.json" "$tmp/renovate.json"
    cp "$repo/renovate/default.json" "$tmp/renovate/default.json"
    cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
done
# A range drift must fail even if its description stays valid.
sed -i 's/"<7.0.0"/"<8.0.0"/' "$tmp/renovate.json"
if "$lint" "$tmp" >/dev/null 2>&1; then
    echo 'accepted a root/preset range mismatch' >&2
    exit 1
fi
echo 'Renovate hold fixtures passed'
