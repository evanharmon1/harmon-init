#!/usr/bin/env bash
# test-session-cleanup.sh — behavioral test for the session-cleanup surface
# (audit-session-artifacts.sh / clean-branches.sh). Run via
# `task test:session-cleanup`.
#
# Everything happens inside a throwaway fixture repository, never in the
# calling repository: the script under test deletes branches, and a test that
# did that to the developer's own checkout would be a data-loss path.
#
# `gh` is stubbed on PATH with a shim that answers exactly the invocations the
# scripts make (repo view, pr list --head, batched pr list), driven by a
# tab-separated PR table — so every case runs offline and deterministically.
# One shim mode advances a branch ref as a side effect of answering, to drive
# the compare-and-delete race window (test-worktree.sh's WTSHIM_ADVANCE
# precedent).
#
# Every run is self-contained under per-run mktemp paths, so any number of
# suites may run concurrently without sharing a byte of state.
set -euo pipefail

# No child may inherit a never-ending stdin (harmon-init#802).
exec </dev/null

repo="$(git rev-parse --show-toplevel)"

# Hooks export GIT_DIR/GIT_WORK_TREE; left set, every `git` below would
# retarget the CALLING repository instead of the fixture.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Neutralize every out-of-tree source of git config so the fixture is hermetic
# (same sanitation as test-worktree.sh).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
git_config_count="${GIT_CONFIG_COUNT:-0}"
case "$git_config_count" in
'' | *[!0-9]*) git_config_count=0 ;;
esac
i=0
while [ "$i" -lt "$git_config_count" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ALTERNATE_OBJECT_DIRECTORIES

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

expect_contains() {
    # expect_contains <haystack> <needle> <label>
    case "$1" in
    *"$2"*) ;;
    *) fail "$3: expected output to contain '$2'" ;;
    esac
}

expect_not_contains() {
    case "$1" in
    *"$2"*) fail "$3: expected output NOT to contain '$2'" ;;
    esac
}

branch_exists() {
    git -C "$fixture" show-ref --verify --quiet "refs/heads/$1"
}

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/session-cleanup-test.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
# Resolve symlinks now (macOS mktemp answers under /var -> /private/var), so
# assertions comparing against git's resolved worktree paths match literally.
test_tmp="$(cd "$test_tmp" && pwd -P)"

# ── gh stub ─────────────────────────────────────────────────────────────────

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub: answers the exact reads the cleanup scripts perform, from the PR
# table in $GH_STUB_PRS (lines: headRefName<TAB>headRefOid<TAB>number<TAB>baseRefName).
set -euo pipefail
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
    exit 1
fi
cmd="${1:-}"
sub="${2:-}"
if [ "$cmd" = repo ] && [ "$sub" = view ]; then
    echo "stub/fixture"
    exit 0
fi
if [ "$cmd" = pr ] && [ "$sub" = list ]; then
    head_filter=""
    batch=false
    prev=""
    for a in "$@"; do
        [ "$prev" = "--head" ] && head_filter="$a"
        case "$a" in *headRefName*) batch=true ;; esac
        prev="$a"
    done
    data="${GH_STUB_PRS:-}"
    if [ -n "$data" ] && [ -f "$data" ]; then
        if [ "$batch" = true ]; then
            cat "$data"
        else
            awk -F'\t' -v b="$head_filter" '$1 == b { print $3 "\t" $2 "\t" $4 }' "$data"
            # Side effect modes, firing AFTER the answer to open the window
            # between verification and deletion: advance the queried branch,
            # or check it out into a worktree (the concurrent-session race).
            if [ -n "${GH_STUB_ADVANCE:-}" ] && [ "$head_filter" = "$GH_STUB_ADVANCE" ]; then
                tip="$(git rev-parse "refs/heads/$head_filter")"
                tree="$(git rev-parse "$tip^{tree}")"
                new="$(git commit-tree -p "$tip" -m advanced "$tree")"
                git update-ref "refs/heads/$head_filter" "$new" "$tip"
            fi
            if [ -n "${GH_STUB_CHECKOUT:-}" ] && [ "$head_filter" = "$GH_STUB_CHECKOUT" ]; then
                git worktree add -q "$GH_STUB_CHECKOUT_DIR" "$head_filter"
            fi
        fi
    fi
    exit 0
