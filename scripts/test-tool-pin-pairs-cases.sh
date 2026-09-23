#!/usr/bin/env bash
# Behavioural fixtures for scripts/test-tool-pin-pairs.sh: each case builds a
# throwaway repo whose base commit pins a tool at one release, applies a change,
# and asserts the guard's verdict and message.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
guard="${repo_root}/scripts/test-tool-pin-pairs.sh"

tmp="$(mktemp -d -t harmon-init-pin-pairs-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

OLD_AMD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_ARM=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NEW_AMD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
NEW_ARM=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

# Spelled through a variable so no Renovate manager (which watches scripts/*.sh)
# mistakes these fixture pins for real ones and opens bump PRs against them.
ann='# renovate'

# write_action <version> <amd64 tag> <amd64 hash> <arm64 tag> <arm64 hash>
write_action() {
    mkdir -p .github/actions/setup
    cat >.github/actions/setup/action.yml <<EOF
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        ${ann}: datasource=github-releases depName=mvdan/sh extractVersion=^v?(?<version>.+)$
        SHFMT_VERSION=$1 # pin-pair: shfmt
        case "\$runner_arch" in
          X64|x86_64)
            ${ann}: datasource=github-release-attachments depName=mvdan/sh digestVersion=$2
            shfmt_sha256=$3 # pin-pair: shfmt
            ;;
          ARM64|arm64|aarch64)
            ${ann}: datasource=github-release-attachments depName=mvdan/sh digestVersion=$4
            shfmt_sha256=$5 # pin-pair: shfmt
            ;;
        esac
EOF
}

# new_repo <name>: a repo whose `base` branch pins shfmt 3.13.1, checked out on
# a `work` branch ready for the case's change.
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
    write_action 3.13.1 v3.13.1 "$OLD_AMD" v3.13.1 "$OLD_ARM"
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
    output="$(PIN_PAIRS_BASE="${PIN_PAIRS_BASE-base}" GITHUB_BASE_REF="${CASE_GITHUB_BASE_REF:-}" "$guard" 2>&1)" || status=$?
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

echo "==> stale hash: version and tags bumped, hashes left at the old release -> fails, names the tool and the fix"
new_repo stale-hash
write_action 3.14.1 v3.14.1 "$OLD_AMD" v3.14.1 "$OLD_ARM"
git commit -qam "bump version only"
start="$(date +%s)"
run_guard
elapsed=$(($(date +%s) - start))
expect_fail stale-hash
expect_output stale-hash "pin-pair 'shfmt'"
expect_output stale-hash "SHFMT_VERSION changed 3.13.1 -> 3.14.1"
expect_output stale-hash "curl -fsSL https://github.com/mvdan/sh/releases/download/"
expect_output stale-hash "sha256sum"
[ "$elapsed" -lt 5 ] || fail "stale-hash: guard took ${elapsed}s (budget: under 5s)"

echo "==> one architecture left behind -> fails, naming only that line"
new_repo one-stale
write_action 3.14.1 v3.14.1 "$NEW_AMD" v3.14.1 "$OLD_ARM"
git commit -qam "bump, arm64 hash forgotten"
run_guard
expect_fail one-stale
expect_output one-stale "these paired hash lines did not: 15."

echo "==> the stale state is caught before it is committed (working tree vs merge-base)"
new_repo uncommitted
write_action 3.14.1 v3.14.1 "$OLD_AMD" v3.14.1 "$OLD_ARM"
run_guard
expect_fail uncommitted

echo "==> matched bump: version, tags and every hash move together -> passes"
new_repo matched
write_action 3.14.1 v3.14.1 "$NEW_AMD" v3.14.1 "$NEW_ARM"
git commit -qam "matched bump"
run_guard
expect_pass matched
expect_output matched "drift checked against base"

echo "==> unchanged pins on a branch -> passes"
new_repo unchanged
run_guard
expect_pass unchanged

