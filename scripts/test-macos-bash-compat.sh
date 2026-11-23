#!/usr/bin/env bash
# test-macos-bash-compat.sh — hermetic unit tests for verify-macos-bash-compat.sh.
#
# Runs inside test:suite on both Linux (Bash 5) and macOS (Bash 3.2) without
# recursing into test:suite: stub interpreters and a stub task binary prove
# version gating, shim precedence, hostile-PATH preservation, the shell-eval
# tripwire, and the default target sequence; on macOS hosts with /bin/bash 3.2,
# a live smoke assertion exercises the real interpreter too.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="${repo_root}/scripts/verify-macos-bash-compat.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -x "$verifier" ] || fail "verifier is missing or not executable: ${verifier}"

real_bash="$(command -v bash)"
work_raw="$(mktemp -d "${TMPDIR:-/tmp}/test-macos-bash-compat.XXXXXX")"
work=""
cleanup() {
    rm -rf "${work:-$work_raw}"
}
trap cleanup EXIT
work="$(cd "$work_raw" && pwd -P)"

# ── Stub interpreters ────────────────────────────────────────────────
stubs="${work}/stubs"
competing_bin="${work}/competing-homebrew-bin"
stub_task_bin="${work}/stub-task-bin"
mkdir -p "$stubs" "$competing_bin" "$stub_task_bin"

cat >"${stubs}/bash-3.2" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-c" ] && [ "\${2:-}" = 'printf "%s" "\${BASH_VERSION:-}"' ]; then
    printf '3.2.57(1)-release'
    exit 0
fi
export FAKE_APPLE_BASH_SHIM_RAN=1
exec "${real_bash}" "\$@"
EOF
chmod +x "${stubs}/bash-3.2"

cat >"${stubs}/bash-5.2" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-c" ] && [ "${2:-}" = 'printf "%s" "${BASH_VERSION:-}"' ]; then
    printf '5.2.37(1)-release'
    exit 0
fi
exit 98
EOF
chmod +x "${stubs}/bash-5.2"

: >"${stubs}/nonexec-bash"
chmod 0644 "${stubs}/nonexec-bash"
mkdir -p "${stubs}/dir-bash"

# Competing modern bash earlier on incoming PATH (like /opt/homebrew/bin/bash
# on a developer Mac or macos-26 runner) — verify-macos-bash-compat.sh itself
# launches under it via #!/usr/bin/env bash, then must shadow it with shim_dir
# for both its own `hash -r` check and every child script it invokes.
cat >"${competing_bin}/bash" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-c" ] && [ "\${2:-}" = 'printf "%s" "\${BASH_VERSION:-}"' ]; then
    printf '5.2.37(1)-release'
    exit 0
fi
export FAKE_APPLE_BASH_SHIM_RAN=0
export COMPETING_MODERN_BASH_RAN=1
exec "${real_bash}" "\$@"
EOF
chmod +x "${competing_bin}/bash"

# ── 1. Missing, non-executable, directory, and non-3.2 interpreters fail ──
never_ran="${work}/never-ran"
for bad_bash in "${work}/no-such-bash" "${stubs}/nonexec-bash" "${stubs}/dir-bash"; do
    out="$(MACOS_BASH_COMPAT_APPLE_BASH="$bad_bash" "$verifier" sh -c ': >"$1"' _ "$never_ran" 2>&1)" && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "accepted unusable interpreter: ${bad_bash}"
    [ ! -e "$never_ran" ] || fail "command ran despite unusable interpreter: ${bad_bash}"
    grep -Fq "Apple Bash 3.2 executable not found" <<<"$out" ||
        fail "unexpected error for '${bad_bash}': ${out}"
done

out="$(MACOS_BASH_COMPAT_APPLE_BASH="${stubs}/bash-5.2" "$verifier" sh -c ': >"$1"' _ "$never_ran" 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "accepted Bash 5.2 interpreter"
[ ! -e "$never_ran" ] || fail "command ran under rejected Bash 5.2 interpreter"
grep -Fq "5.2.37(1)-release" <<<"$out" || fail "version mismatch diagnostic omitted reported version: ${out}"
grep -Fq "expected 3.2.*" <<<"$out" || fail "version mismatch diagnostic omitted 3.2.* expectation: ${out}"

