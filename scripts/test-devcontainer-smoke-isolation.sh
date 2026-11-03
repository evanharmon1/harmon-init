#!/usr/bin/env bash
# Exercise the real smoke script against a stateful Docker/CLI fixture. Root
# also renders the actual Python-enabled configs; consumers use their configs.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$repo_root" "$work" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

repo, work = map(Path, sys.argv[1:])

def check(ok, message):
    if not ok:
        raise AssertionError(message)


def run(args, **kwargs):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, **kwargs)
    check(result.returncode == 0, f'{args}: exit {result.returncode}\n{result.stdout}')
    return result.stdout


# JSONC comments are removed outside strings (URLs contain //); these configs
# have no trailing commas. Decode with json rather than evaluating config data.
def config(path):
    src = path.read_text()
    clean = re.sub(r'("(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/)',
                   lambda m: m[0] if m[0].startswith('"') else '', src)
    return json.loads(clean)


fixture = work / 'workspace'
if (repo / '.dogfood-answers.yml').exists():
    source = work / 'source'
    source.mkdir()
    shutil.copy(repo / 'copier.yml', source / 'copier.yml')
    template = source / 'template' / '[% if devcontainer %].devcontainer[% endif %]'
    for profile in ('', 'dev/', 'agent/'):
        dest = template / (profile + 'devcontainer.json.jinja')
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(repo / 'template' / '[% if devcontainer %].devcontainer[% endif %]'
                    / (profile + 'devcontainer.json.jinja'), dest)
    run(['copier', 'copy', '--trust', '--defaults', '--quiet',
         '-d', 'project_type=iac', '-d', 'project_name=SmokeFixture',
         '-d', 'github_org=smoke-tests', '-d', 'devcontainer=true',
         '-d', 'git_init=false', '-d', 'run_task_install=false',
         str(source), str(fixture)])
else:
    shutil.copytree(repo / '.devcontainer', fixture / '.devcontainer')

scripts = fixture / 'scripts'
scripts.mkdir(exist_ok=True)
shutil.copy(repo / 'scripts/devcontainer-smoke.sh', scripts / 'devcontainer-smoke.sh')
# Assertions block on a per-invocation release file so concurrent cleanup is
# tested while another invocation still owns a working environment.
(scripts / 'devcontainer-assert.sh').write_text('''#!/usr/bin/env bash
set -eu
id="$3"
touch "$SMOKE_FIXTURE_STATE/ready/$id"
attempt=0
while [ -d "$SMOKE_FIXTURE_STATE/release" ] && [ ! -f "$SMOKE_FIXTURE_STATE/release/$id" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 400 ] || exit 1
    sleep 0.05
done
''')
state = work / 'state'
for directory in ('volumes', 'containers', 'ready', 'release', 'records'):
    (state / directory).mkdir(parents=True)