echo "==> hand bump of the version line alone: tags still name the old release -> fails statically"
new_repo tag-mismatch
write_action 3.14.1 v3.13.1 "$NEW_AMD" v3.13.1 "$NEW_ARM"
run_guard
expect_fail tag-mismatch
expect_output tag-mismatch "annotated for v3.13.1 but SHFMT_VERSION is 3.14.1"

echo "==> a paired hash with no github-release-attachments annotation -> fails"
new_repo unannotated
# Drop the annotation line directly above the amd64 hash.
awk -v t="shfmt_sha256=${OLD_AMD}" '
    NR > 1 { if (!done && index($0, t)) done = 1; else print prev }
    { prev = $0 }
    END { print prev }
' .github/actions/setup/action.yml >action.tmp
mv action.tmp .github/actions/setup/action.yml
grep -q "shfmt_sha256=${OLD_AMD}" .github/actions/setup/action.yml || fail "unannotated: fixture edit removed the hash line"
run_guard
expect_fail unannotated
expect_output unannotated "not directly under a"

echo "==> a hash annotated for a different project than its version line -> fails"
new_repo wrong-dep
sed -i.bak 's#depName=mvdan/sh digestVersion=v3.13.1#depName=mvdan/other digestVersion=v3.13.1#' .github/actions/setup/action.yml
rm -f .github/actions/setup/action.yml.bak
run_guard
expect_fail wrong-dep
expect_output wrong-dep "is annotated for mvdan/other but SHFMT_VERSION"

echo "==> a marker on a line that is not NAME=value -> fails"
new_repo bad-marker
printf '%s\n' '        echo hi # pin-pair: shfmt' >>.github/actions/setup/action.yml
run_guard
expect_fail bad-marker
expect_output bad-marker "is not \`NAME=value # pin-pair: <tool>\`"

echo "==> hashes with no version line -> fails"
new_repo no-version
sed -i.bak 's/^        SHFMT_VERSION=3.13.1 # pin-pair: shfmt$/        SHFMT_VERSION=3.13.1/' .github/actions/setup/action.yml
rm -f .github/actions/setup/action.yml.bak
run_guard
expect_fail no-version
expect_output no-version "has hash lines but no"

echo "==> no merge-base (no remote, no PIN_PAIRS_BASE) -> static checks only, passes with a notice"
new_repo no-base
write_action 3.14.1 v3.14.1 "$OLD_AMD" v3.14.1 "$OLD_ARM"
PIN_PAIRS_BASE='' run_guard
expect_pass no-base
expect_output no-base "drift check skipped"

echo "==> a pull request with no merge-base (shallow checkout) -> fails rather than skipping the drift check"
new_repo pr-no-base
PIN_PAIRS_BASE='' CASE_GITHUB_BASE_REF=main run_guard
expect_fail pr-no-base
expect_output pr-no-base "fetch-depth: 0"

echo "==> a pull request whose base resolves -> drift is checked against origin/<base>"
new_repo pr-base
git update-ref refs/remotes/origin/main refs/heads/base
write_action 3.14.1 v3.14.1 "$OLD_AMD" v3.14.1 "$OLD_ARM"
PIN_PAIRS_BASE='' CASE_GITHUB_BASE_REF=main run_guard
expect_fail pr-base
expect_output pr-base "since origin/main"

echo "==> an explicit PIN_PAIRS_BASE that does not resolve -> fails rather than silently skipping"
new_repo bad-base
PIN_PAIRS_BASE=does-not-exist run_guard
expect_fail bad-base
expect_output bad-base "does not resolve"

echo "==> no markers at all -> passes"
mkdir -p "${tmp}/none" && cd "${tmp}/none" && git init -q .
PIN_PAIRS_BASE='' run_guard
expect_pass none
expect_output none "no '# pin-pair:' markers"

echo "tool pin-pair guard cases: PASS"