fi
echo "gh stub: unexpected invocation: $*" >&2
exit 64
STUB
chmod +x "$stub_bin/gh"
PATH="$stub_bin:$PATH"

# ── Fixture repository ──────────────────────────────────────────────────────

origin="$test_tmp/origin.git"
fixture="$test_tmp/fixture"
git init -q --bare --initial-branch=main "$origin"
git clone -q "$origin" "$fixture" 2>/dev/null
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name "Session Cleanup Test"
git -C "$fixture" symbolic-ref HEAD refs/heads/main
(
    cd "$fixture"
    echo base >README.md
    git add README.md
    git commit -qm "initial"
    git push -qu origin main
    git remote set-head origin --auto
)

# The scripts resolve their repo root from their own location, so the fixture
# gets its own copy — the same way generated repos ship them. worktree-lock.sh
# rides along because the delete path sources its lifecycle-lock protocol.
mkdir -p "$fixture/scripts"
cp "$repo/scripts/clean-branches.sh" "$repo/scripts/audit-session-artifacts.sh" \
    "$repo/scripts/worktree-lock.sh" "$fixture/scripts/"

# make_branch <name> <file> — new branch off main with one pushed commit;
# echoes the tip. Leaves the checkout back on main.
make_branch() {
    (
        cd "$fixture"
        git checkout -q -b "$1" main
        echo "$1" >"$2"
        git add "$2"
        git commit -qm "work on $1"
        git push -qu origin "$1" 2>/dev/null
        git rev-parse HEAD
        git checkout -q main
    )
}

# retire_remote <name> — delete the remote branch and prune, leaving the
# local upstream [gone].
retire_remote() {
    git -C "$fixture" push -q origin ":$1" 2>/dev/null
    git -C "$fixture" fetch -qp origin
}

# 1. anc-merged: fast-forwarded into main — ancestry evidence, class 1.
anc_tip="$(make_branch anc-merged anc.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-merged
    git push -q origin main
)
retire_remote anc-merged

# 2. sq-merged: squash-merged (different commit on main), remote branch gone —
#    PR evidence, class 2.
sq_tip="$(make_branch sq-merged sq.txt)"
(
    cd "$fixture"
    echo sq-merged >sq.txt
    git add sq.txt
    git commit -qm "squash of sq-merged"
    git push -q origin main
)
retire_remote sq-merged

# 3. gone-nopr: upstream gone, no PR anywhere — must survive (negative control).
gone_nopr_tip="$(make_branch gone-nopr nopr.txt)"
retire_remote gone-nopr

# 4. gone-tipdiff: a merged PR exists for an EARLIER commit, but the local tip
#    has one more (unpushed) commit — must survive (negative control).
tipdiff_pushed="$(make_branch gone-tipdiff tipdiff.txt)"
(
    cd "$fixture"
    git checkout -q gone-tipdiff
    echo more >>tipdiff.txt
    git add tipdiff.txt
    git commit -qm "extra local work"
    git checkout -q main
)
retire_remote gone-tipdiff

# 5. wt-checked: PR evidence says merged, but the branch is checked out in a
#    linked worktree — must survive (negative control for the update-ref path,
#    which does not respect git's checked-out guard on its own).
wt_tip="$(make_branch wt-checked wt.txt)"
retire_remote wt-checked
git -C "$fixture" worktree add -q "$test_tmp/wt" wt-checked

# 6. unpushed-live: never pushed anywhere — ordinary in-flight work, silent
#    survival.
(
    cd "$fixture"
    git checkout -q -b unpushed-live main
    echo local >local.txt
    git add local.txt
    git commit -qm "local-only work"
    git checkout -q main
)

# 6b. sq-stacked: a merged PR exists at exactly this tip, but its base was a
#     stacked branch, not the default — insufficient evidence; must survive.
stacked_tip="$(make_branch sq-stacked stacked.txt)"
retire_remote sq-stacked

# 6c. tf-stale: the remote branch is deleted upstream WITHOUT a local fetch
#     (bare-origin surgery), so the local tracking ref survives, the branch
#     reads neither [gone] nor unpushed — the audit's freshness section is
#     what must surface it.
tf_tip="$(make_branch tf-stale tf.txt)"
git -C "$origin" update-ref -d refs/heads/tf-stale

# 7. A tag sharing a branch's name: %(refname:short) would disambiguate the
#    branch to "heads/gone-nopr" and break every ref built from it.
git -C "$fixture" tag gone-nopr

