#!/usr/bin/env bash
# Offline contract tests: stub gh, never contact GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
catalog = json.loads((root / 'checklist-classes.json').read_text())
with tempfile.TemporaryDirectory(prefix='audit-github-') as tmp:
    fixture = Path(tmp)
    (fixture / 'scripts').mkdir()
    (fixture / 'docs').mkdir()
    (fixture / 'bin').mkdir()
    shutil.copy2(root / 'scripts/audit-github.sh', fixture / 'scripts/audit-github.sh')
    (fixture / 'scripts/label-registry-render.mjs').write_text("console.log('feature|abcdef|Feature work')\n")
    (fixture / 'checklist-classes.json').write_text(json.dumps(catalog))
    gh = fixture / 'bin/gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['AUDIT_TEST_LOG'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
assert args[:3] == ['api', '--method', 'GET'] or args[:2] == ['api', 'graphql'], args
assert not any(word in args for word in ['--input', 'POST', 'PUT', 'PATCH', 'DELETE'])
endpoint = args[3] if args[1] == '--method' else 'graphql'
data = json.loads(Path(os.environ['AUDIT_TEST_DATA']).read_text())
key = endpoint.split('?')[0]
value = data.get(endpoint, data.get(key, {'error': 403}))
if isinstance(value, dict) and 'error' in value:
    print('gh: permission unavailable (HTTP ' + str(value['error']) + ')', file=sys.stderr)
    sys.exit(1)
