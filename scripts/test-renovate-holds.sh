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
    text = path.read_text(encoding='utf-8')
    old, new = {
        'reason': ('Reason: TypeScript 7 requires typescript-eslint support for its native compiler', 'Reason: '),
        'upstream': ('https://github.com/typescript-eslint/typescript-eslint/issues/10940', 'invalid'),
        'removal': ('Remove when: typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7', 'Remove when: '),
        'removal_missing': ('; Remove when: typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7', ''),
        'canary': ('https://github.com/evanharmon1/harmon-init', 'invalid'),
    }[field]
    path.write_text(text.replace(old, new, 1), encoding='utf-8')
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
    text = path.read_text(encoding='utf-8')
    assert text.count(original) == 1
    path.write_text(text.replace(original, json.dumps(replacement)[1:-1], 1), encoding='utf-8')
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
# Escaped keys are valid JSON. Reject incomplete holds even when every copy
# uses the same spelling, and when the generated consumer has no preset.
for mode in consumer copies; do
    for missing in description removal; do
        python3 - "$tmp" "$mode" "$missing" <<'PYCASE'
import pathlib, sys
root, mode, missing = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
paths = [root / 'renovate.json']
if mode == 'copies':
    paths += [root / 'renovate/default.json', root / 'template/renovate.json.jinja']
for path in paths:
    text = path.read_text(encoding='utf-8')
    match = text.index('"matchPackageNames": ["typescript"]')
    start = text.rindex('{', 0, match)
    end = text.index('}', match)
    rule = text[start:end]
    assert '"allowedVersions"' in rule and '"description"' in rule
    rule = rule.replace('"allowedVersions"', r'"allowed\u0056ersions"', 1)
    if missing == 'description':
        import re
        rule = re.sub(r'"description": "[^"\n]*",?\s*', '', rule, count=1)
    else:
        rule = rule.replace('; Remove when: typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7', '', 1)
    if mode == 'consumer':
        path.write_text('{"packageRules": [' + rule + '}]}', encoding='utf-8')
    else:
        path.write_text(text[:start] + rule + text[end:], encoding='utf-8')
if mode == 'consumer':
    (root / 'renovate/default.json').unlink()
PYCASE
        if "$lint" "$tmp" >"$tmp/diagnostic" 2>&1; then
            echo "accepted escaped hold key with missing $missing ($mode)" >&2
            exit 1
        fi
        if ! grep -q 'allowedVersions rule needs Reason' "$tmp/diagnostic"; then
            echo "escaped hold key failed for the wrong reason ($mode, $missing)" >&2
            exit 1
        fi
        cp "$repo/renovate.json" "$tmp/renovate.json"
        cp "$repo/renovate/default.json" "$tmp/renovate/default.json"
        cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
    done
done
# JSON-decoded whitespace and controls cannot form a GitHub owner or repo.
for component in upstream_owner upstream_repo canary_owner canary_repo; do
    for value in tab newline control; do
        python3 - "$tmp" "$component" "$value" <<'PYURL'
import json, pathlib, sys
root, component, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
old = {
    'upstream_owner': 'github.com/typescript-eslint/typescript-eslint/issues/10940',
    'upstream_repo': 'github.com/typescript-eslint/typescript-eslint/issues/10940',
    'canary_owner': 'github.com/evanharmon1/harmon-init',
    'canary_repo': 'github.com/evanharmon1/harmon-init',
}[component]
parts = old.split('/')
parts[1 if component.endswith('owner') else 2] = json.dumps({'tab': '\t', 'newline': '\n', 'control': '\x01'}[value])[1:-1]
for path in (root / 'renovate.json', root / 'renovate/default.json', root / 'template/renovate.json.jinja'):
    text = path.read_text(encoding='utf-8')
    assert old in text
    path.write_text(text.replace(old, '/'.join(parts), 1), encoding='utf-8')