# ── 2. Shim wins PATH over competing bash and preserves hostile PATH literally ──
probe_script="${work}/probe-child.sh"
probe_report="${work}/probe-report.txt"
cat >"$probe_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'SHIM_RAN=%s\n' "${FAKE_APPLE_BASH_SHIM_RAN:-0}"
    printf 'RESOLVED_BASH=%s\n' "$(command -v bash)"
    printf 'FIRST_ENTRY=%s\n' "${PATH%%:*}"
    rest="${PATH#*:}"
    printf 'SECOND_ENTRY=%s\n' "${rest%%:*}"
    printf 'FULL_PATH=%s\n' "$PATH"
} >"$1"
EOF
chmod +x "$probe_script"

incoming_tail="${work}/tail-entry"
mkdir -p "$incoming_tail"
PATH="${competing_bin}:${PATH}:${incoming_tail}" \
    MACOS_BASH_COMPAT_APPLE_BASH="${stubs}/bash-3.2" \
    "$verifier" "$probe_script" "$probe_report"

grep -Fxq 'SHIM_RAN=1' "$probe_report" ||
    fail "env bash shebang did not execute through the Apple Bash 3.2 shim: $(cat "$probe_report")"
first_entry="$(sed -n 's/^FIRST_ENTRY=//p' "$probe_report")"
resolved_entry="$(sed -n 's/^RESOLVED_BASH=//p' "$probe_report")"
second_entry="$(sed -n 's/^SECOND_ENTRY=//p' "$probe_report")"
full_path="$(sed -n 's/^FULL_PATH=//p' "$probe_report")"

case "$first_entry" in
*"/Apple Bash 3.2 bin") ;;
*) fail "first PATH entry is not the spaced shim directory: ${first_entry}" ;;
esac
[ "$resolved_entry" = "${first_entry}/bash" ] ||
    fail "bash resolved to '${resolved_entry}', expected '${first_entry}/bash'"
expected_hostile_suffix='/PATH with spaces & sed|shell $foo ; __harmon_path_reinterpreted_tripwire__ ;'
case "$second_entry" in
*"${expected_hostile_suffix}") ;;
*) fail "second PATH entry lost hostile spaces/sed/shell metacharacters: ${second_entry}" ;;
esac
case "$full_path" in
*":${competing_bin}:"*":${incoming_tail}") ;;
*) fail "incoming PATH entries were not preserved behind the shim: ${full_path}" ;;
esac

# ── 3. Command failure propagates its exact non-zero status ──────────
MACOS_BASH_COMPAT_APPLE_BASH="${stubs}/bash-3.2" \
    "$verifier" sh -c 'exit 23' && rc=0 || rc=$?
[ "$rc" -eq 23 ] || fail "expected exit status 23 to propagate, got ${rc}"

# ── 4. Unquoted shell reinterpretation of PATH trips the sentinel and fails closed ──
# Even if the buggy child exits 0, unquoted evaluation of PATH executes the
# `;__harmon_path_reinterpreted_tripwire__` segment, creating
# MACOS_BASH_COMPAT_SENTINEL so run_checked fails closed.
out="$(MACOS_BASH_COMPAT_APPLE_BASH="${stubs}/bash-3.2" \
    "$verifier" sh -c 'eval "PATH=$PATH" </dev/null >/dev/null 2>&1 || true; exit 0' 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "PATH shell-reinterpretation was not caught by tripwire"
grep -Fq "PATH was reinterpreted as shell syntax" <<<"$out" ||
    fail "tripwire failure did not explain PATH reinterpretation: ${out}"

# ── 5. Zero-arg invocation runs the exact four Task targets in order ──
task_calls="${work}/task-calls.txt"
cat >"${stub_task_bin}/task" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAKE_APPLE_BASH_SHIM_RAN:-0}" = "1" ] || {
    echo "stub task did not run under shimmed bash" >&2
    exit 91
}
printf '%s\n' "$*" >>"${TEST_TASK_CALLS:?}"
EOF
chmod +x "${stub_task_bin}/task"

TEST_TASK_CALLS="$task_calls" \
    PATH="${stub_task_bin}:${competing_bin}:${PATH}" \
    MACOS_BASH_COMPAT_APPLE_BASH="${stubs}/bash-3.2" \
    "$verifier" >/dev/null

expected_calls="${work}/expected-calls.txt"
cat >"$expected_calls" <<'EOF'
lint:shell
test:suite
test:ci-results
test:agent-profile
EOF
diff -u "$expected_calls" "$task_calls" ||
    fail "default zero-argument target list drifted"