# 8. A symbolic ref under refs/heads: deleting it via update-ref would
#    DEREFERENCE it and delete the target branch — it must be skipped, never
#    resolved.
git -C "$fixture" symbolic-ref refs/heads/alias-main refs/heads/main

# The PR table the stub serves (headRefName, headRefOid, number).
export GH_STUB_PRS="$test_tmp/prs.tsv"
printf '%s\t%s\t%s\t%s\n' \
    sq-merged "$sq_tip" 101 main \
    gone-tipdiff "$tipdiff_pushed" 102 main \
    wt-checked "$wt_tip" 103 main \
    sq-stacked "$stacked_tip" 107 feature-base \
    >"$GH_STUB_PRS"

# Audit fixtures: sidecar files and a shepherd cycle state.
gitdir="$(git -C "$fixture" rev-parse --absolute-git-dir)"
mkdir -p "$gitdir/deferred-findings" "$gitdir/adjudication-ledger/dead" "$gitdir/shepherd-codex/stub/fixture"
echo "p2 note" >"$gitdir/deferred-findings/unpushed-live"
echo "orphan" >"$gitdir/adjudication-ledger/dead/branch"
echo '{}' >"$gitdir/shepherd-codex/stub/fixture/42.json"

snapshot() {
    git -C "$fixture" for-each-ref --format='%(refname) %(objectname)'
    git -C "$fixture" worktree list --porcelain
}

# ── Case A: dry run is the default and mutates nothing ─────────────────────

before="$(snapshot)"
dry_out="$(cd "$fixture" && bash scripts/clean-branches.sh 2>&1)" ||
    fail "dry run exited nonzero: $dry_out"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "dry run mutated refs or worktrees"

expect_contains "$dry_out" "WOULD DELETE  anc-merged" "dry run: ancestry candidate"
expect_contains "$dry_out" "WOULD DELETE  sq-merged" "dry run: PR-evidence candidate"
expect_contains "$dry_out" "merged PR #101" "dry run: names the vouching PR"
expect_not_contains "$dry_out" "WOULD DELETE  main" "dry run: default branch is never a candidate"
expect_not_contains "$dry_out" "WOULD DELETE  gone-nopr" "dry run: no-evidence branch is not a candidate"
expect_contains "$dry_out" "gone-nopr" "dry run: no-evidence branch is skipped loudly"
expect_contains "$dry_out" "unpushed work is never deleted" "dry run: tip-past-PR branch refused as unpushed"
expect_contains "$dry_out" "checked out in worktree" "dry run: worktree branch refused loudly"
expect_contains "$dry_out" "SKIP  alias-main — symbolic ref" "dry run: symbolic ref skipped, never dereferenced"
expect_not_contains "$dry_out" "WOULD DELETE  sq-stacked" "dry run: PR into a non-default base is not evidence"
expect_contains "$dry_out" "sq-stacked" "dry run: stacked-base branch skipped loudly"
expect_not_contains "$dry_out" "WOULD DELETE  alias-main" "dry run: symbolic ref is never a candidate"
expect_not_contains "$dry_out" "heads/gone-nopr" "dry run: tag/branch name collision does not mangle the branch name"
echo "ok: dry run classifies and mutates nothing"

# ── Case B: audit reports everything and mutates nothing ───────────────────

before="$(snapshot)"
audit_out="$(cd "$fixture" && bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "audit exited nonzero: $audit_out"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "audit mutated refs or worktrees"

expect_contains "$audit_out" "unpushed-live — 1 commit(s) on no remote" "audit: unpushed work is the headline"
expect_contains "$audit_out" "prunable      sq-merged — merged PR #101" "audit: prunable classification"
expect_contains "$audit_out" "no merged PR  gone-nopr" "audit: gone without PR"
expect_contains "$audit_out" "tip differs   gone-tipdiff" "audit: PR matched by name but not tip"
expect_contains "$audit_out" "tip differs   sq-stacked" "audit: non-default-base PR is not prunable evidence"
expect_contains "$audit_out" "tf-stale — deleted upstream" "audit: stale tracking ref surfaced by the freshness section"
expect_contains "$audit_out" "$test_tmp/wt — wt-checked" "audit: other worktree named"
expect_contains "$audit_out" "active    deferred-findings/unpushed-live" "audit: live sidecar"
expect_contains "$audit_out" "leftover  adjudication-ledger/dead/branch" "audit: orphan sidecar"
expect_contains "$audit_out" "stub/fixture/42.json" "audit: shepherd cycle state listed"
echo "ok: audit reports all artifact classes read-only"