PYURL
        if "$lint" "$tmp" >/dev/null 2>&1; then
            echo "accepted $value in $component" >&2
            exit 1
        fi
        cp "$repo/renovate.json" "$tmp/renovate.json"
        cp "$repo/renovate/default.json" "$tmp/renovate/default.json"
        cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
    done
done
# Quoted braces and escaped quotes are JSON data in both paired and consumer configs.
for mode in copies consumer; do
    if [[ $mode == consumer ]]; then
        cp "$repo/renovate/default.json" "$tmp/renovate.json"
    fi
    python3 - "$tmp" "$mode" <<'PYBRACE'
import pathlib, sys
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
paths = [root / 'renovate.json']
if mode == 'copies':
    paths += [root / 'renovate/default.json', root / 'template/renovate.json.jinja']
for path in paths:
    text = path.read_text(encoding='utf-8')
    text = text.replace('Reason: TypeScript 7 requires', r'Reason: {candidate} \"quoted\" TypeScript 7 requires', 1)
    path.write_text(text, encoding='utf-8')
if mode == 'consumer':
    (root / 'renovate/default.json').unlink()
PYBRACE
    "$lint" "$tmp"
    cp "$repo/renovate.json" "$tmp/renovate.json"
    cp "$repo/renovate/default.json" "$tmp/renovate/default.json"
    cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
done
# A template hold whose object contains Jinja is outside the bounded extractor.
python3 - "$tmp/template/renovate.json.jinja" <<'PYUNSUPPORTED'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
text = text.replace('"allowedVersions": "<7.0.0"', '"allowedVersions": [[ unsupported ]]', 1)
path.write_text(text, encoding='utf-8')
PYUNSUPPORTED
if "$lint" "$tmp" >"$tmp/diagnostic" 2>&1; then
    echo 'accepted unsupported template hold' >&2
    exit 1
fi
if ! grep -q 'cannot inspect every allowedVersions rule' "$tmp/diagnostic"; then
    echo 'unsupported template hold failed for the wrong reason' >&2
    exit 1
fi
cp "$repo/template/renovate.json.jinja" "$tmp/template/renovate.json.jinja"
# A range drift must fail even if its description stays valid.
sed -i.bak 's/"<7.0.0"/"<8.0.0"/' "$tmp/renovate.json"
if "$lint" "$tmp" >/dev/null 2>&1; then
    echo 'accepted a root/preset range mismatch' >&2
    exit 1
fi
# Exercise the actual template parity guard, including the narrow Node exception.
awk '/<<.PYGUARD./ {copy=1; next} /^PYGUARD$/ {exit} copy' "$repo/scripts/test-template.sh" >"$tmp/parity-guard.py"
python3 - "$repo/renovate/default.json" "$tmp" <<'PYTEST'
import copy, json, pathlib, subprocess, sys
preset = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
tmp = pathlib.Path(sys.argv[2])

def is_ts(rule):
    return rule.get('matchPackageNames') == ['typescript']

def check(label, shared, rendered, profile, expected):
    (tmp / 'shared.json').write_text(json.dumps(shared), encoding='utf-8')
    (tmp / 'rendered.json').write_text(json.dumps(rendered), encoding='utf-8')
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
# A private consumer may keep its config at .github/renovate.json; a root
# renovate.json, .jsonc or .json5 takes precedence because Renovate reads it first.
alt="$tmp/alt"
mkdir -p "$alt/.github"
strip_removal() {
    python3 - "$1" <<'PYALT'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
old = '; Remove when: typescript-eslint supports TypeScript 7 and the canary Node and Astro checks pass with TypeScript 7'
assert text.count(old) == 1
path.write_text(text.replace(old, '', 1), encoding='utf-8')
PYALT
}
expect_alt_failure() {
    if "$lint" "$alt" >"$tmp/diagnostic" 2>&1; then
        echo "accepted $1" >&2
        exit 1
    fi
    if ! grep -qF "$2" "$tmp/diagnostic"; then
        echo "$1 failed for the wrong reason: $(cat "$tmp/diagnostic")" >&2
        exit 1
    fi
}
expect_alt_failure 'a consumer with no Renovate config' \
    'renovate.json: missing (checked renovate.json, renovate.jsonc, renovate.json5 and the same names under .github/)'
