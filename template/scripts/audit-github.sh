#!/usr/bin/env bash
# Read-only checklist audit. Stdout is NDJSON; diagnostics go to stderr.
# Requires python3 and gh. No secret value endpoint is ever requested.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description='Read-only GitHub checklist audit (NDJSON). Exit 0: clean, 1: drift, 2: unavailable (takes precedence). Manual evidence is unknown.')
parser.add_argument('--repo', help='[HOST/]OWNER/REPO; defaults to gh repository resolution')
parser.add_argument('--all', action='store_true', help='audit every catalog entry, including inactive template options')
parser.add_argument('--foreman', action='store_true', help='include Foreman labels in registry comparison')
parser.add_argument('--release-please', action='store_true', help='include release-please labels in registry comparison')
parser.add_argument('--bot-collaborator', help='expected bot login for the repository settings probe')
args = parser.parse_args()


def command(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Unavailable('command unavailable or timed out') from None
    if result.returncode:
        # Preserve status, never echo response bodies or credentials into reports.
        status = re.search(r'HTTP[ /]+(\d{3})', result.stderr)
        raise Unavailable('GitHub read unavailable' + (' (HTTP ' + status[1] + ')' if status else ' (no HTTP status)'))
    try:
        return json.loads(result.stdout) if result.stdout.strip() else None
    except ValueError:
        raise Unavailable('GitHub response is not valid JSON') from None


class Unavailable(Exception):
    pass


cache = {}
repo = None
host = None
try:
    target = args.repo
    if not target:
        target = command(['gh', 'repo', 'view', '--json', 'nameWithOwner,url'])
        host = target['url'].split('/')[2]
        target = target['nameWithOwner']
    parts = target.split('/')
    if len(parts) == 3:
        host, owner, name = parts
    elif len(parts) == 2:
        owner, name = parts
    else:
        raise Unavailable('repository must be [HOST/]OWNER/REPO')
    if not all(re.fullmatch(r'[A-Za-z0-9_.-]+', part) for part in (owner, name)):
        raise Unavailable('invalid repository')
    repo = owner + '/' + name
    target_error = None
except (Unavailable, KeyError, IndexError) as error:
    target_error = str(error)


def api(endpoint, key=None, paginated=False):
    """GET only, bounded pagination; cache evidence within this invocation."""
    identity = (endpoint, key, paginated)
    if identity not in cache:
        try:
            if target_error:
                raise Unavailable(target_error)
            values = []
            for page in range(1, 11):
                path = endpoint
                if paginated:
                    path += ('&' if '?' in path else '?') + f'per_page=100&page={page}'
                argv = ['gh', 'api', '--method', 'GET', path]
                if host:
                    argv += ['--hostname', host]
                payload = command(argv)
                if not paginated:
                    cache[identity] = payload
                    break
                payload = payload.get(key) if key and isinstance(payload, dict) else payload
                if not isinstance(payload, list):
                    raise Unavailable('GitHub list response has an unsupported shape')
                values.extend(payload)
                if len(payload) < 100:
                    cache[identity] = values
                    break
            else:
                raise Unavailable('GitHub pagination exceeded 10 pages; evidence incomplete')
        except Unavailable as error:
            cache[identity] = error
    result = cache[identity]
    if isinstance(result, Unavailable):
        raise result
    return result


def read(path, key=None, pages=False):
    return api('repos/' + repo + '/' + path, key, pages) if repo else api('', key, pages)


def field(data, name):
    if not isinstance(data, dict) or name not in data:
        raise Unavailable('GitHub response omitted ' + name)
    return data[name]


def names(path, key):
    values = read(path, key, True)
    if any(not isinstance(item, dict) or not isinstance(item.get('name'), str) for item in values):
        raise Unavailable('GitHub name inventory has an unsupported shape')
    return {item['name'] for item in values}


def secret(*expected):
    # This endpoint returns names/metadata only, never encrypted or clear values.
    missing = set(expected) - names('actions/secrets', 'secrets')
    return (not missing, 'secret names present' if not missing else 'missing secret names: ' + ', '.join(sorted(missing)))


def outcome(ok, reason):
    return ('pass' if ok else 'fail', reason)


def probe(entry):
    item = entry['id']
    manual = 'manual evidence required: ' + (entry['probe'] or 'no read-only probe is available')
    if 'automated-settings-' in item:
        settings = api('repos/' + repo) if repo else api('')
        if args.bot_collaborator and not re.fullmatch(r'[A-Za-z0-9-]+', args.bot_collaborator):
            raise Unavailable('invalid bot collaborator login')
        ok = (field(settings, 'delete_branch_on_merge') is True and
              field(settings, 'allow_update_branch') is True and
              field(settings, 'allow_auto_merge') is False)
        # A 404 on this permission-sensitive endpoint is unknown, never disabled.
        api('repos/' + repo + '/vulnerability-alerts')
        if field(settings, 'visibility') == 'public':
            ok = field(read('private-vulnerability-reporting'), 'enabled') is True and ok
        variables = read('actions/variables', 'variables', True)
        routing = {row['name']: row['value'] for row in variables}
        expected = ('CI_RUNS_ON', 'BROWSER_RUNS_ON', 'IMAGE_BUILD_RUNS_ON', 'ISOLATED_RUNS_ON', 'MULTICORE_RUNS_ON')
        if not all(key in routing for key in expected):
            raise Unavailable('runner variables missing; inherited organization values require operator verification')
        for key in expected:
            try:
                selector = json.loads(routing[key])
            except (ValueError, TypeError):
                return outcome(False, 'invalid runner selector: ' + key)
            labels = selector.get('labels') if isinstance(selector, dict) else selector
            labels = [labels] if isinstance(labels, str) else labels
            valid = isinstance(labels, list) and bool(labels) and all(isinstance(label, str) and label for label in labels)
            ok = valid and ok
            if key == 'ISOLATED_RUNS_ON' and valid:
                ok = all(label.lower() != 'self-hosted' for label in labels) and ok
        if args.bot_collaborator:
            permission = field(read('collaborators/' + args.bot_collaborator + '/permission'), 'permission')
            ok = permission in ('admin', 'maintain', 'write') and ok
        return outcome(ok, 'repository merge/security settings and runner routing' + ('; bot permission checked' if args.bot_collaborator else '; no bot login specified'))
    if 'actions-secret-claude-code' in item:
        return outcome(*secret('CLAUDE_CODE_OAUTH_TOKEN'))
    if 'set-ci-app-client-id-' in item:
        ok, reason = secret('CI_APP_PRIVATE_KEY')
        present = 'CI_APP_CLIENT_ID' in names('actions/variables', 'variables')
        return outcome(ok and present, reason + '; CI_APP_CLIENT_ID variable ' + ('present' if present else 'missing'))
    if 'snyk' in item:
        ok, reason = secret('SNYK_TOKEN')
        # Schedule opt-in is explicit; name presence alone cannot prove posture.
        raise Unavailable(reason + '; workflow schedule and intended Snyk posture require operator verification')
    if 'install-and-activate-renovate-' in item:
        issues = read('issues?state=open', pages=True)
        found = any(row.get('title') == 'Dependency Dashboard' and row.get('user', {}).get('login') in ('renovate[bot]', 'renovate-bot') for row in issues)
        return outcome(found, 'Renovate Dependency Dashboard ' + ('present' if found else 'absent'))
    if 'install-the-app-on-this-repo-' in item:
        # A succeeded workflow is evidence of token minting only when the workflow
        # itself contains the mint step. Whole-run success can skip that step.
        runs = read('actions/runs?status=success', 'workflow_runs', True)
        for run in runs[:20]:
            jobs = read('actions/runs/' + str(run['id']) + '/jobs?filter=latest', 'jobs', True)
            for job in jobs:
                for step in job.get('steps', []):
                    if 'actions/create-github-app-token@' in step.get('name', '') and step.get('conclusion') == 'success':
                        return outcome(True, 'succeeded App token-minting step in run ' + str(run['id']))
        raise Unavailable('no succeeded token-minting step in the latest 20 successful runs; installation cannot be inferred')
    if any(part in item for part in ('coderabbit', 'greptile', 'gemini-code', 'connect-codex')):
        pulls = read('pulls?state=all&sort=updated&direction=desc', pages=True)
        login = ('coderabbitai[bot]' if 'coderabbit' in item else
                 'chatgpt-codex-connector[bot]' if 'codex' in item else
                 'gemini-code-assist[bot]' if 'gemini' in item else 'greptile-apps[bot]')
        observed = False
        for pull in pulls[:20]:
            reviews = read('pulls/' + str(pull['number']) + '/reviews', pages=True)
            if any(review.get('user', {}).get('login') == login for review in reviews):
                observed = True
                break
        raise Unavailable(login + (' review evidence present' if observed else ' not observed in latest 20 updated PRs') + '; connection and service preferences require manual verification')
    if 'import-the-branch-ruleset-' in item or 'add-closing-keywords-' in item or 'enable-unattributed-' in item:
        rules = read('rulesets?includes_parents=true', pages=True)
        if 'import-the-branch' in item:
            desired = json.loads(Path('.github/Branch Protection Ruleset - Protect Main.json').read_text())
            return outcome(any(row.get('name') == desired['name'] and row.get('enforcement') == 'active' for row in rules), 'named active ruleset presence only; content comparison: task audit:ruleset')
        raise Unavailable('read ' + str(len(rules)) + ' rulesets; approval/check conditions require task audit:ruleset and manual applicability review')
    if 'disable-github-codeql-' in item:
        return outcome(field(read('code-scanning/default-setup'), 'state') == 'not-configured', 'CodeQL default setup state')
    if 'free-sast-' in item or 'sast-coverage-' in item:
        read('code-scanning/default-setup')
        raise Unavailable('code scanning configuration readable; language coverage requires manual verification')
    if 'labels-run-task-' in item or 'after-a-copier-update-that-adds-labe-' in item:
        live = {row['name']: row for row in read('labels', pages=True)}
        # Use the same registry renderer as setup:github-labels, when available.
        renderer = Path('scripts/label-registry-render.mjs')
        if not renderer.exists():
            raise Unavailable('label registry renderer unavailable')
        argv = ['node', str(renderer), 'labels']
        if args.foreman or Path('.foreman.toml').exists():
            argv.append('--foreman')
        if args.release_please or Path('.release-please-manifest.json').exists():
            argv.append('--release-please')
        try:
            rendered = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise Unavailable('label registry renderer unavailable') from None
        if rendered.returncode:
            raise Unavailable('label registry rendering failed')
        drift = []
        for line in rendered.stdout.splitlines():
            label, color, description = line.split('|', 2)
            row = live.get(label)
            if row is None or field(row, 'color').lower() != color.lower() or (field(row, 'description') or '') != description:
                drift.append(label)
        if not rendered.stdout.strip():
            raise Unavailable('label registry renderer returned no labels')
        return outcome(not drift, 'registry label drift: ' + (', '.join(drift) or 'none') + '; extra labels preserved')
    if 'retire-any-legacy-agent-claim-' in item:
        labels = names('labels', None)
        legacy = sorted(name for name in labels if name.startswith('agent:'))
        return outcome(not legacy, 'legacy claim labels: ' + (', '.join(legacy) or 'none'))
    if 'github-project-run-' in item or 'org-issue-fields-run-' in item or 'org-issue-types-run-' in item:
        # REST's repository projects endpoint is Projects classic, not Projects V2.
        # Query actual repository linkage with GraphQL instead of reporting classic.
        query = 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){projectsV2(first:100){nodes{id title} pageInfo{hasNextPage}}}}'
        argv = ['gh', 'api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner, '-f', 'name=' + name]
        if host:
            argv += ['--hostname', host]
        payload = command(argv)
        if payload.get('errors'):
            raise Unavailable('GitHub GraphQL project read denied or incomplete (HTTP 200)')
        projects = payload['data']['repository']['projectsV2']
        if projects['pageInfo']['hasNextPage']:
            raise Unavailable('project linkage exceeds 100 results')
        if 'github-project-run-' in item:
            if not projects['nodes']:
                return outcome(False, 'Projects V2 repository linkage absent')
            raise Unavailable('Projects V2 repository linkage present; expected project and field configuration require operator verification')
        raise Unavailable('read ' + str(len(projects['nodes'])) + ' linked Projects V2; organization issue fields/types require operator verification')
    return ('unknown', manual)


try:
    catalog = json.loads(Path('checklist-classes.json').read_text())
    entries = catalog['entries']
    if catalog.get('schema_version') != 1 or not isinstance(entries, list) or not entries:
        raise ValueError('unsupported or empty checklist catalog')
    if len({entry['id'] for entry in entries}) != len(entries):
        raise ValueError('duplicate catalog IDs')
    if not args.all:
        checklist = Path('docs/CHECKLIST.md').read_text()
        ids = set(re.findall(r'<!-- reconcile-id: ([a-z0-9-]+) -->', checklist))
        selected = {entry['id'] for entry in entries}
        if not ids or ids - selected:
            raise ValueError('checklist IDs missing from catalog')
        entries = [entry for entry in entries if entry['id'] in ids]
except (OSError, ValueError, KeyError, TypeError) as error:
    print('audit:github unavailable: ' + str(error), file=sys.stderr)
    sys.exit(2)

exit_code = 0
for entry in entries:
    try:
        result, reason = probe(entry)
    except (Unavailable, OSError, KeyError, TypeError, ValueError, AttributeError) as error:
        result, reason = 'unknown', str(error) or 'unsupported GitHub response'
    if result == 'unknown':
        exit_code = 2
    elif result == 'fail' and exit_code == 0:
        exit_code = 1
    print(json.dumps({'id': entry['id'], 'class': entry['class'], 'result': result,
                      'reason': reason, 'write_task': entry['write_task']}))
sys.exit(exit_code)
PY
