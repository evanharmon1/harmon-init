#!/usr/bin/env bash
# Behavioural fixtures for scripts/test-oh-my-pi-pin.sh: each case builds a
# throwaway repo with a fixture images/devcontainer/Dockerfile and asserts the
# guard's verdict, message, and speed.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
guard="${repo_root}/scripts/test-oh-my-pi-pin.sh"

tmp="$(mktemp -d -t harmon-init-oh-my-pi-pin-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

AMD_HASH=0000000000000000000000000000000000000000000000000000000000000000
ARM_HASH=1111111111111111111111111111111111111111111111111111111111111111

# write_dockerfile <version> <marker mode>
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
        echo "ARG OH_MY_PI_SHA256_AMD64=${AMD_HASH}"
        echo "ARG OH_MY_PI_SHA256_ARM64=${ARM_HASH}"
    } >images/devcontainer/Dockerfile
}

new_repo() {
    local dir="${tmp}/$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q .
    git config user.email test@example.com
    git config user.name Test
}

run_guard() {
    status=0
    output="$("$guard" 2>&1)" || status=$?
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

echo "==> OH_MY_PI_VERSION matches the verified-for marker -> passes"
new_repo match
write_dockerfile 18.2.6 18.2.6
start="$(date +%s)"
run_guard
elapsed=$(($(date +%s) - start))
expect_pass match
expect_output match "18.2.6"
[ "$elapsed" -lt 5 ] || fail "match: guard took ${elapsed}s (budget: under 5s)"

echo "==> OH_MY_PI_VERSION bumped past the verified-for marker -> fails fast, names the manual procedure"
new_repo mismatch
write_dockerfile 18.3.0 18.2.6
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

echo "==> no verified-for marker at all -> fails, says so"
new_repo no-marker
write_dockerfile 18.2.6 omit-marker
run_guard
expect_fail no-marker
expect_output no-marker "no '# verified-for:"

echo "==> a different comment sits where the marker belongs -> fails"
new_repo wrong-line
write_dockerfile 18.2.6 wrong-comment
run_guard
expect_fail wrong-line
expect_output wrong-line "no '# verified-for:"

echo "==> no OH_MY_PI_VERSION line at all -> fails"
new_repo no-version
mkdir -p images/devcontainer
echo "FROM scratch" >images/devcontainer/Dockerfile
run_guard
expect_fail no-version
expect_output no-version "could not find"

echo "oh-my-pi pin guard cases: PASS"
