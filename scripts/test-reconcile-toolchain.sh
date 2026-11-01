#!/usr/bin/env bash
# Offline fixtures: real setup/session wrapper, stubbed network, and the shared
# checksum installer when developing harmon-init (not shipped in consumers).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

source = Path.cwd()
base_env = os.environ.copy()
for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
             "CLAUDE_CODE_REMOTE", "HARMON_PREFIX", "HARMON_BIN", "HARMON_VERSIONS_FILE",
             "HARMON_CHANGE_LOG", "HARMON_TMPDIR"):
    base_env.pop(name, None)
base_env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
real_timeout = shutil.which("timeout")
real_task = shutil.which("task")
if not real_timeout:
    raise SystemExit("test-reconcile-toolchain needs GNU timeout")
if not real_task:
    raise SystemExit("test-reconcile-toolchain needs task")


def run(args, cwd=source, env=None):
    result = subprocess.run(args, cwd=cwd, env=env or base_env, text=True, capture_output=True, timeout=20)
    return result.returncode, result.stdout + result.stderr


registry = set(subprocess.check_output(["bash", "scripts/reconcile-toolchain.sh", "--list"], text=True).split())


def gate_errors(text):
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    selectors = set(re.findall(r"reconcile-toolchain\.sh[\"']?\s+--check\s+([a-z0-9_-]+)", code))
    errors = selectors - registry
    # Gate version comparisons go through --check, never a private probe/pin
    # reader that per-session preparation would not know exists.
    if re.search(r"\b[\w-]+\s+(?:--version|-version|version)\b|\b[A-Z_]+_VERSION=", code):
        errors.add("direct version check outside registry")
    return errors


selectors = set()
for gate in (source / "scripts").glob("lint-*.sh"):
    text = gate.read_text()
    assert not gate_errors(text), (gate, gate_errors(text))
    selectors.update(re.findall(r"reconcile-toolchain\.sh[\"']?\s+--check\s+([a-z0-9_-]+)", text))
assert selectors == registry, (selectors, registry)
assert gate_errors('bash scripts/reconcile-toolchain.sh --check new-tool') == {"new-tool"}
assert gate_errors('local_version="$(new-tool --version)"')
rc, out = run(["bash", "scripts/reconcile-toolchain.sh", "--check", "new-tool"])
assert rc != 0 and "unregistered" in out, out
print("OK: gate registry coverage rejects unknown tools and private gate probes")