# This executable implements external tool behavior, not the script's cleanup
# policy. Volume listing deliberately returns substring matches like Docker.
tool = work / 'tools' / 'fixture-tool'
tool.parent.mkdir()
tool.write_text('''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
s = Path(os.environ['SMOKE_FIXTURE_STATE'])
a = sys.argv[1:]
def flag(name): return a[a.index(name)+1]
if Path(sys.argv[0]).name == 'docker':
    if a[0] == 'info': sys.exit(0)
    if a[0] == 'ps':
        key, value = flag('--filter').removeprefix('label=').split('=', 1)
        for p in (s/'containers').iterdir():
            if json.loads((p/'metadata').read_text())['labels'].get(key) == value:
                print(p.name)
    elif a[0] == 'rm':
        for cid in a[2:]: shutil.rmtree(s/'containers'/cid)
    elif a[:2] == ['volume', 'ls']:
        value = flag('--filter').removeprefix('name=')
        for p in (s/'volumes').iterdir():
            if value in p.name: print(p.name)
    elif a[:2] == ['volume', 'rm']:
        for volume in a[2:]: shutil.rmtree(s/'volumes'/volume)
    else: raise AssertionError(a)
else:
    assert a[0] == 'up', a
    # An explicit id-label replaces CLI workspace-based lookup; with no label,
    # overlapping invocations resolve to the same container in the fixture.
    labels = dict([flag('--id-label').split('=', 1)]) if '--id-label' in a else {}
    cid = os.environ['SMOKE_FIXTURE_CASE'] if labels else 'shared-workspace'
    p = s/'containers'/cid
    p.mkdir()
    (p/'metadata').write_text(json.dumps({'labels': labels}))
    config = json.loads(Path(os.environ['SMOKE_FIXTURE_CONFIG']).read_text())
    suffix = os.environ['HARMON_DEVCONTAINER_SMOKE_VOLUME_SUFFIX']
    mounts = []
    for mount in config['mounts']:
        mount = mount.replace('${localEnv:HARMON_DEVCONTAINER_SMOKE_VOLUME_SUFFIX}', suffix)
        spec = dict(part.split('=',1) for part in mount.split(','))
        if spec.get('type') != 'volume': continue
        volume = s/'volumes'/spec['source']
        volume.mkdir(exist_ok=True)
        mounts.append(spec)
        if spec['target'].endswith('/.venv'):
            # A container-local interpreter disappears when its owner exits.
            interpreter = p/'python'
            interpreter.write_text(cid)
            bin_dir = volume/'bin'
            bin_dir.mkdir(exist_ok=True)
            link = bin_dir/'python'
            assert not link.is_symlink(), 'inherited virtualenv from another invocation'
            link.symlink_to(interpreter)
            (volume/'owner').write_text(cid)
    # A substring match must not let cleanup remove this foreign volume.
    (s/'volumes'/('foreign'+suffix+'-keep')).mkdir()
    (s/'records'/cid).write_text(json.dumps({'suffix':suffix,'mounts':mounts,'args':a}))
    if os.environ.get('SMOKE_FIXTURE_FAIL') == '1': sys.exit(2)
    print(json.dumps({'outcome':'success','containerId':cid,
                     'remoteWorkspaceFolder':'/workspaces/smoke-fixture'}))
''')
tool.chmod(0o755)
for name in ('docker', 'devcontainer'):
    (tool.parent / name).symlink_to(tool)
env = dict(os.environ, PATH=str(tool.parent) + os.pathsep + os.environ['PATH'],
           SMOKE_FIXTURE_STATE=str(state))
children = []


def start(profile, cid, fail=False):
    path = fixture / '.devcontainer' / profile / 'devcontainer.json'
    cfg = config(path)
    data = work / (cid + '.json')
    data.write_text(json.dumps(cfg))
    log = work / (cid + '.log')
    child_env = dict(env, SMOKE_FIXTURE_CASE=cid, SMOKE_FIXTURE_CONFIG=str(data),
                     SMOKE_FIXTURE_FAIL='1' if fail else '0')
    with log.open('w') as out:
        child = subprocess.Popen(['bash', str(scripts / 'devcontainer-smoke.sh'), str(path)],
                                 env=child_env, stdout=out, stderr=subprocess.STDOUT)
        children.append((child, cid))
    return child, log, cfg


def wait_ready(child, log, cid):
    deadline = time.monotonic() + 20
    while not (state / 'ready' / cid).exists():
        check(child.poll() is None, f'{cid} exited early: {log.read_text()}')
        check(time.monotonic() < deadline, f'{cid} did not reach assertions: {log.read_text()}')
        time.sleep(0.05)
    return json.loads((state / 'records' / cid).read_text())


def finish(child, log, cid, expected=0):
    (state / 'release' / cid).touch()
    status = child.wait(timeout=25)
    check(status == expected, f'{cid}: {status}\n{log.read_text()}')
    check(not (state / 'containers' / cid).exists(), f'{cid}: leaked container')
    record = json.loads((state / 'records' / cid).read_text())
    for m in record['mounts']:
        if m['source'].endswith(record['suffix']):
            check(not (state / 'volumes' / m['source']).exists(), f'{cid}: leaked volume {m}')
    check((state / 'volumes' / ('foreign'+record['suffix']+'-keep')).is_dir(),
          'cleanup removed a substring match owned by someone else')
    return record


