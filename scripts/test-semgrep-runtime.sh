#!/usr/bin/env bash
# Network smoke test of the generated wrapper; kept out of offline verify.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
copier copy --trust --defaults --vcs-ref=HEAD \
    --data project_name="Semgrep Runtime Test" \
    --data github_remote_create=false --data github_release_init=false \
    --data run_task_install=false --data bunch_add=false \
    --data obsidian_project_add=false --data use_skills_sync=false \
    "$repo" "$scratch/consumer"
# A file prevents writes even when the smoke test runs as root.
: >"$scratch/blocked-home"
: >"$scratch/blocked-data"
mkdir -p "$scratch/tmp" "$scratch/cache" "$scratch/tools" "$scratch/semgrep"
printf 'print("semgrep runtime smoke")\n' >"$scratch/consumer/smoke.py"
cd "$scratch/consumer"
printf '3.15\n' >.python-version
# Semgrep's own state paths belong to the separate read-only-home issue #1710.
# Set them explicitly so this regression exercises uv's interpreter directory.
HOME="$scratch/blocked-home" XDG_DATA_HOME="$scratch/blocked-data" \
    UV_CACHE_DIR="$scratch/cache" UV_TOOL_DIR="$scratch/tools" \
    UV_PYTHON_INSTALL_DIR="$scratch/project-python" UV_PYTHON_PREFERENCE=only-managed \
    TMPDIR="$scratch/tmp" \
    SEMGREP_SETTINGS_FILE="$scratch/semgrep/settings.yml" \
    SEMGREP_LOG_FILE="$scratch/semgrep/scan.log" \
    SEMGREP_VERSION_CACHE_PATH="$scratch/semgrep/version-cache" \
    uv run --no-project --python 3.15 python -c '
import os
import sys
assert sys.version_info[:2] == (3, 15), sys.version
print("Project Python:", sys.version, flush=True)
os.environ.pop("UV_PYTHON_INSTALL_DIR")
os.execv(sys.argv[1], sys.argv[1:])
' "$scratch/consumer/scripts/run-semgrep.sh" smoke.py
expected_python="$scratch/tmp/uv-$(id -u)/python"
installed="$(UV_PYTHON_INSTALL_DIR="$expected_python" uv python find --managed-python 3.14)"
case "$installed" in
"$expected_python"/*) ;;
*)
    echo "FAIL: Python 3.14 was not installed in the writable fallback: $installed" >&2
    exit 1
    ;;
esac
"$installed" -c 'import sys; assert sys.version_info[:2] == (3, 14), sys.version'
echo "PASS: generated consumer scans from Python 3.15 with a fresh Python 3.14 fallback"