# Degraded mode: a failing gh probe is UNVERIFIED, never silently clean.
audit_fail_out="$(cd "$fixture" && GH_STUB_FAIL=1 bash scripts/audit-session-artifacts.sh 2>&1)" ||
    fail "degraded audit exited nonzero: $audit_fail_out"
expect_contains "$audit_fail_out" "UNVERIFIED" "audit: failed PR read reported unverified"
echo "ok: audit fails closed when gh is unavailable"

# ── Case C: a failed PR probe blocks PR-evidence deletion (fail closed) ────

failrun_out="$(cd "$fixture" && GH_STUB_FAIL=1 bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "fail-closed delete run exited nonzero: $failrun_out"
branch_exists sq-merged || fail "fail-closed: sq-merged deleted without a reachable PR check"
expect_contains "$failrun_out" "gh is unavailable" "fail-closed: refusal is loud"
branch_exists anc-merged && fail "fail-closed: ancestry evidence needs no gh, anc-merged should have been deleted"
expect_contains "$failrun_out" "deleted  anc-merged" "fail-closed: ancestry deletion proceeded offline"
echo "ok: PR-evidence deletion fails closed without gh"

# ── Case D: --delete removes exactly the evidenced branches ────────────────

del_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "delete run exited nonzero: $del_out"
expect_contains "$del_out" "deleted  sq-merged" "delete: squash-merged branch removed"
expect_contains "$del_out" "recover: git branch sq-merged" "delete: recovery hint printed"
branch_exists sq-merged && fail "delete: sq-merged still exists"
git -C "$fixture" config --get-regexp '^branch\.sq-merged\.' >/dev/null 2>&1 &&
    fail "delete: branch.sq-merged config section left behind"
branch_exists gone-nopr || fail "negative control: gone-nopr was deleted without evidence"
branch_exists gone-tipdiff || fail "negative control: gone-tipdiff was deleted despite unpushed tip"
branch_exists wt-checked || fail "negative control: worktree-checked-out branch was deleted"
branch_exists unpushed-live || fail "negative control: unpushed in-flight branch was deleted"
branch_exists sq-stacked || fail "negative control: stacked-base PR branch was deleted"
branch_exists main || fail "negative control: default branch was deleted"
[ -d "$test_tmp/wt" ] || fail "delete: worktree directory was removed"
git -C "$fixture" symbolic-ref -q refs/heads/alias-main >/dev/null ||
    fail "negative control: symbolic ref alias-main was deleted"
echo "ok: delete removes evidenced branches only, negative controls survive"

# ── Case E: compare-and-delete refuses a tip that moved after verification ─

cad_tip="$(make_branch sq-cad cad.txt)"
(
    cd "$fixture"
    echo cad >cad.txt
    git add cad.txt
    git commit -qm "squash of sq-cad"
    git push -q origin main
)
retire_remote sq-cad
printf '%s\t%s\t%s\t%s\n' sq-cad "$cad_tip" 104 main >>"$GH_STUB_PRS"

cad_out="$(cd "$fixture" && GH_STUB_ADVANCE=sq-cad bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "CAD run exited nonzero: $cad_out"
expect_contains "$cad_out" "tip moved since verification" "CAD: refusal is loud"
branch_exists sq-cad || fail "CAD: sq-cad deleted although its tip moved after verification"
echo "ok: compare-and-delete refuses a moved tip"

# ── Case E2: a branch claimed by a worktree AFTER classification survives ──
# Classification saw it unclaimed; the stub checks it out while answering the
# PR probe. Only the delete-phase re-check stands between update-ref and
# another session's workspace.

race_tip="$(make_branch sq-race race.txt)"
(
    cd "$fixture"
    echo race >race.txt
    git add race.txt
    git commit -qm "squash of sq-race"
    git push -q origin main
)
retire_remote sq-race
printf '%s\t%s\t%s\t%s\n' sq-race "$race_tip" 105 main >>"$GH_STUB_PRS"

race_out="$(cd "$fixture" && GH_STUB_CHECKOUT=sq-race GH_STUB_CHECKOUT_DIR="$test_tmp/wt-race" \
    bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "worktree-race run exited nonzero: $race_out"
