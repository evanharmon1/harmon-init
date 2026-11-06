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
# Exercise decoded whitespace in both free-text fields, across all copies.
# JSON escapes keep the source syntactically valid while jq sees actual tabs
# and newlines; valid controls include whitespace around meaningful text.
for field in reason removal; do
    for value in tab newline mixed valid_spaces valid_mixed; do
        python3 - "$tmp" "$field" "$value" <<'PYCODE'
import json, pathlib, sys
root, field, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
original = {
    'reason': 'TypeScript 7 requires typescript-eslint support for its native compiler',
    'removal': 'typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7',
}[field]
replacement = {
    'tab': '\t', 'newline': '\n', 'mixed': ' \t\n ',
    'valid_spaces': '  meaningful text  ', 'valid_mixed': '\t meaningful text \n',
}[value]
for path in (root / 'renovate.json', root / 'renovate/default.json', root / 'template/renovate.json.jinja'):
    text = path.read_text()
    assert text.count(original) == 1
    path.write_text(text.replace(original, json.dumps(replacement)[1:-1], 1))
PYCODE
        if [[ $value == valid_* ]]; then
            "$lint" "$tmp" || {
                echo "rejected valid $field $value" >&2
                exit 1
            }
        elif "$lint" "$tmp" >/dev/null 2>&1; then
            echo "accepted whitespace-only $field $value" >&2
            exit 1
        fi
        cp "$repo/renovate.json" "$tmp/renovate.json"
        cp "$repo/renovate/default.json" "$tmp/renovate/default.json"
        cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
    done
done
# A range drift must fail even if its description stays valid.
sed -i 's/"<7.0.0"/"<8.0.0"/' "$tmp/renovate.json"
if "$lint" "$tmp" >/dev/null 2>&1; then
    echo 'accepted a root/preset range mismatch' >&2
    exit 1
fi
echo 'Renovate hold fixtures passed'