cp "$repo/renovate/default.json" "$alt/.github/renovate.json"
"$lint" "$alt" || {
    echo 'rejected valid holds in .github/renovate.json' >&2
    exit 1
}
strip_removal "$alt/.github/renovate.json"
expect_alt_failure 'missing hold metadata in .github/renovate.json' \
    '.github/renovate.json: allowedVersions rule needs Reason'
cp "$repo/renovate/default.json" "$alt/renovate.json"
"$lint" "$alt" || {
    echo 'checked .github/renovate.json although the root config exists' >&2
    exit 1
}
cp "$repo/renovate/default.json" "$alt/.github/renovate.json"
strip_removal "$alt/renovate.json"
expect_alt_failure 'missing hold metadata in a root config beside .github/renovate.json' \
    'renovate.json: allowedVersions rule needs Reason'
if grep -qF '.github/' "$tmp/diagnostic"; then
    echo 'root config precedence reported the .github config' >&2
    exit 1
fi
# A root renovate.json5 is what Renovate reads, so a valid .github config
# cannot stand in for it and an invalid one is not the file reported.
rm "$alt/renovate.json"
cp "$repo/renovate/default.json" "$alt/renovate.json5"
strip_removal "$alt/renovate.json5"
expect_alt_failure 'an invalid root renovate.json5 beside a valid .github/renovate.json' \
    'renovate.json5: the hold checker reads only renovate.json or .github/renovate.json'
cp "$repo/renovate/default.json" "$alt/renovate.json5"
strip_removal "$alt/.github/renovate.json"
expect_alt_failure 'a root renovate.json5 beside an invalid .github/renovate.json' \
    'renovate.json5: the hold checker reads only renovate.json or .github/renovate.json'
if grep -qF '.github/renovate.json:' "$tmp/diagnostic"; then
    echo 'a root renovate.json5 reported the .github config' >&2
    exit 1
fi
# Renovate's order, highest first. For every adjacent pair, the higher file
# beside a valid lower one must be the file checked: an invalid .json fails on
# its records and a .jsonc/.json5 fails closed, each naming the higher file.
order=(renovate.json renovate.jsonc renovate.json5
    .github/renovate.json .github/renovate.jsonc .github/renovate.json5)
alt="$tmp/order"
for ((i = 0; i + 1 < ${#order[@]}; i++)); do
    high=${order[i]} low=${order[i + 1]}
    rm -rf "$alt"
    mkdir -p "$alt/.github"
    cp "$repo/renovate/default.json" "$alt/$low"
    cp "$repo/renovate/default.json" "$alt/$high"
    if [[ $high == *.json ]]; then
        strip_removal "$alt/$high"
        expected="$high: allowedVersions rule needs Reason"
    else
        expected="$high: the hold checker reads only renovate.json or .github/renovate.json"
    fi
    if "$lint" "$alt" >"$tmp/diagnostic" 2>&1; then
        echo "accepted $high beside a valid $low" >&2
        exit 1
    fi
    if [[ $(head -n 1 "$tmp/diagnostic") != "$expected"* ]]; then
        echo "$high beside $low checked the wrong file: $(cat "$tmp/diagnostic")" >&2
        exit 1
    fi
done
rm -rf "$alt"
mkdir -p "$alt"
cp "$repo/renovate/default.json" "$alt/renovate.json"
cp "$repo/renovate/default.json" "$alt/renovate.json5"
"$lint" "$alt" || {
    echo 'rejected a valid renovate.json beside renovate.json5' >&2
    exit 1
}
echo 'Renovate hold fixtures passed'