expect_contains "$race_out" "became checked out in a worktree since classification" "race: delete-phase re-check refused"
branch_exists sq-race || fail "race: sq-race deleted although a worktree claimed it mid-run"
echo "ok: delete-phase worktree re-check catches a mid-run checkout"

# ── Case E3: a held branch lifecycle lock refuses the deletion ─────────────
# The lock is the serialization boundary shared with worktree:new/rm; an
# ownerless entry always refuses (crash-vs-suspension is undecidable), which
# doubles here as the cheapest way to simulate a concurrent holder.

lock_tip="$(make_branch sq-locked lock.txt)"
(
    cd "$fixture"
    echo locked >lock.txt
    git add lock.txt
    git commit -qm "squash of sq-locked"
    git push -q origin main
)
retire_remote sq-locked
printf '%s\t%s\t%s\t%s\n' sq-locked "$lock_tip" 106 main >>"$GH_STUB_PRS"

commondir="$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$commondir/worktree-locks/branch=sq-locked+lock"
locked_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "locked run exited nonzero: $locked_out"
expect_contains "$locked_out" "branch lifecycle lock refused" "lock: contended branch skipped loudly"
branch_exists sq-locked || fail "lock: sq-locked deleted although its lifecycle lock was held"
rmdir "$commondir/worktree-locks/branch=sq-locked+lock"
unlocked_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "post-lock run exited nonzero: $unlocked_out"
expect_contains "$unlocked_out" "deleted  sq-locked" "lock: released lock lets the evidenced delete proceed"
branch_exists sq-locked && fail "lock: sq-locked still exists after the lock was released"
echo "ok: branch lifecycle lock serializes deletion with worktree operations"

# ── Case E4: stale ancestry evidence fails closed ──────────────────────────
# The remote default branch moves (force-push/repoint) after the last fetch;
# the local tracking ref then vouches for commits the remote no longer
# holds. The delete phase compares against the ADVERTISED tip and refuses.

fresh_tip="$(make_branch anc-fresh fresh.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-fresh
    git push -q origin main
)
retire_remote anc-fresh

sab_sha="$(
    cd "$fixture"
    git checkout -q -b sabotage main
    echo sab >sab.txt
    git add sab.txt
    git commit -qm "divergent remote main"
    git push -q origin sabotage:refs/heads/main-sab 2>/dev/null
    git rev-parse HEAD
    git checkout -q main
    git update-ref -d refs/heads/sabotage
)"
git -C "$origin" update-ref refs/heads/main "$sab_sha"

stale_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "stale-ancestry run exited nonzero: $stale_out"
expect_contains "$stale_out" "stale or unverifiable against the live remote" "freshness: stale tracking ref refused"
branch_exists anc-fresh || fail "freshness: anc-fresh deleted against stale ancestry evidence"

git -C "$origin" update-ref refs/heads/main "$(git -C "$fixture" rev-parse refs/remotes/origin/main)"
fresh_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "restored-freshness run exited nonzero: $fresh_out"
expect_contains "$fresh_out" "deleted  anc-fresh" "freshness: fresh evidence lets the ancestry delete proceed"
branch_exists anc-fresh && fail "freshness: anc-fresh still exists after freshness was restored"
echo "ok: ancestry deletion fails closed on stale remote evidence"

# ── Case E5: ancestry deletion works from a divergent checkout ─────────────
# `git branch -d` would authorize against the current HEAD and refuse here;
# the verified-evidence compare-and-delete must not (challenge r2).

anc_head_tip="$(make_branch anc-head head.txt)"
(
    cd "$fixture"
    git merge -q --ff-only anc-head
    git push -q origin main
)
retire_remote anc-head
# runner branches from BEFORE the anc-head merge, so anc-head is not an
# ancestor of HEAD during the run — exactly the state where `git branch -d`
# would refuse what the dry run promised.
(
    cd "$fixture"
    git checkout -q -b runner main~1
    echo runner >runner.txt
    git add runner.txt
    git commit -qm "divergent runner work"
)
div_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "divergent-checkout run exited nonzero: $div_out"
git -C "$fixture" checkout -q main
expect_contains "$div_out" "deleted  anc-head" "divergent HEAD: verified ancestry deletes regardless of checkout"
branch_exists anc-head && fail "divergent HEAD: anc-head still exists"
branch_exists runner || fail "divergent HEAD: the current branch itself was deleted"
echo "ok: ancestry deletion is checkout-independent"

