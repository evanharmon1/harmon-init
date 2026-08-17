#!/usr/bin/env bash
# audit-session-artifacts.sh — report every session leftover in one place,
# mutating nothing. Run via `task audit:session-artifacts`.
#
# Companion to clean-branches.sh (harmon-init#838): this script only reports —
# no deletion, no fetch, no ref write, ever. The sections, in the order a
# human should read them:
#
#   1. branches with UNPUSHED commits — work about to be lost silently
#   2. gone-upstream branches, classified by merged-PR evidence
#   3. worktrees other than this one — named, never touched
#   4. review sidecars (deferred-findings / adjudication-ledger) left behind
#   5. shepherd Codex cycle-state files
#   6. totals, so branch creep stays visible
#
# Squash-merge context: `git branch --merged` cannot see a squash-merged
# branch, so classification asks the PR API (one batched read). Where gh is
# unavailable the classification is reported UNVERIFIED, never "clean".
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-session.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

section() {
    printf '\n== %s ==\n' "$1"
}

# Bounded network probes (status.sh precedent — a hung gh call must not wedge
# the report; stock macOS gets `timeout` from coreutils).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
else
    echo "audit:session-artifacts: no 'timeout' found (brew install coreutils) — network probes are unbounded." >&2
fi

# net_probe <cmd...> — bounded, stdin-closed network invocation (gh or git).
net_probe() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" -k 5 "${GH_TIMEOUT:-30}" "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

# %(refname:lstrip=2), not %(refname:short): when a tag shares a branch's
# name, :short disambiguates to "heads/<name>" and every "refs/heads/$branch"
# built from it dereferences nothing (challenge r1).
git for-each-ref refs/heads \
    --format='%(refname:lstrip=2)%09%(objectname)%09%(upstream:track)' \
    >"$tmp/branches"
total_branches="$(wc -l <"$tmp/branches" | tr -d ' ')"

has_remote=true
[ -n "$(git remote)" ] || has_remote=false

# One remote and its default branch, resolved once: origin preferred, else
# the first listed. The default branch scopes the merged-PR evidence below —
# only a merge into it proves durable delivery (challenge r2).
remote=""
default_branch=""
if [ "$has_remote" = true ]; then
    remote="$(git remote | head -n 1)"
    if git remote | grep -qx origin; then
        remote=origin
    fi
    if default_ref="$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD")"; then
        default_branch="${default_ref#"refs/remotes/$remote/"}"
    else
        for cand in main master; do
            if git show-ref --verify --quiet "refs/remotes/$remote/$cand"; then
                default_branch="$cand"
                break
            fi
        done
    fi
fi

# ── 1. Unpushed work ────────────────────────────────────────────────────────

section "Branches with unpushed commits (work on no remote)"
if [ "$has_remote" = false ]; then
    echo "No remote configured — every local commit is unpushed by definition; listing skipped."
else
    unpushed_count=0
    while IFS=$'\t' read -r branch _tip _track; do
        n="$(git rev-list --count "refs/heads/$branch" --not --remotes --)"
        if [ "$n" -gt 0 ]; then
            printf '  %s — %s commit(s) on no remote\n' "$branch" "$n"
            unpushed_count=$((unpushed_count + 1))
        fi
    done <"$tmp/branches"
    if [ "$unpushed_count" -eq 0 ]; then
        echo "  none"
    fi
fi

# ── 1b. Remote-tracking freshness ───────────────────────────────────────────

# Every judgement above and below is only as fresh as the tracking refs: a
# remote branch deleted upstream (e.g. GitHub's delete-on-merge) is invisible
# here until a fetch --prune — its local branch reads neither [gone] nor
# unpushed (challenge r2). One bounded read of the remote's advertised heads
# makes that staleness explicit instead of silent.
section "Remote-tracking freshness"
if [ "$has_remote" = false ]; then
    echo "  n/a — no remote configured"
elif net_probe git ls-remote --heads "$remote" >"$tmp/remote-heads" 2>/dev/null; then
    git for-each-ref "refs/remotes/$remote" \
        --format='%(refname:lstrip=3)%09%(objectname)%09%(if)%(symref)%(then)%(symref)%(else)-%(end)' \
        >"$tmp/tracking"
    stale=0
    while IFS=$'\t' read -r tname toid tsymref; do
        [ "$tsymref" = "-" ] || continue
        live_oid="$(awk -v r="refs/heads/$tname" '$2 == r { print $1; exit }' "$tmp/remote-heads")"
        if [ -z "$live_oid" ]; then
            printf '  stale  %s — deleted upstream; local tracking ref survives until a prune\n' "$tname"
            stale=$((stale + 1))
        elif [ "$live_oid" != "$toid" ]; then
            printf '  stale  %s — moved upstream (local tracking is behind or diverged)\n' "$tname"
            stale=$((stale + 1))
        fi
    done <"$tmp/tracking"
    if [ "$stale" -eq 0 ]; then
        echo "  fresh — local tracking refs match the remote's advertised heads"
    else
        echo "  -> $stale stale tracking ref(s): run 'task clean:remote-refs' (git fetch --prune), then re-run this audit"
    fi
else
    echo "  UNVERIFIED — could not read the remote's advertised heads; every section below trusts possibly-stale tracking refs"
fi

# ── 2. Gone-upstream classification ─────────────────────────────────────────

section "Branches whose upstream is gone"
awk -F'\t' '$3 == "[gone]" { print $1 "\t" $2 }' "$tmp/branches" >"$tmp/gone"
gone_count="$(wc -l <"$tmp/gone" | tr -d ' ')"
if [ "$gone_count" -eq 0 ]; then
    echo "  none"
