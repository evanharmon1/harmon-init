#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pnpm-install-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runner" "$tmp/project"
cat >"$tmp/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PNPM_CONFIG_STORE_DIR" >> "$CALLS"
case "$SCENARIO:$(wc -l < "$CALLS" | tr -d ' ')" in
    success:1) exit 0 ;;
    malformed:1|retry-fails:1) echo '[ERR_PNPM_ERR_SQLITE_ERROR] database disk image is malformed' >&2; exit 7 ;;
    direct:1) echo '[ERR_SQLITE_ERROR] database disk image is malformed' >&2; exit 7 ;;
    malformed:2 | direct:2) exit 0 ;;
    retry-fails:2) echo 'retry failed' >&2; exit 23 ;;
    unrelated:1) echo 'lockfile mismatch' >&2; exit 9 ;;
    sqlite-other:1) echo '[ERR_PNPM_ERR_SQLITE_ERROR] database is locked' >&2; exit 8 ;;
    *) exit 99 ;;
esac
STUB
chmod +x "$tmp/bin/pnpm"
export PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp/runner" CALLS="$tmp/calls" GITHUB_ENV="$tmp/env" GITHUB_STEP_SUMMARY="$tmp/summary"
export PNPM_CONFIG_STORE_DIR="$RUNNER_TEMP/.pnpm-store" npm_config_store_dir="$RUNNER_TEMP/.pnpm-store"
run_case() {
    local scenario="$1" expected="$2" calls="$3" rc=0
    : >"$CALLS"
    : >"$GITHUB_ENV"
    : >"$GITHUB_STEP_SUMMARY"
    SCENARIO="$scenario" "$root/scripts/pnpm-install.sh" >"$tmp/output" 2>&1 || rc=$?
    [ "$rc" -eq "$expected" ] || {
        echo "$scenario: exit $rc, expected $expected" >&2
        exit 1
    }
    [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq "$calls" ] || {
        echo "$scenario: wrong call count" >&2
        exit 1
    }
    [ "$(head -n 1 "$CALLS")" = "$RUNNER_TEMP/.pnpm-store" ]
    if [ "$calls" -eq 2 ]; then
        fresh="$(tail -n 1 "$CALLS")"
        case "$fresh" in "$RUNNER_TEMP"/pnpm-recovery.*) ;; *) exit 1 ;; esac
        [ -d "$fresh" ]
        grep -q 'database disk image is malformed' "$tmp/output"
        grep -qi 'dependency setup' "$GITHUB_STEP_SUMMARY"
        if [ "$expected" -eq 0 ]; then grep -Fq "$fresh" "$GITHUB_ENV"; fi
    elif [ "$expected" -ne 0 ]; then
        grep -qi 'dependency setup' "$GITHUB_STEP_SUMMARY"
        [ ! -s "$GITHUB_ENV" ]
    fi
}
cd "$tmp/project"
touch package.json
run_case success 0 1
run_case malformed 0 2
run_case direct 0 2
run_case unrelated 9 1
run_case sqlite-other 8 1
run_case retry-fails 23 2
echo 'pnpm install recovery tests passed'
