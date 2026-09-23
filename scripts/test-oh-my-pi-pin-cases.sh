#!/usr/bin/env bash
# Behavioural fixtures for scripts/test-oh-my-pi-pin.sh: each case builds a
# throwaway repo with a fixture images/devcontainer/Dockerfile on a `base`
# branch, applies a change on a `work` branch, and asserts the guard's
# verdict, message, and speed.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
guard="${repo_root}/scripts/test-oh-my-pi-pin.sh"

tmp="$(mktemp -d -t harmon-init-oh-my-pi-pin-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

OLD_AMD=0000000000000000000000000000000000000000000000000000000000000000
OLD_ARM=1111111111111111111111111111111111111111111111111111111111111111
NEW_AMD=2222222222222222222222222222222222222222222222222222222222222222
NEW_ARM=3333333333333333333333333333333333333333333333333333333333333333

# write_dockerfile <version> <marker mode> <amd64 hash> <arm64 hash>
# marker mode is a verified-for value, or one of:
#   omit-marker   — no verified-for line; the explanatory comment sits directly above the hash instead
#   wrong-comment — an unrelated comment sits directly above the hash instead
write_dockerfile() {
    mkdir -p images/devcontainer
    {
        echo "FROM scratch"
        echo "# renovate: datasource=github-releases depName=can1357/oh-my-pi extractVersion=^v?(?<version>.+)\$"
        echo "ARG OH_MY_PI_VERSION=$1"
        echo "# oh-my-pi ships unsigned release binaries: verify a bump by hand before moving this marker."
        case "$2" in
        omit-marker) : ;; # the comment above is the last line before the hash
        wrong-comment) echo "# some unrelated comment" ;;
        *) echo "# verified-for: $2" ;;
        esac
        echo "ARG OH_MY_PI_SHA256_AMD64=$3"
        echo "ARG OH_MY_PI_SHA256_ARM64=$4"
    } >images/devcontainer/Dockerfile
}

# new_repo <name>: a repo whose `base` branch pins 18.2.6 (both hashes OLD_*,
# marker matching), checked out on a `work` branch ready for the case's change.
new_repo() {
    local dir="${tmp}/$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q .
    git config user.email test@example.com
    git config user.name Test
    git config maintenance.auto false
    git config gc.auto 0
    git checkout -q -b base
    write_dockerfile 18.2.6 18.2.6 "$OLD_AMD" "$OLD_ARM"
    git add -A
    git commit -qm base
    git checkout -q -b work
}

# run_guard: runs the guard in the current repo, capturing status and output.
# GITHUB_BASE_REF is cleared unless a case sets it: this suite runs inside
# harmon-init's own pull-request CI, where the real value would point the
# fixture repos at an origin they do not have.
run_guard() {
    status=0
    output="$(OH_MY_PI_PIN_BASE="${OH_MY_PI_PIN_BASE-base}" GITHUB_BASE_REF="${CASE_GITHUB_BASE_REF:-}" "$guard" 2>&1)" || status=$?
}

expect_fail() {
    [ "$status" -ne 0 ] || fail "$1: guard passed; output: ${output}"
}

expect_pass() {
    [ "$status" -eq 0 ] || fail "$1: guard failed; output: ${output}"
}

expect_output() {
    case "$output" in
    *"$2"*) : ;;
    *) fail "$1: output lacks '$2'; output: ${output}" ;;
    esac
}

echo "==> unchanged pins on a branch -> passes"
new_repo unchanged
run_guard
expect_pass unchanged
expect_output unchanged "unchanged since base"

echo "==> version, marker, and both hashes moved together -> passes"
new_repo matched
write_dockerfile 18.3.0 18.3.0 "$NEW_AMD" "$NEW_ARM"
git commit -qam "matched bump"
start="$(date +%s)"
run_guard
elapsed=$(($(date +%s) - start))
expect_pass matched
expect_output matched "moved together"
[ "$elapsed" -lt 5 ] || fail "matched: guard took ${elapsed}s (budget: under 5s)"

echo "==> OH_MY_PI_VERSION bumped past the verified-for marker -> fails fast, names the manual procedure"
new_repo mismatch
write_dockerfile 18.3.0 18.2.6 "$OLD_AMD" "$OLD_ARM"
start="$(date +%s)"
run_guard
elapsed=$(($(date +%s) - start))
expect_fail mismatch
expect_output mismatch "18.3.0"
expect_output mismatch "18.2.6"
expect_output mismatch "Read the release notes and provenance"
expect_output mismatch "sha256sum each binary asset (not the source archives)"
expect_output mismatch "https://github.com/can1357/oh-my-pi/releases/download/v18.3.0/omp-linux-x64"
expect_output mismatch "https://github.com/can1357/oh-my-pi/releases/download/v18.3.0/omp-linux-arm64"
[ "$elapsed" -lt 5 ] || fail "mismatch: guard took ${elapsed}s (budget: under 5s)"

