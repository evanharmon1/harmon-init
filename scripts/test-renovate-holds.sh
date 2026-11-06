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
# Exercise the actual template parity guard, including the narrow Node exception.
awk '/<<.PYGUARD./ {copy=1; next} /^PYGUARD$/ {exit} copy' "$repo/scripts/test-template.sh" >"$tmp/parity-guard.py"
python3 - "$repo/renovate/default.json" "$tmp" <<'PYTEST'
import copy, json, pathlib, subprocess, sys
preset = json.loads(pathlib.Path(sys.argv[1]).read_text())
tmp = pathlib.Path(sys.argv[2])

def is_ts(rule):
    return rule.get('matchPackageNames') == ['typescript']

def check(label, shared, rendered, profile, expected):
    (tmp / 'shared.json').write_text(json.dumps(shared))
    (tmp / 'rendered.json').write_text(json.dumps(rendered))
    result = subprocess.run([sys.executable, str(tmp / 'parity-guard.py'), str(tmp / 'shared.json'),
                             str(tmp / 'rendered.json'), profile], capture_output=True, text=True)
    if (result.returncode == 0) != expected:
        sys.exit(f'{label}: unexpected exit {result.returncode}: {result.stderr}')

minimal = copy.deepcopy(preset)
minimal['packageRules'] = [r for r in minimal['packageRules'] if not is_ts(r)]
check('minimal valid', preset, minimal, 'minimal', True)
check('Node valid', preset, preset, 'web', True)
changed = copy.deepcopy(minimal)
changed['schedule'] = ['* * * * *']
check('common policy drift', preset, changed, 'minimal', False)
changed = copy.deepcopy(minimal)
changed['packageRules'].append({'matchPackageNames': ['other'], 'allowedVersions': '<2'})
check('unrelated hold', preset, changed, 'minimal', False)
changed = copy.deepcopy(minimal)
changed['osvVulnerabilityAlerts'] = False
shared = copy.deepcopy(preset)
shared['osvVulnerabilityAlerts'] = False
check('both feeds disabled equally', shared, changed, 'minimal', False)
check('Node hold missing', preset, minimal, 'web', False)
changed = copy.deepcopy(preset)
next(r for r in changed['packageRules'] if is_ts(r))['allowedVersions'] = '<8.0.0'
check('Node hold wrong', preset, changed, 'web', False)
check('both TypeScript holds wrong', changed, changed, 'web', False)
check('preset hold missing', minimal, minimal, 'minimal', False)
check('non-Node hold unexpectedly present', preset, preset, 'iac', False)
PYTEST
echo 'Renovate hold fixtures passed'
