#!/usr/bin/env bash
# Focused tests for the production quiet-grep invariant.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
guard="$repo/scripts/lint-shell-robustness.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    printf '  ✗ %s\n' "$*" >&2 || true
    return 0
}

fixture() {
    local name="$1" path="$tmp_root/$1"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
        cat
    } >"$path"
    printf '%s\n' "$path"
}

expect_flagged() {
    local description="$1" path="$2" output
    if output="$($guard "$path" 2>&1)"; then
        bad "$description (expected rejection)"
    elif [[ "$output" == *"quiet-mode grep is banned"* ]]; then
        ok "$description"
    else
        bad "$description (wrong rejection: $output)"
    fi
}

expect_clean() {
    local description="$1" path="$2" output
    if output="$($guard "$path" 2>&1)"; then
        ok "$description"
    else
        bad "$description (unexpected rejection: $output)"
    fi
}

echo '==> quiet grep spellings are rejected'
path="$(
    fixture ordinary.sh <<'BODY'
grep -q needle file
BODY
)"
expect_flagged 'ordinary -q' "$path"

path="$(
    fixture long-options.sh <<'BODY'
grep --quiet needle file
grep --silent needle file
BODY
)"
expect_flagged 'long quiet options' "$path"

path="$(
    fixture combined.sh <<'BODY'
grep -qm1 needle file
grep -mq needle file
BODY
)"
expect_flagged 'combined short options including digits' "$path"

path="$(
    fixture wrappers.sh <<'BODY'
command grep -q needle file
env LC_ALL=C grep --quiet needle file
time grep -mq needle file
BODY
)"
expect_flagged 'safe command-prefix wrappers do not hide grep' "$path"

path="$(
    fixture qualified.sh <<'BODY'
/usr/bin/grep -q needle file
BODY
)"
expect_flagged 'path-qualified grep' "$path"

path="$(
    fixture continued.sh <<'BODY'
command grep \
-qm1 needle file
BODY
)"
expect_flagged 'line-continuation options' "$path"

echo '==> pipeline syntax is irrelevant to the invariant'
path="$(
    fixture compound-same-line.sh <<'BODY'
seq 100000 | { grep -q 1; }
BODY
)"
expect_flagged 'same-line compound RHS' "$path"

path="$(
    fixture compound-next-line.sh <<'BODY'
seq 100000 |
{
    grep -q 1
}
BODY
)"
expect_flagged 'pipe then next-line compound RHS' "$path"

path="$(
    fixture compound-stderr.sh <<'BODY'
seq 100000 |&
(
    grep -mq 1
)
BODY
)"
expect_flagged 'stderr pipe and next-line subshell RHS' "$path"

echo '==> small explicit exclusions stay outside the invariant'
path="$(
    fixture safe.sh <<'BODY'
if grep -F needle file >/dev/null; then
    printf '%s\n' found
fi
grep -- -q file >/dev/null
printf '%s\n' 'grep -q is sample text'
sample="grep --quiet is quoted text"
# grep -qm1 is a comment
cat <<'SCRIPT'
grep -q is fixture text
return 0
SCRIPT
BODY
)"
expect_clean 'redirected grep, comments, quotes, and heredocs' "$path"

path="$(
    fixture multiline-quote.sh <<'BODY'
sample="grep \
-q is still quoted"
printf '%s\n' "$sample" >/dev/null
BODY
)"
expect_clean 'multiline quoted sample text' "$path"

path="$(
    fixture test-reporter.sh <<'BODY'
ok() {
    cat <<'SCRIPT'
return 0
SCRIPT
    echo "$*"
}
BODY
)"
expect_clean 'test suites and reporter fixtures are excluded by scope' "$path"

echo '==> repository enumeration is authoritative and fail-closed'
scope_repo="$tmp_root/scope-repo"
mkdir -p "$scope_repo/.claude/hooks" "$scope_repo/.devcontainer" \
    "$scope_repo/scripts" "$scope_repo/template/scripts" "$scope_repo/.claude/skills/vendor"
git -C "$scope_repo" init -q
printf '%s\n' '#!/bin/sh' 'grep -q needle file' >"$scope_repo/.claude/hooks/hazard.sh"
printf '%s\n' '#!/bin/sh' 'time grep -qm1 needle file' >"$scope_repo/.devcontainer/hazard.bash"
printf '%s\n' '#!/bin/sh' 'grep -q fixture file' >"$scope_repo/scripts/test-fixture.sh"
printf '%s\n' '#!/bin/sh' 'grep --quiet vendored file' >"$scope_repo/.claude/skills/vendor/ignored.sh"
conditional='[% if feature %]helper.sh[% endif %]'
printf '%s\n' '#!/bin/sh' 'command grep -mq needle file' >"$scope_repo/template/scripts/$conditional"
git -C "$scope_repo" add -- .
scope_output="$(cd "$scope_repo" && "$guard" 2>&1)" && scope_status=0 || scope_status=$?
if [ "$scope_status" -ne 0 ] &&
    [[ "$scope_output" == *'.claude/hooks/hazard.sh'* ]] &&
    [[ "$scope_output" == *'.devcontainer/hazard.bash'* ]] &&
    [[ "$scope_output" == *"template/scripts/$conditional"* ]] &&
    [[ "$scope_output" != *'test-fixture.sh'* ]] &&
    [[ "$scope_output" != *'.claude/skills/vendor/ignored.sh'* ]]; then
    ok 'tracked production scope includes root and conditional template scripts only'
else
    bad "tracked production scope mismatch: $scope_output"
fi

printf '%s\n' '#!/bin/sh' 'grep needle file >/dev/null' >"$scope_repo/.claude/hooks/hazard.sh"
printf '%s\n' '#!/bin/sh' 'grep needle file >/dev/null' >"$scope_repo/.devcontainer/hazard.bash"
printf '%s\n' '#!/bin/sh' 'grep needle file >/dev/null' >"$scope_repo/template/scripts/$conditional"
git -C "$scope_repo" add -- .
if scope_output="$(cd "$scope_repo" && "$guard" 2>&1)"; then
    ok 'tracked production scope passes after standardizing grep checks'
else
    bad "clean tracked production scope was rejected: $scope_output"
fi

fail_repo="$tmp_root/fail-repo"
stub_bin="$tmp_root/stub-bin"
mkdir -p "$fail_repo" "$stub_bin"
stub="$stub_bin/git"
apply_stub="$tmp_root/git-stub-body"
printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$1" = rev-parse ]; then' \
    "    printf '%s\\n' '$fail_repo'" \
    '    exit 0' \
    'fi' \
    'exit 7' >"$apply_stub"
cp "$apply_stub" "$stub"
chmod +x "$stub"
if output="$(cd "$fail_repo" && PATH="$stub_bin:$PATH" "$guard" 2>&1)"; then
    bad 'git enumeration failure must fail closed'
elif [[ "$output" == *'could not enumerate tracked shell files'* ]]; then
    ok 'git enumeration failure fails closed'
else
    bad "git enumeration failure produced the wrong diagnostic: $output"
fi

if output="$($guard "$tmp_root/missing.sh" 2>&1)"; then
    bad 'missing explicit file must fail'
elif [[ "$output" == *'no such file'* ]]; then
    ok 'missing explicit file fails closed'
else
    bad "missing explicit file produced the wrong diagnostic: $output"
fi

echo '==> the real tracked production tree is clean'
if output="$(cd "$repo" && "$guard" 2>&1)"; then
    ok 'repository production scripts satisfy the invariant'
else
    bad "repository guard failed: $output"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
