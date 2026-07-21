#!/usr/bin/env bash
# test-codex-review.sh — offline unit tests for scripts/codex-review.sh's
# target selection and prompt assembly. A stub `codex` on PATH records its
# arguments, so no network, auth, or real review is involved. Guards the
# regression a real adversarial review caught: with no local main/master and
# origin/HEAD pointing at another default branch, the base fallback used to
# strip `origin/` into a nonexistent local ref and silently report nothing
# to review. Run via `task test:codex-review`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# Stub codex: print the invocation so assertions can grep it.
mkdir -p "${test_tmp}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "STUB-ARGS:%s %s\n" "$1" "$2"' 'printf "STUB-PROMPT:%s\n" "$3"' >"${test_tmp}/bin/codex"
chmod +x "${test_tmp}/bin/codex"
PATH="${test_tmp}/bin:${PATH}"
export PATH

git_t() {
    git -c user.email=test@test -c user.name=test "$@"
}

# Fixture: an upstream whose default branch is `develop` (not main/master),
# and a clone with only origin/develop plus a feature branch.
git init -q -b develop "${test_tmp}/upstream"
(
    cd "${test_tmp}/upstream"
    mkdir scripts
    cp "${repo}/scripts/codex-review.sh" scripts/
    git add -A
    git_t commit -q -m base
)
git clone -q "${test_tmp}/upstream" "${test_tmp}/clone"
cd "${test_tmp}/clone"
git checkout -q -b feature
echo change >feature.txt
git add feature.txt
git_t commit -q -m work
git branch -q -D develop

run() {
    ./scripts/codex-review.sh "$@" 2>&1
}

echo "==> clean tree, no local main/master: falls back to origin/HEAD's branch"
out="$(run challenge)" || fail "challenge exited non-zero: $out"
echo "$out" | grep -q "STUB-ARGS:exec review" || fail "codex exec review not invoked: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "remote-qualified fallback base missing: $out"
echo "$out" | grep -q "ADVERSARIAL" || fail "challenge mode instructions missing: $out"
echo "$out" | grep -q "feature.txt" || fail "changed-file manifest missing from branch-scope prompt: $out"

echo "==> explicit --base and focus text reach the prompt"
out="$(run review --base origin/develop watch the hooks)" || fail "review --base exited non-zero: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "--base not honored: $out"
echo "$out" | grep -q "VERIFICATION-CHECKPOINT" || fail "review mode instructions missing: $out"
echo "$out" | grep -q "watch the hooks" || fail "focus text missing from prompt: $out"

echo "==> dirty tree auto-selects uncommitted scope"
echo x >dirty.txt
out="$(run review)" || fail "dirty-tree review exited non-zero: $out"
echo "$out" | grep -q "uncommitted work" || fail "dirty tree did not select uncommitted scope: $out"
echo "$out" | grep -q "dirty.txt" || fail "untracked file missing from uncommitted manifest: $out"
rm -f dirty.txt

echo "==> a >200-entry dirty tree still reviews (no SIGPIPE abort) and marks truncation"
# Top-level files: git status collapses an untracked directory into a single
# "?? dir/" entry, which would defeat the >200-entry premise.
i=1
while [ "$i" -le 250 ]; do
    : >"bulk_f${i}.txt"
    i=$((i + 1))
done
out="$(run review)" || fail "large dirty tree aborted the review (pipefail/SIGPIPE regression): $out"
echo "$out" | grep -q "STUB-ARGS:exec review" || fail "codex not invoked on large dirty tree: $out"
echo "$out" | grep -q "manifest truncated at 200 entries" || fail "truncation marker missing on >200-entry manifest: $out"
rm -f bulk_f*.txt

echo "==> clean tree at the base tip reports nothing to review"
git checkout -q -b tipcheck origin/develop
out="$(run review)" || fail "nothing-to-review case exited non-zero: $out"
echo "$out" | grep -q "Nothing to review" || fail "expected nothing-to-review message: $out"
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite nothing to review: $out"

echo "==> bad mode is rejected"
if out="$(run bogus 2>&1)"; then
    fail "bogus mode accepted: $out"
fi

echo "==> invalid explicit targets fail fast without invoking codex"
if out="$(run review --base no-such-ref 2>&1)"; then
    fail "--base with an unresolvable ref was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite bad --base ref: $out"
echo "$out" | grep -q "does not resolve" || fail "missing fail-fast message for bad --base: $out"
if out="$(run challenge --commit 0000000000000000000000000000000000000000 2>&1)"; then
    fail "--commit with an unresolvable sha was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite bad --commit sha: $out"

echo "codex-review target selection OK (7 cases)"