def exercise_profiles():
    for profile in ('', 'dev', 'agent'):
        key = profile or 'bot'
        cfg = config(fixture / '.devcontainer' / profile / 'devcontainer.json')
        baseline = []
        for mount in cfg['mounts']:
            spec = dict(part.split('=', 1) for part in mount.split(','))
            if spec.get('type') != 'volume':
                continue
            name = spec['source'].replace('${localEnv:HARMON_DEVCONTAINER_SMOKE_VOLUME_SUFFIX}', '')
            baseline.append(name)
            volume = state / 'volumes' / name
            volume.mkdir(exist_ok=True)
            (volume / 'persistent').write_text('developer state')
            if spec['target'].endswith('/.venv'):
                (volume / 'bin').mkdir(exist_ok=True)
                (volume / 'bin/python').symlink_to(
                    '/home/vscode/.local/share/uv/python/cpython-3.14-linux-x86_64-gnu/bin/python3.14')
        python_mounts = [m for m in cfg['mounts'] if '/.venv,' in m]
        if (repo / '.dogfood-answers.yml').exists():
            check(len(python_mounts) == 1, f'{key}: Python-enabled render missing venv')
            expected = 'venv-smoke-tests-smokefixture' + ('-' + profile if profile else '')
            check(expected in baseline, f'{key}: changed normal Python identity')
        # Sequential runs see a fresh venv even after another run has torn down its
        # interpreter; long-lived volumes deliberately remain poisoned/untouched.
        previous = None
        for n in range(2):
            cid = f'{key}-sequential-{n}'
            child, log, _ = start(profile, cid)
            record = wait_ready(child, log, cid)
            if previous:
                check(record['suffix'] != previous['suffix'], 'sequential identity reused')
            previous = finish(child, log, cid)
        left, left_log, _ = start(profile, key+'-left')
        right, right_log, _ = start(profile, key+'-right')
        l = wait_ready(left, left_log, key+'-left')
        r = wait_ready(right, right_log, key+'-right')
        check(l['suffix'] != r['suffix'], 'concurrent identity reused')
        finish(left, left_log, key+'-left')
        check((state/'containers'/(key+'-right')).exists(), 'cleanup removed another active container')
        for m in r['mounts']:
            if m['target'].endswith('/.venv'):
                venv = state/'volumes'/m['source']
                check((venv/'owner').read_text() == key+'-right', 'another run altered the venv')
                check((venv/'bin/python').exists(), 'another run removed the interpreter')
        finish(right, right_log, key+'-right')
        child, log, _ = start(profile, key+'-failed', fail=True)
        finish(child, log, key+'-failed', expected=2)
        for name in baseline:
            check((state/'volumes'/name/'persistent').read_text() == 'developer state',
                  f'{key}: persistent volume changed')
        for raw in python_mounts:
            normal_name = raw.split(',')[0].removeprefix('source=').replace(
                '${localEnv:HARMON_DEVCONTAINER_SMOKE_VOLUME_SUFFIX}', '')
            check(os.readlink(state/'volumes'/normal_name/'bin/python').endswith('/bin/python3.14'),
                  'smoke run consumed or repaired the stale developer interpreter')
        # Existing credential/config names must preserve their suffix policy.
        for raw, actual in zip([m for m in cfg['mounts'] if 'type=volume' in m], r['mounts']):
            if '/.venv,' not in raw and '${localEnv:HARMON_DEVCONTAINER_SMOKE_VOLUME_SUFFIX}' not in raw:
                check(actual['source'] in baseline, f'{key}: credential/config identity changed')
        print(f'PASS: {key} sequential/concurrent Python state, failure cleanup, normal volumes')


try:
    exercise_profiles()
finally:
    # Only these Popen handles and private release files belong to this fixture.
    # Release foreground assertion loops before reaping their smoke shells;
    # each shell waits for its synchronous child commands before it exits.
    for child, cid in children:
        (state / 'release' / cid).touch()
    for child, _ in children:
        child.wait()