else
    # One batched read of merged PRs, matched locally. Tip equality decides
    # "prunable" — a recycled branch name can match an old PR by name alone —
    # and so does the base: only a PR merged into the default branch proves
    # durable delivery, since a stacked base can be deleted with the merge
    # result in it (challenge r2).
    gh_repo=""
    if command -v gh >/dev/null 2>&1 && [ "$has_remote" = true ] && [ -n "$default_branch" ]; then
        gh_repo="$(net_probe gh repo view "$(git remote get-url "$remote")" \
            --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || gh_repo=""
    fi
    pr_limit="${AUDIT_PR_LIMIT:-1000}"
    if [ -n "$gh_repo" ] &&
        net_probe gh pr list --repo "$gh_repo" --state merged --limit "$pr_limit" \
            --json number,headRefName,headRefOid,baseRefName \
            --jq '.[] | [.headRefName, .headRefOid, (.number | tostring), .baseRefName] | @tsv' \
            >"$tmp/merged-prs" 2>/dev/null; then
        merged_seen="$(wc -l <"$tmp/merged-prs" | tr -d ' ')"
        if [ "$merged_seen" -ge "$pr_limit" ]; then
            echo "  (note: merged-PR listing hit its $pr_limit cap — 'no merged PR' below may be incomplete)"
        fi
        prunable=0
        tip_differs=0
        no_pr=0
        while IFS=$'\t' read -r branch tip; do
            match="$(awk -F'\t' -v b="$branch" -v tip="$tip" -v base="$default_branch" \
                '$1 == b && $2 == tip && $4 == base { print $3; exit }' "$tmp/merged-prs")"
            if [ -n "$match" ]; then
                printf '  prunable      %s — merged PR #%s into %s (head == tip %s)\n' "$branch" "$match" "$default_branch" "${tip:0:12}"
                prunable=$((prunable + 1))
            elif awk -F'\t' -v b="$branch" '$1 == b { found = 1; exit } END { exit !found }' "$tmp/merged-prs"; then
                printf '  tip differs   %s — a merged PR matches by name but not tip/base (a human decides)\n' "$branch"
                tip_differs=$((tip_differs + 1))
            else
                printf '  no merged PR  %s — abandoned or renamed (a human decides)\n' "$branch"
                no_pr=$((no_pr + 1))
            fi
        done <"$tmp/gone"
        printf '  -> %s prunable (task clean:branches), %s tip-differs, %s without a merged PR\n' \
            "$prunable" "$tip_differs" "$no_pr"
    else
        echo "  UNVERIFIED — gh unavailable or the merged-PR read failed; $gone_count gone branch(es) unclassified:"
        awk -F'\t' '{ print "    " $1 }' "$tmp/gone"
    fi
fi

# ── 3. Other worktrees ──────────────────────────────────────────────────────

section "Worktrees other than this one (reported only — no cleanup task touches these)"
this_tree="$(git rev-parse --show-toplevel)"
git worktree list --porcelain | awk -v self="$this_tree" '
    /^worktree /            { path = substr($0, 10) }
    /^branch refs\/heads\// { branch = substr($0, 19) }
    /^detached$/            { branch = "(detached)" }
    /^$/ {
        if (path != "" && path != self) { printf "  %s — %s\n", path, branch; found = 1 }
        path = ""; branch = "?"
    }
    END {
        if (path != "" && path != self) { printf "  %s — %s\n", path, branch; found = 1 }
        if (!found) print "  none"
    }
'

# ── 4. Review sidecars ──────────────────────────────────────────────────────

# The gauntlet stage keeps per-branch scratch state under the git directory
# (deliberately outside the worktree). Entries for branches that no longer
# exist are leftovers a finished PR should have deleted (§10 ritual).
section "Review sidecars (deferred-findings / adjudication-ledger)"
# Each entry is a single file whose repo-relative path IS the branch name
# (slashes in the branch nest directories), per the gauntlet skill's layout.
sidecars_found=false
for treename in deferred-findings adjudication-ledger; do
    dir="$(git rev-parse --git-path "$treename")"
    [ -d "$dir" ] || continue
    find "$dir" -type f 2>/dev/null >"$tmp/sidecar-list"
    [ -s "$tmp/sidecar-list" ] || continue
    sidecars_found=true
    while IFS= read -r f; do
        rel="${f#"$dir"/}"
        if git show-ref --verify --quiet "refs/heads/$rel"; then
            printf '  active    %s/%s (branch exists)\n' "$treename" "$rel"
        else
            printf '  leftover  %s/%s — no such branch; stale scratch state\n' "$treename" "$rel"
        fi
    done <"$tmp/sidecar-list"
done
[ "$sidecars_found" = true ] || echo "  none"

# ── 5. Shepherd cycle state ─────────────────────────────────────────────────

section "Shepherd Codex cycle-state files"
cycles_dir="$(git rev-parse --git-path shepherd-codex)"
if [ -d "$cycles_dir" ] && [ -n "$(find "$cycles_dir" -type f 2>/dev/null | head -n 1)" ]; then
    find "$cycles_dir" -type f 2>/dev/null | while IFS= read -r f; do
        printf '  %s\n' "${f#"$cycles_dir"/}"
    done
    echo "  (the shepherd checker's 'reap' subcommand sweeps states whose PR has closed)"
else
    echo "  none"
fi

# ── 6. Totals ───────────────────────────────────────────────────────────────

section "Totals"
echo "  $total_branches local branches ($gone_count with a gone upstream)"
echo "  Report only — nothing was mutated. Deletion lives in 'task clean:branches' (dry run by default)."
