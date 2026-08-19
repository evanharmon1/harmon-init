#!/usr/bin/env bash
# Hermetic unit tests for test-template.sh's quiet-command capture helpers
# (harmon-init#934).
#
# Why this suite exists at all. `run_quiet` replaced seven bare
# `>/dev/null 2>&1 || err "..."` call sites, so every one of those rendered-repo
# gates now reaches `err` only if run_quiet propagates a nonzero status. A
# run_quiet that returned 0 unconditionally would not fail loudly — it would
# turn all seven gates into silent no-ops while `task verify` stayed green. The
# exit-status case below is therefore the load-bearing one, and the call-site
# case guards the wiring those gates depend on.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
subject="${repo}/scripts/test-template.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

job_tmp="$(mktemp -d -t harmon-init-tth-XXXXXX)"
trap 'rm -rf "$job_tmp"' EXIT

# Bind to the REAL helpers rather than a copy: extract them from the subject and
# source them, so this suite cannot pass against a run_quiet that no longer
# matches the one test-template.sh actually calls.
helpers="$job_tmp/helpers.sh"
sed -n '/^dump_log() {/,/^}/p;/^run_quiet() {/,/^}/p' "$subject" >"$helpers"

# Negative control on the extraction itself. A sed that silently matched
# nothing would make every assertion below vacuously true — the #889 class of
# defect, and the reason this is asserted rather than assumed.
grep -q '^dump_log() {' "$helpers" || fail "extraction found no dump_log() in ${subject}"
grep -q '^run_quiet() {' "$helpers" || fail "extraction found no run_quiet() in ${subject}"

# shellcheck source=/dev/null
. "$helpers"

# ── The success path must be exactly as quiet as the >/dev/null it replaced ──

noise="$(run_quiet quiet_ok sh -c 'echo to_stdout; echo to_stderr >&2; exit 0' 2>&1)"
[ -z "$noise" ] || fail "run_quiet leaked output on the success path: ${noise}"

status=0
run_quiet status_ok true || status=$?
[ "$status" -eq 0 ] || fail "run_quiet returned ${status} for a command that succeeded"

# ── The failure path must replay BOTH streams ────────────────────────────────

status=0
replay="$(run_quiet loud_fail sh -c 'echo marker_out; echo marker_err >&2; exit 1' 2>&1)" || status=$?
case "$replay" in
*marker_out*) : ;;
*) fail "run_quiet lost the failing command's stdout" ;;
esac
case "$replay" in
*marker_err*) : ;;
*) fail "run_quiet lost the failing command's stderr" ;;
esac
case "$replay" in
*"----- end: loud_fail -----"*) : ;;
*) fail "run_quiet omitted the closing boundary that delimits captured output" ;;
esac

# ── Exit-status propagation: the case seven gates depend on ──────────────────
#
# Asserted across several distinct nonzero values, not just one, so a helper
# that collapsed every failure to a constant would still be caught.
for expected in 1 3 7 42; do
    status=0
    run_quiet "status_${expected}" sh -c "exit ${expected}" >/dev/null 2>&1 || status=$?
    [ "$status" -eq "$expected" ] ||
        fail "run_quiet reported ${status} for a command that exited ${expected} — the '|| err' call sites would not fire"
done

# ── --in <dir> runs elsewhere without moving the caller ──────────────────────

mkdir -p "$job_tmp/elsewhere"
before="$PWD"
run_quiet --in "$job_tmp/elsewhere" chdir_probe pwd >/dev/null 2>&1 ||
    fail "run_quiet --in failed on a directory that exists"
grep -qF "elsewhere" "$job_tmp/chdir_probe.log" ||
    fail "run_quiet --in did not run the command in the requested directory"
[ "$PWD" = "$before" ] ||
    fail "run_quiet --in moved the caller's working directory to ${PWD}"

# A directory that does not exist must fail rather than silently running in the
# caller's cwd, where the command could pass against the wrong tree.
status=0
run_quiet --in "$job_tmp/no-such-dir" absent_dir true >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "run_quiet --in succeeded against a directory that does not exist"

# ── dump_log replays a log captured by something other than run_quiet ────────
#
# The worktree:new call site captures by hand (its failure is legitimate on a
# profile with no commit) and replays only on the branch that treats it as an
# error, so dump_log must work standalone.
printf 'standalone_marker\n' >"$job_tmp/manual.log"
replay="$(dump_log manual 2>&1)"
case "$replay" in
*standalone_marker*) : ;;
*) fail "dump_log did not replay a hand-captured log" ;;
esac

# ── The call sites are actually wired to the helper ──────────────────────────
#
# Guards the regression this change exists to prevent: a gate reverted to a bare
# discard fails silently and undiagnosably, which is exactly what #934 reported.
if grep -nE 'task --color=false [a-z:-]+ >/dev/null 2>&1' "$subject"; then
    fail "a rendered-repo task gate above still discards its output instead of using run_quiet"
fi
if grep -nF 'test:worktree >/dev/null 2>&1' "$subject"; then
    fail "the test:worktree gate still discards its output (the original #934 report)"
fi

wired="$(grep -c 'run_quiet ' "$subject" || true)"
[ "$wired" -ge 6 ] ||
    fail "expected at least 6 run_quiet call sites in ${subject}, found ${wired}"

echo "test-template.sh capture helpers: PASS"