# ── Case E6: a config write failure after deletion is loud ─────────────────
# A stale config.lock makes --remove-section fail; the deletion must still
# report the leftover branch.<name> config instead of swallowing it.

cfg_tip="$(make_branch sq-cfg cfg.txt)"
(
    cd "$fixture"
    echo cfg >cfg.txt
    git add cfg.txt
    git commit -qm "squash of sq-cfg"
    git push -q origin main
)
retire_remote sq-cfg
printf '%s\t%s\t%s\t%s\n' sq-cfg "$cfg_tip" 108 main >>"$GH_STUB_PRS"

gitdir_cfg="$(git -C "$fixture" rev-parse --absolute-git-dir)"
touch "$gitdir_cfg/config.lock"
cfg_out="$(cd "$fixture" && bash scripts/clean-branches.sh --delete 2>&1)" ||
    fail "config-lock run exited nonzero: $cfg_out"
rm -f "$gitdir_cfg/config.lock"
expect_contains "$cfg_out" "deleted  sq-cfg" "config lock: the evidenced deletion itself proceeds"
expect_contains "$cfg_out" "WARN  sq-cfg was deleted but its branch.sq-cfg" "config lock: leftover config reported loudly"
git -C "$fixture" config --local --remove-section branch.sq-cfg 2>/dev/null || true
echo "ok: config cleanup failure is reported, never swallowed"

# ── Case E7: worktree-record pruning refuses to orphan a detached commit ───
# A stale record whose HEAD is detached at a commit no shared ref contains is
# the only thing keeping that commit alive; a raw `git worktree prune` would
# drop it (challenge r3). Branch-attached stale records prune normally.

cp "$repo/scripts/clean-worktree-records.sh" "$fixture/scripts/"

git -C "$fixture" worktree add -q -b prune-br "$test_tmp/wt-br" main
git -C "$fixture" worktree add -q --detach "$test_tmp/wt-det" main
(
    cd "$test_tmp/wt-det"
    echo det >det.txt
    git add det.txt
    git commit -qm "detached-only work"
)
det_sha="$(git -C "$test_tmp/wt-det" rev-parse HEAD)"
rm -rf "$test_tmp/wt-br" "$test_tmp/wt-det"

if prune_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)"; then
    fail "record prune succeeded while a record was the last reference to $det_sha: $prune_out"
fi
expect_contains "$prune_out" "detached commit $det_sha" "record prune: refusal names the at-risk commit"
[ -d "$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)/worktrees" ] &&
    ls "$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)/worktrees" | grep -q wt-det ||
    fail "record prune: the at-risk record was pruned anyway"
echo "ok: record prune refuses to orphan a detached commit"

git -C "$fixture" branch -q rescue-det "$det_sha"
prune_ok_out="$(cd "$fixture" && bash scripts/clean-worktree-records.sh 2>&1)" ||
    fail "record prune failed after the commit was rescued: $prune_ok_out"
expect_contains "$prune_ok_out" "stale records pruned" "record prune: proceeds once the commit is referenced"
if ls "$(git -C "$fixture" rev-parse --path-format=absolute --git-common-dir)/worktrees" 2>/dev/null | grep -Eq 'wt-det|wt-br'; then
    fail "record prune: stale records survived a safe prune"
fi
git -C "$fixture" cat-file -e "$det_sha" || fail "record prune: rescued commit lost from the object db"
echo "ok: record prune clears stale records once every commit is referenced"

# ── Case F: the evidence rule is not bypassable by force ───────────────────

grep -q 'branch -D' "$repo/scripts/clean-branches.sh" &&
    fail "clean-branches.sh contains 'branch -D' — the evidence rule was bypassed"
grep -q 'branch -D' "$repo/scripts/audit-session-artifacts.sh" &&
    fail "audit-session-artifacts.sh contains 'branch -D'"
echo "ok: no force deletion anywhere in the cleanup surface"

# ── Case G: unknown arguments are refused ──────────────────────────────────

if (cd "$fixture" && bash scripts/clean-branches.sh --force >/dev/null 2>&1); then
    fail "clean-branches.sh accepted an unknown --force flag"
fi
echo "ok: unknown flags are refused"

echo "PASS: session-cleanup surface behaves (evidence-gated deletion, loud refusals, read-only audit)"