# ── 6. Live /bin/bash 3.2 smoke on macOS hosts ───────────────────────
if [ -x /bin/bash ]; then
    host_apple_ver="$(/bin/bash -c 'printf "%s" "${BASH_VERSION:-}"' 2>/dev/null || true)"
    case "$host_apple_ver" in
    3.2.*)
        PATH="${competing_bin}:${PATH}" "$verifier" \
            bash -c 'case "${BASH_VERSION:-}" in 3.2.*) ;; *) exit 1 ;; esac'
        ;;
    esac
fi

# ── 7. BSD /sbin/sha256sum explicit-stdin `-` regression (macos-26) ──
# macOS 26 ships BSD /sbin/sha256sum, which rejects `sha256sum --check --status`
# with no file operand ("usage: sha256sum [-bctwz] [files ...]"). Verify
# harmon_verify_sha256 passes `-` explicitly to both sha256sum and shasum.
install_lib="${repo_root}/images/devcontainer/install/lib.sh"
if [ -f "$install_lib" ]; then
    bsd_sha_bin="${work}/bsd-sha-bin"
    shasum_only_bin="${work}/shasum-only-bin"
    mkdir -p "$bsd_sha_bin" "$shasum_only_bin"
    for tool in dirname printf; do
        tool_path="$(command -v "$tool" 2>/dev/null || true)"
        [ -z "$tool_path" ] || ln -s "$tool_path" "${bsd_sha_bin}/${tool}"
        [ -z "$tool_path" ] || ln -s "$tool_path" "${shasum_only_bin}/${tool}"
    done
    python3_bin="$(command -v python3)"
    payload="${work}/payload.bin"
    printf 'macos-26-bsd-sha256sum\n' >"$payload"
    payload_sha="$("$python3_bin" -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$payload")"

    cat >"${bsd_sha_bin}/sha256sum" <<EOF
#!${python3_bin}
import hashlib, pathlib, sys
if sys.argv[1:] != ["--check", "--status", "-"]:
    sys.stderr.write("usage: sha256sum [-bctwz] [files ...]\\n")
    raise SystemExit(1)
expected, path = sys.stdin.read().rstrip("\\n").split("  ", 1)
actual = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
raise SystemExit(0 if actual == expected else 1)
EOF
    chmod +x "${bsd_sha_bin}/sha256sum"

    cat >"${shasum_only_bin}/shasum" <<EOF
#!${python3_bin}
import hashlib, pathlib, sys
if sys.argv[1:] != ["-a", "256", "--check", "--status", "-"]:
    sys.stderr.write("unexpected shasum argv: " + repr(sys.argv[1:]) + "\\n")
    raise SystemExit(1)
expected, path = sys.stdin.read().rstrip("\\n").split("  ", 1)
actual = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
raise SystemExit(0 if actual == expected else 1)
EOF
    chmod +x "${shasum_only_bin}/shasum"

    PATH="$bsd_sha_bin" "$real_bash" -euo pipefail -c \
        '. "$1"; harmon_verify_sha256 "$2" "$3"' _ "$install_lib" "$payload" "$payload_sha" ||
        fail "harmon_verify_sha256 failed under BSD-strict sha256sum requiring '-'"
    if PATH="$bsd_sha_bin" "$real_bash" -euo pipefail -c \
        '. "$1"; harmon_verify_sha256 "$2" "$3"' _ "$install_lib" "$payload" "0000000000000000000000000000000000000000000000000000000000000000" 2>/dev/null; then
        fail "harmon_verify_sha256 accepted a mismatched digest under BSD-strict sha256sum"
    fi

    PATH="$shasum_only_bin" "$real_bash" -euo pipefail -c \
        '. "$1"; harmon_verify_sha256 "$2" "$3"' _ "$install_lib" "$payload" "$payload_sha" ||
        fail "harmon_verify_sha256 failed under strict shasum requiring '-'"
    if PATH="$shasum_only_bin" "$real_bash" -euo pipefail -c \
        '. "$1"; harmon_verify_sha256 "$2" "$3"' _ "$install_lib" "$payload" "0000000000000000000000000000000000000000000000000000000000000000" 2>/dev/null; then
        fail "harmon_verify_sha256 accepted a mismatched digest under strict shasum"
    fi
fi

echo "test-macos-bash-compat: PASS"