with tempfile.TemporaryDirectory(prefix="reconcile-") as scratch:
    scratch = Path(scratch)
    repo = scratch / "checkout"
    prefix = scratch / "prefix"
    stubs = scratch / "stubs"
    for path in (repo / "scripts", repo / ".github/actions/setup", prefix / "bin", stubs):
        path.mkdir(parents=True)
    for name in ("setup-remote.sh", "session-start-remote.sh", "reconcile-toolchain.sh"):
        shutil.copyfile(source / "scripts" / name, repo / "scripts" / name)
    subprocess.run(["git", "init", "-q", str(repo)], check=True, env=base_env)
    (repo / "Taskfile.yml").write_text('version: "3"\ntasks:\n  setup:remote:\n    cmds:\n      - bash scripts/setup-remote.sh\n')
    (repo / ".github/actions/setup/action.yml").write_text("        SHELLCHECK_VERSION=7.8.9\n")
    cache = prefix / "share/harmon-remote-env"
    assets = repo / "images/devcontainer"
    (assets / "install").mkdir(parents=True)
    (cache / "install").mkdir(parents=True)
    manifest = cache / "manifest.json"
    original_manifest = {"image": {"revision": "v1.2.3"}, "tools": {"shellcheck": "1.2.3"}}
    manifest.write_text(json.dumps(original_manifest))
    log = scratch / "downloads"

    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def old_tool(text="1.2.3", exit_code=0):
        executable(prefix / "bin/shellcheck", f"#!/bin/sh\necho 'version: {text}'\nexit {exit_code}\n")

    binary = b"#!/bin/sh\necho 'version: 7.8.9'\n"
    archive = scratch / "shellcheck.tar.xz"
    with tarfile.open(archive, "w:xz") as tar:
        member = tarfile.TarInfo("shellcheck-v7.8.9/shellcheck")
        member.mode = 0o755
        member.size = len(binary)
        tar.addfile(member, io.BytesIO(binary))
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    pins = f"SHELLCHECK_VERSION=7.8.9\nshellcheck_amd64_sha256={checksum}\nshellcheck_arm64_sha256={checksum}\n"
    (assets / "versions.env").write_text(pins)
    real_install = source / "images/devcontainer/install/install-shellcheck.sh"
    if real_install.exists():
        for name in ("lib.sh", "install-shellcheck.sh"):
            shutil.copyfile(real_install.parent / name, assets / "install" / name)
    else:
        # Consumers do not ship image assets. Model a bootstrap-owned installer
        # contract; harmon-init's root run above exercises the actual installer.
        (assets / "install/lib.sh").write_text("# bootstrap fixture\n")
        (assets / "install/install-shellcheck.sh").write_text('''#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -o "$tmp/archive"
tar -xJf "$tmp/archive" -C "$tmp"
cp "$tmp/shellcheck-v7.8.9/shellcheck" "$HARMON_BIN/shellcheck"
''')
    for path in assets.rglob("*"):
        if path.is_file():
            dest = cache / path.relative_to(assets)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)

    executable(stubs / "curl", '''#!/usr/bin/env bash
echo download >>"$RECONCILE_TEST_LOG"
case "${RECONCILE_TEST_MODE:-}" in
fail) exit 22 ;;
slow) sleep 10; exit 1 ;;
esac
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then cp "$RECONCILE_TEST_ARCHIVE" "$2"; exit; fi
    shift
done
exit 2
''')
    # Exercise a real timeout in milliseconds without a 30-second test delay.
    executable(stubs / "timeout", f'''#!/usr/bin/env bash
if [ "${{RECONCILE_TEST_MODE:-}}" = slow ] && [ "${{2:-}}" = 30s ]; then
    shift 2
    exec {real_timeout} --kill-after=0.5s 3s "$@"
fi
if [ "${{RECONCILE_TEST_MODE:-}}" = outer ] && [ "${{2:-}}" = 90s ]; then exit 124; fi
exec {real_timeout} "$@"
''')
    executable(stubs / "task", f'''#!/usr/bin/env bash
if [ "${{RECONCILE_TEST_MODE:-}}" = setup-failure ]; then exit 7; fi
exec {shlex.quote(real_task)} "$@"
''')
    env = base_env | {"CLAUDE_CODE_REMOTE": "true", "HARMON_PREFIX": str(prefix),
                      "PATH": f"{prefix / 'bin'}:{stubs}:{base_env['PATH']}",
                      "RECONCILE_TEST_LOG": str(log), "RECONCILE_TEST_ARCHIVE": str(archive),
                      "TMPDIR": str(scratch)}

    def setup(mode="", remote=True):
        log.unlink(missing_ok=True)
        current_env = env | {"RECONCILE_TEST_MODE": mode}
        if not remote:
            current_env.pop("CLAUDE_CODE_REMOTE")
        rc, output = run(["task", "--silent", "setup:remote"], repo, current_env)
        assert rc == 0, output
        return output

    def drift_warning(output, reason):
        line = next(line for line in output.splitlines() if line.startswith("==> setup:remote completed with warnings:"))
        for value in ("shellcheck", "installed 1.2.3", "checkout pin 7.8.9", "environment v1.2.3",
                      "HARMON_INIT_REF", "release carrying shellcheck 7.8.9", reason):
            assert value in line, (value, output)
        assert "latest release" not in line, output

    old_tool()
    out = setup()
    assert "Reconciled shellcheck 1.2.3 -> 7.8.9" in out and "completed with warnings" not in out, out
    assert (prefix / "bin/shellcheck").read_bytes() == binary
    assert log.exists()
    out = setup()
    assert not log.exists() and "WARNING" not in out and "Reconciled" not in out, out
    print("OK: task setup:remote installs the checkout pin and matching versions do not install/warn")

    missing_tmp = scratch / "missing-tmpdir"
    assert not missing_tmp.exists()
    bad_tmp_env = env | {"TMPDIR": str(missing_tmp)}
    rc, out = run(["bash", "scripts/reconcile-toolchain.sh", "--check", "shellcheck"], repo, bad_tmp_env)
    assert rc == 0 and not out, out
    print("OK: --check at the pinned version succeeds with a missing TMPDIR")
    for args in (["--status"], []):
        rc, out = run(["bash", "scripts/reconcile-toolchain.sh", *args], repo, bad_tmp_env)
        assert rc == 0 and "WARNING: shellcheck version probe: mktemp failed" in out, out
        assert str(missing_tmp) in out and "installed unknown" not in out and "checkout pin" not in out, out
        assert not log.exists(), out
    print("OK: bounded probe allocation failure reports mktemp/TMPDIR rather than unknown version drift")

    for mode, reason in (("fail", "installer failed"), ("slow", "time budget exhausted")):
        old_tool()
        before = (prefix / "bin/shellcheck").read_bytes()
        out = setup(mode)
        drift_warning(out, reason)
        assert log.exists() and (prefix / "bin/shellcheck").read_bytes() == before, (mode, log.exists(), out)
    print("OK: failed downloads and exhausted install budgets warn with all required fields, exit 0, preserve old tool")

    old_tool()
    out = setup(remote=False)
    assert not log.exists() and "shellcheck" not in out and "WARNING" not in out, out
    assert "1.2.3" in (prefix / "bin/shellcheck").read_text()
    print("OK: local preparation does not reconcile")

    # The generated-repository path has no images/, so uses persisted assets.
    shutil.rmtree(repo / "images")
    out = setup()
    assert "Reconciled shellcheck" in out and log.exists(), out
    old_tool()
    rc, out = run(["bash", "scripts/session-start-remote.sh"], repo, env)
    assert rc == 0, out
    line = next(line for line in out.splitlines() if "SessionStart remote preparation:" in line)
    assert "Reconciled shellcheck 1.2.3 -> 7.8.9" in line, out
    old_tool()
    installer = cache / "install/install-shellcheck.sh"
    installer.rename(installer.with_suffix(".saved"))
    out = setup()
    drift_warning(out, "shared installer unavailable")
    assert not log.exists(), out
    installer.with_suffix(".saved").rename(installer)
    executable(stubs / "shellcheck", "#!/bin/sh\necho 'version: 1.2.3'\n")
    log.unlink(missing_ok=True)
    rc, out = run(["task", "--silent", "setup:remote"], repo,
                  env | {"PATH": f"{stubs}:{prefix / 'bin'}:{base_env['PATH']}"})
    assert rc == 0 and not log.exists(), out
    drift_warning(out, "must be writable and precede")
    (stubs / "shellcheck").unlink()
    print("OK: successful SessionStart names the repair; missing installers and shadowed prefixes warn without installing")
    old_tool()
    cached_pins = cache / "versions.env"
    cached_pins.write_text(pins.replace("7.8.9", "7.8.8"))
    out = setup()
    drift_warning(out, "checksum metadata")
    assert not log.exists(), out
    cached_pins.write_text(pins)
    if real_install.exists():
        cached_pins.write_text(pins.replace(checksum, "0" * 64))
        out = setup()
        drift_warning(out, "installer failed")
        assert "checksum mismatch" in out and "1.2.3" in (prefix / "bin/shellcheck").read_text(), out
        cached_pins.write_text(pins)
    print("OK: generated checkouts reuse cached assets; missing checksum coverage cannot install")
    if real_install.exists():
        print("OK: a bad digest rejects the archive before replacing the existing tool")

    # The environment release number is deliberately unrelated to the tool's
    # version. Numeric tuple comparison must recognize 7.8.10 > 7.8.9.
    old_tool("7.8.10")
    cached_pins.write_text(pins.replace("7.8.9", "7.8.10"))
    manifest.write_text(json.dumps({"image": {"revision": "v1.2.3"}, "tools": {"shellcheck": "7.8.10"}}))
    out = setup()
    assert not log.exists(), out
    line = next(line for line in out.splitlines() if line.startswith("==> setup:remote completed with warnings:"))
    for value in ("installed 7.8.10", "checkout pin 7.8.9", "environment v1.2.3",
                  "update the repository's shellcheck pin", "7.8.10", "copier update"):
        assert value in line, (value, out)
    assert "HARMON_INIT_REF" not in line and "latest release" not in line, out
    manifest.write_text(json.dumps(original_manifest))
    cached_pins.write_text(pins)
    old_tool()
    print("OK: a newer recorded tool pin advises a repository update instead of the latest environment release")

    for mode in ("outer", "setup-failure"):
        rc, out = run(["bash", "scripts/session-start-remote.sh"], repo, env | {"RECONCILE_TEST_MODE": mode})
        assert rc == 0, out
        line = next(line for line in out.splitlines() if "SessionStart remote preparation:" in line)
        for value in ("shellcheck", "installed 1.2.3", "checkout pin 7.8.9", "environment v1.2.3", "HARMON_INIT_REF",
                      "preparation left this tool unreconciled"):
            assert value in line, (mode, value, out)
        assert "within its time budget" not in line, out
    print("OK: outer timeout and ordinary preparation failure report drift without inventing a timeout cause")

    # This child escapes timeout's process group and retains stdout for 8s
    # after the version command exits. A pipe capture used to wait for it.
    executable(prefix / "bin/shellcheck", f'''#!/usr/bin/env bash
exec {shlex.quote(sys.executable)} - <<'PYPROBE'
import subprocess
import sys
subprocess.Popen([sys.executable, "-c", "import time; time.sleep(8)"],
                 start_new_session=True, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("version: 1.2.3", flush=True)
PYPROBE
''')
    for args, mode in ((["bash", "scripts/reconcile-toolchain.sh", "--status"], ""),
                       (["bash", "scripts/session-start-remote.sh"], "outer")):
        started = time.monotonic()
        rc, out = run(args, repo, env | {"RECONCILE_TEST_MODE": mode})
        elapsed = time.monotonic() - started
        assert rc == 0 and "installed 1.2.3" in out, out
        # The actual probe budget is 2s + 1s kill grace; allow 0.5s for the
        # wrapper/metadata probes. Waiting for the 8s child fails decisively.
        assert elapsed < 3.5, (args, elapsed, out)
        print(f"OK: stdout-holding descendant cannot extend {args[1]} beyond the probe budget ({elapsed:.2f}s)")

print("reconcile-toolchain OK")
PY