# Real uv, no downloads or dependency resolution: reproduce a dangling Linux
# interpreter link, then isolate the new environment from that prior state.
uv = shutil.which('uv')
check(uv is not None, 'uv is required for the stale-interpreter regression')
stale = work / 'stale-project'
(stale / '.venv/bin').mkdir(parents=True)
(stale / 'pyproject.toml').write_text('[project]\nname="stale-fixture"\nversion="0.0.0"\n')
missing = '/home/vscode/.local/share/uv/python/cpython-3.14-linux-x86_64-gnu/bin/python3.14'
(stale / '.venv/bin/python').symlink_to(missing)
seed_config = 'home = /missing\nversion = 3.14\n'
(stale / '.venv/pyvenv.cfg').write_text(seed_config)
# A real disposable caller distribution makes ambient-env regressions visible
# without ever risking the actual caller's environment.
caller = work / 'caller-environment'
uv_env = dict(os.environ, UV_PROJECT_ENVIRONMENT=str(caller),
              UV_CACHE_DIR=str(work/'uv-cache'),
              UV_PYTHON_INSTALL_DIR=str(work/'uv-python'), UV_PYTHON_DOWNLOADS='never')
run([uv, 'venv', '--offline', '--python', sys.executable, str(caller)], env=uv_env)
site = Path(run([str(caller/'bin/python'), '-c',
                 'import sysconfig; print(sysconfig.get_path("purelib"))']).strip())
check(site.resolve().is_relative_to(caller.resolve()), 'caller fixture escaped its scratch environment')
site.mkdir(parents=True, exist_ok=True)
sentinel = site / 'caller_sentinel.py'
sentinel.write_text('TOKEN = "preserved"\n')
distribution = site / 'caller_sentinel-1.0.dist-info'
distribution.mkdir()
(distribution/'METADATA').write_text('Metadata-Version: 2.1\nName: caller-sentinel\nVersion: 1.0\n')
(distribution/'RECORD').write_text('caller_sentinel.py,,\ncaller_sentinel-1.0.dist-info/METADATA,,\ncaller_sentinel-1.0.dist-info/RECORD,,\n')
fresh = work / 'fresh-environment'
run([uv, 'sync', '--offline', '--no-install-project', '--python', sys.executable],
    cwd=stale, env=dict(uv_env, UV_PROJECT_ENVIRONMENT=str(fresh)))
check((fresh/'bin/python').exists(), 'isolated environment lacks interpreter')
check(os.readlink(stale/'.venv/bin/python') == missing, 'fresh run repaired prior state')
# Deny ordinary-user writes in this scratch directory. Privileged hosts can
# still write, so assert the actual precondition rather than assume EACCES.
stale.chmod(0o555)
permission_denied = not os.access(stale, os.W_OK)
try:
    result = subprocess.run([uv, 'sync', '--offline', '--no-install-project', '--python', sys.executable],
                            cwd=stale, env=dict(uv_env, UV_PROJECT_ENVIRONMENT=str(stale/'.venv')),
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
finally:
    stale.chmod(0o755)
legacy_rejection = (result.returncode > 0
                    and 'not a valid Python environment' in result.stdout
                    and 'no Python executable was found' in result.stdout)
if legacy_rejection:
    check(os.readlink(stale/'.venv/bin/python') == missing
          and (stale/'.venv/pyvenv.cfg').read_text() == seed_config,
          'legacy uv rejection changed the seeded invalid environment')
    print('PASS: dangling environment rejected before recovery (removal/EACCES not reached)')
else:
    check('non-existent Python interpreter' in result.stdout and missing in result.stdout,
          'missing-interpreter warning was not reproduced: '+result.stdout)
    if permission_denied:
        check(result.returncode != 0, 'stale environment unexpectedly recovered in non-writable fixture')
        check('failed to remove' in result.stdout and 'Permission denied' in result.stdout,
              'stale removal permission failure was not reproduced: '+result.stdout)
        print('PASS: real uv dangling interpreter → removal permission error')
    else:
        check(result.returncode == 0 and (stale/'.venv/bin/python').exists(),
              'privileged writable fixture did not recover its stale interpreter: '+result.stdout)
        print('PASS: missing-interpreter warning reproduced; privileged writable fixture recovered (no EACCES claim)')
check(sentinel.read_text() == 'TOKEN = \"preserved\"\n' and (distribution/'METADATA').exists(),
      'uv sync changed the disposable caller environment')
print('PASS: ambient caller environment and sentinel distribution preserved')
PY