echo "==> marker moved to match the bumped version, but BOTH hashes left stale -> fails, names both"
new_repo marker-only
write_dockerfile 18.3.0 18.3.0 "$OLD_AMD" "$OLD_ARM"
git commit -qam "moved marker without re-verifying either hash"
start="$(date +%s)"
run_guard
elapsed=$(($(date +%s) - start))
expect_fail marker-only
expect_output marker-only "OH_MY_PI_VERSION changed 18.2.6 -> 18.3.0"
expect_output marker-only "OH_MY_PI_SHA256_AMD64,OH_MY_PI_SHA256_ARM64 did not move"
expect_output marker-only "without re-verifying the hash"
[ "$elapsed" -lt 5 ] || fail "marker-only: guard took ${elapsed}s (budget: under 5s)"

echo "==> marker moved to match the bumped version, only the arm64 hash left stale -> fails, names only that one"
new_repo one-stale
write_dockerfile 18.3.0 18.3.0 "$NEW_AMD" "$OLD_ARM"
git commit -qam "arm64 hash forgotten"
run_guard
expect_fail one-stale
expect_output one-stale "OH_MY_PI_SHA256_ARM64 did not move"
case "$output" in
*"OH_MY_PI_SHA256_AMD64 did not move"*) fail "one-stale: amd64 wrongly reported stale; output: ${output}" ;;
esac

echo "==> the stale state is caught before it is committed (working tree vs merge-base)"
new_repo uncommitted
write_dockerfile 18.3.0 18.3.0 "$OLD_AMD" "$OLD_ARM"
run_guard
expect_fail uncommitted

echo "==> no verified-for marker at all -> fails, says so"
new_repo no-marker
write_dockerfile 18.2.6 omit-marker "$OLD_AMD" "$OLD_ARM"
git commit -qam "drop marker"
run_guard
expect_fail no-marker
expect_output no-marker "no '# verified-for:"

echo "==> a different comment sits where the marker belongs -> fails"
new_repo wrong-line
write_dockerfile 18.2.6 wrong-comment "$OLD_AMD" "$OLD_ARM"
git commit -qam "wrong comment"
run_guard
expect_fail wrong-line
expect_output wrong-line "no '# verified-for:"

echo "==> no OH_MY_PI_VERSION line at all -> fails"
new_repo no-version
mkdir -p images/devcontainer
echo "FROM scratch" >images/devcontainer/Dockerfile
git add -A && git commit -qm "no version"
run_guard
expect_fail no-version
expect_output no-version "could not find"

echo "==> no merge-base (no remote, no OH_MY_PI_PIN_BASE) -> drift check skipped, passes with a notice"
new_repo no-base
write_dockerfile 18.3.0 18.3.0 "$OLD_AMD" "$OLD_ARM"
git commit -qam "bump, no base to diff against"
OH_MY_PI_PIN_BASE='' run_guard
expect_pass no-base
expect_output no-base "drift check skipped"

echo "==> a pull request with no merge-base (shallow checkout) -> fails rather than skipping the drift check"
new_repo pr-no-base
write_dockerfile 18.3.0 18.3.0 "$OLD_AMD" "$OLD_ARM"
git commit -qam "bump on a shallow PR checkout"
OH_MY_PI_PIN_BASE='' CASE_GITHUB_BASE_REF=main run_guard
expect_fail pr-no-base
expect_output pr-no-base "fetch-depth: 0"

echo "==> a pull request whose base resolves -> drift is checked against origin/<base>"
new_repo pr-base
git update-ref refs/remotes/origin/main refs/heads/base
write_dockerfile 18.3.0 18.3.0 "$OLD_AMD" "$OLD_ARM"
git commit -qam "bump, base resolves via origin/main"
OH_MY_PI_PIN_BASE='' CASE_GITHUB_BASE_REF=main run_guard
expect_fail pr-base
expect_output pr-base "since origin/main"

echo "==> an explicit OH_MY_PI_PIN_BASE that does not resolve -> fails rather than silently skipping"
new_repo bad-base
OH_MY_PI_PIN_BASE=does-not-exist run_guard
expect_fail bad-base
expect_output bad-base "does not resolve"

echo "oh-my-pi pin guard cases: PASS"