print(json.dumps(value) if value is not None else '')
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=str(fixture / 'bin') + os.pathsep + os.environ['PATH'],
               AUDIT_TEST_LOG=str(fixture / 'calls'), AUDIT_TEST_DATA=str(fixture / 'data.json'))
    def entry(fragment):
        return next(row for row in catalog['entries'] if row['source'] == 'root' and fragment in row['id'])
    settings = entry('automated-settings-')
    secrets = entry('actions-secret-')
    labels = entry('labels-run-')
    sast = entry('free-sast-')
    manual = entry('macos-add-')
    renovate = entry('install-and-activate-renovate-')
    app = entry('install-the-app-on-this-repo-')
    project = entry('github-project-run-')
    data = {
        'repos/acme/widget': {'delete_branch_on_merge': True, 'allow_update_branch': True, 'allow_auto_merge': False, 'visibility': 'public'},
        'repos/acme/widget/vulnerability-alerts': None,
        'repos/acme/widget/private-vulnerability-reporting': {'enabled': True},
        'repos/acme/widget/actions/variables': {'variables': [
            {'name': name, 'value': '"ubuntu-latest"'} for name in
            ['CI_RUNS_ON', 'BROWSER_RUNS_ON', 'IMAGE_BUILD_RUNS_ON', 'ISOLATED_RUNS_ON', 'MULTICORE_RUNS_ON']]},
        'repos/acme/widget/actions/secrets': {'secrets': [{'name': 'CLAUDE_CODE_OAUTH_TOKEN'}]},
        'repos/acme/widget/labels': [{'name': 'feature', 'color': 'abcdef', 'description': 'Feature work'}],
        'repos/acme/widget/issues': [{'title': 'Dependency Dashboard', 'user': {'login': 'renovate[bot]'}}],
        'repos/acme/widget/actions/runs': {'workflow_runs': [{'id': 42}]},
        'repos/acme/widget/actions/runs/42/jobs': {'jobs': [{'steps': [{'name': 'Run actions/create-github-app-token@sha', 'conclusion': 'success'}]}]},
        'graphql': {'data': {'repository': {'projectsV2': {'nodes': [{'id': 'P1', 'title': 'widget'}], 'pageInfo': {'hasNextPage': False}}}}},
    }
    def run(rows, expected, payload=None, extra=()):
        (fixture / 'docs/CHECKLIST.md').write_text('\n'.join('<!-- reconcile-id: ' + row['id'] + ' -->' for row in rows))
        (fixture / 'data.json').write_text(json.dumps(data if payload is None else payload))
        (fixture / 'calls').write_text('')
        result = subprocess.run(['bash', str(fixture / 'scripts/audit-github.sh'), '--repo', 'acme/widget', *extra], env=env, capture_output=True, text=True, check=False)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(output) == len(rows), (len(output), len(rows))
        assert {row['id'] for row in output} == {row['id'] for row in rows}
        assert all(set(row) == {'id', 'class', 'result', 'reason', 'write_task'} and row['reason'] for row in output)
        assert all(row['class'] == next(item['class'] for item in rows if item['id'] == row['id']) for row in output)
        return output
    output = run([settings, secrets, labels, renovate, app], 0)
    assert all(row['result'] == 'pass' for row in output)
    assert any('minting' in row['reason'] for row in output)
    assert 'linkage present' in run([project], 2)[0]['reason']
    # Rendered profiles include only their active template IDs, never root IDs
    # or catalog items from options Copier omitted.
    rendered = [next(row for row in catalog['entries'] if row['source'] == 'template' and fragment in row['id'])
                for fragment in ('automated-settings-', 'actions-secret-')]
    assert all(row['id'].startswith('template-') for row in run(rendered, 0))
    drift = dict(data, **{'repos/acme/widget/actions/secrets': {'secrets': []}})
    assert run([secrets], 1, drift)[0]['result'] == 'fail'
    for status in (401, 403, 404, 429, 500):
        denied = dict(data, **{'repos/acme/widget/actions/secrets': {'error': status}})
        row = run([secrets], 2, denied)[0]
        assert row['result'] == 'unknown' and str(status) in row['reason']
    assert any(row['result'] == 'fail' for row in run([secrets, manual], 2, drift))  # unknown dominates drift
    assert run([sast], 2)[0]['class'] == 'unknown-when-unprivileged'
    # All four classifications have the same read-only probe semantics.
    fleet = dict(settings, **{'class': 'agent-apply-with-fleet-approval'})
    custom = dict(catalog, entries=[fleet])
    (fixture / 'checklist-classes.json').write_text(json.dumps(custom))
    assert run([fleet], 0)[0]['class'] == 'agent-apply-with-fleet-approval'
    (fixture / 'checklist-classes.json').write_text(json.dumps(catalog))
    # Every catalog ID, including inactive options, produces exactly one row.
    output = run(catalog['entries'], 2, extra=['--all'])
    assert len(output) == len(catalog['entries'])
    calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
    secret_calls = [call for call in calls if 'actions/secrets' in ' '.join(call)]
    assert len(secret_calls) == 1, secret_calls  # cached metadata inventory
    assert secret_calls[0][3].split('?')[0] == 'repos/acme/widget/actions/secrets'
    assert 'CLAUDE_CODE_OAUTH_TOKEN' not in ' '.join(secret_calls[0])
    # Permission-sensitive repository reads must never manufacture a failure.
    denied = dict(data, **{'repos/acme/widget/vulnerability-alerts': {'error': 404}})
    assert run([settings], 2, denied)[0]['result'] == 'unknown'
    invalid = dict(data, **{'repos/acme/widget/actions/secrets': {'unexpected': []}})
    assert run([secrets], 2, invalid)[0]['result'] == 'unknown'
    # A skipped mint step is not installation evidence.
    skipped = dict(data, **{'repos/acme/widget/actions/runs/42/jobs': {'jobs': [{'steps': [{'name': 'Run actions/create-github-app-token@sha', 'conclusion': 'skipped'}]}]}})
    assert run([app], 2, skipped)[0]['result'] == 'unknown'
    # Exhaustion and a denied later page cannot make a partial list pass/fail.
    many = dict(data, **{'repos/acme/widget/labels': [{'name': 'x' + str(i), 'color': 'ffffff', 'description': ''} for i in range(100)]})
    assert '10 pages' in run([labels], 2, many)[0]['reason']
    later = dict(many, **{'repos/acme/widget/labels?per_page=100&page=2': {'error': 403}})
    assert '403' in run([labels], 2, later)[0]['reason']
    # Unknown checklist IDs are rejected before any GitHub read.
    (fixture / 'docs/CHECKLIST.md').write_text('<!-- reconcile-id: unregistered -->')
    result = subprocess.run(['bash', str(fixture / 'scripts/audit-github.sh'), '--repo', 'acme/widget'], env=env, capture_output=True, text=True, check=False)
    assert result.returncode == 2 and not result.stdout
print('audit:github: complete catalog, four classes, drift, permissions, pagination, read-only calls and name-only secrets passed')
PY
