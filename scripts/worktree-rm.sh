#!/usr/bin/env bash
# worktree-rm.sh — remove a linked worktree created by worktree-new.sh and clear
# the gitlink debris a bare `git worktree remove` can leave behind.
#
# Run via `task worktree:rm -- <name> [--force]`.
#
# Refuses a dirty tree by default: uncommitted work in a worktree is invisible
# from the main checkout, so removing one silently is a data-loss path.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: task worktree:rm -- <name> [--force]

Removes .worktrees/<name>, clears that path's registry record, and deletes any
leftover gitlink directory. --force discards uncommitted changes in the tree.
Refuses when another registered worktree lives inside <name>.
EOF
}

die() {
    echo "worktree:rm: $*" >&2
    exit 1
}

# Refs that would STILL reference a commit once this worktree is gone.
#
# `refs/worktree/*`, `refs/bisect/*` and `refs/rewritten/*` are PER-WORKTREE:
# they live in the worktree's own administrative directory and are destroyed
# along with it, so counting them makes the reachability guard vouch for the
# very thing it is deciding about. Everything else — branches, tags,
# remote-tracking refs, notes, replace, stash — is shared and survives.
#
# They are excluded wholesale rather than per-owner because the query cannot
# tell whose per-worktree refs it is looking at: once a record is stale, its
# `refs/worktree/*` is unreadable from here, and the main worktree's own is
# indistinguishable in the output. Excluding all of them can only make the
# guard refuse a removal that was safe, which is the survivable direction.
shared_refs_containing() {
    git for-each-ref --contains "$1" --format='%(refname)' 2>/dev/null |
        grep -Ev '^refs/(worktree|bisect|rewritten)/' || true
}

# Locate the administrative directory backing the registry record for a
# worktree path. git exposes no porcelain for this mapping; each record's
# `gitdir` file holds the path of that worktree's `.git` file, which is the
# link back. Prints nothing and returns 1 when no record matches.
record_admin_dir() {
    admin_common="$(git rev-parse --path-format=absolute --git-common-dir)"
    [ -d "$admin_common/worktrees" ] || return 1
    for admin_candidate in "$admin_common"/worktrees/*; do
        [ -f "$admin_candidate/gitdir" ] || continue
        if [ "$(cat "$admin_candidate/gitdir" 2>/dev/null || true)" = "$1/.git" ]; then
            printf '%s\n' "$admin_candidate"
            return 0
        fi
    done
    return 1
}

name=""
force=0

while [ "$#" -gt 0 ]; do
    case "$1" in
    --force | -f)
        force=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        die "unknown option: $1"
        ;;
    *)
        [ -z "$name" ] || die "unexpected extra argument: $1"
        name="$1"
        shift
        ;;
    esac
done

[ -n "$name" ] || {
    usage
    die "a worktree name is required"
}

case "$name" in
/* | -*) die "invalid name '$name': must not start with '/' or '-'" ;;
*..*) die "invalid name '$name': must not contain '..'" ;;
esac
# The same character whitelist creation enforces. Removal used to get away
# without it, but lock entries are derived from the name, and a name
# carrying whitespace, glob characters, or the encoding characters would
# corrupt the lock bookkeeping (harmon-init#784) — and no conforming
# creation can have produced such a worktree anyway.
case "$name" in
*[!A-Za-z0-9._/-]*) die "invalid name '$name': use only A-Z a-z 0-9 . _ - /" ;;
esac
# The same component rule creation enforces, and for the same reason: every
# decision below compares `$tree` against git's CANONICAL registry paths as
# text. `./live` would miss the record for the live worktree at `live`, and the
# script would then classify a checked-out tree as debris and delete its
# gitlink. Equivalent spellings must not reach the comparisons at all.
case "/$name/" in
*//* | */./*) die "invalid name '$name': path components must not be empty or '.'" ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

main_root="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
[ -n "$main_root" ] && [ -d "$main_root" ] || die "could not resolve the main worktree root"

tree="$main_root/.worktrees/$name"

# ── Per-path lifecycle locks ─────────────────────────────────────────
# worktree:new and worktree:rm serialize per worktree path (harmon-init#839,
# #784): concurrent creations of `parent` and `parent/child` could otherwise
# both read the pre-creation registry, pass the ancestry checks, and
# register the nested layout those checks exist to refuse — and a removal's
# later steps could act on a worktree recreated at the same path mid-run.
#
# The protocol, shared by both scripts:
# - An operation on NAME holds every ancestor path SHARED and NAME itself
#   EXCLUSIVE. Ancestors are shared so sibling operations — feat/a and
#   feat/b both passing through feat — stay fully concurrent; an operation
#   ON an ancestor takes it exclusively and refuses while any live
#   descendant holds it, and vice versa.
# - Everything is TRY-acquired: contention refuses immediately rather than
#   queueing, so no deadlock is possible and no caller waits minutes to
#   then be refused at the registry.
# - A stale entry is broken by RENAMING it aside first — rename is atomic
#   and single-winner, so two breakers can never both "succeed" and then
#   delete each other's fresh lock.
# - Liveness is judged with ps(1) — `kill -0` reports EPERM for another
#   user's live process, which reads as dead — plus the recorded process
#   start time where ps can report it, so a reused PID does not keep a dead
#   owner's lock alive. Only owners recorded on THIS host are judged; a
#   foreign host's entry refuses with the remedy, never a guess. Residuals,
#   stated: two PID namespaces sharing one hostname over one checkout
#   cannot be told apart from here (default container hostnames differ,
#   which is the intended guard), and an acquirer SIGSTOPped for over a
#   minute inside the two-statement claim window can have its ownerless
#   lock broken as crashed.
# - Lock entries live in the COMMON git dir (shared across linked
#   worktrees; `--git-path` would resolve per-worktree). `/` in names is
#   encoded as `%` and entry suffixes use `+`; both characters are outside
#   the name charset both scripts enforce, so encodings cannot collide.
lock_root="$(git rev-parse --path-format=absolute --git-common-dir)/worktree-locks"
lock_host="$(hostname)"
held_excl=""
held_shared=""
release_locks() {
    if [ -n "$held_excl" ]; then
        rm -rf "$lock_root/$held_excl+lock"
        held_excl=""
    fi
    # The holders directory itself is deliberately never removed: an rmdir
    # here races a sibling's marker publication (mkdir -p sees the dir,
    # rmdir empties it away, the marker write then fails spuriously). An
    # empty holders dir is a few bytes of permanent bookkeeping; the
    # session-cleanup surface (#838) is where sweeping it belongs.
    for _held in $held_shared; do
        rm -f "$lock_root/$_held+holders/$$.marker"
    done
    held_shared=""
}
lock_stamp() {
    printf '%s %s %s\n' "$$" "$lock_host" \
        "$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')"
}
lock_owner_alive() {
    # $1 = recorded "pid host [start-time]". Anything unparseable, and any
    # owner from another host, is treated as alive: breaking is only ever
    # allowed on positive evidence of death.
    _own_pid="${1%% *}"
    _own_rest="${1#* }"
    _own_host="${_own_rest%% *}"
    _own_start=""
    case "$_own_rest" in *" "*) _own_start="${_own_rest#* }" ;; esac
    [ "$_own_host" = "$lock_host" ] || return 0
    case "$_own_pid" in "" | *[!0-9]*) return 0 ;; esac
    # ps is probed against OUR OWN pid first: a sandbox that denies ps
    # entirely would otherwise make every probe "fail", and a failed probe
    # must read as indeterminate (alive), never as proof of death.
    [ -n "$(ps -p $$ -o pid= 2>/dev/null)" ] || return 0
    [ -n "$(ps -p "$_own_pid" -o pid= 2>/dev/null)" ] || return 1
    if [ -n "$_own_start" ]; then
        _now_start="$(ps -o lstart= -p "$_own_pid" 2>/dev/null | sed 's/^ *//;s/ *$//')"
        if [ -n "$_now_start" ] && [ "$_now_start" != "$_own_start" ]; then
            return 1
        fi
    fi
    return 0
}
lock_try_break() {
    # $1 = lock dir, $2 = the owner content it was judged dead on. Breaking
    # is serialized under its own one-shot lock and REVALIDATED inside it:
    # without that, a second breaker still holding yesterday's judgement
    # can rename away the fresh lock the first breaker's successor just
    # acquired. Content equality is the validation — a re-acquired lock
    # carries a different stamp. An empty judgement additionally re-checks
    # age inside the break lock, so a just-created lock in its two-statement
    # claim window is never broken as "ownerless". Returns 0 only when this
    # caller performed the break.
    _break="$1+break"
    if ! mkdir "$_break" 2>/dev/null; then
        # A breaker died holding the break lock: ownerless and aged, sweep
        # it and let the next loop iteration retry.
        if [ -n "$(find "$_break" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rm -rf "$_break"
        fi
        return 1
    fi
    _break_now="$(cat "$1/owner" 2>/dev/null || true)"
    if [ "$_break_now" != "$2" ]; then
        rmdir "$_break" 2>/dev/null || true
        return 1
    fi
    if [ -z "$2" ] && [ -z "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$_break" 2>/dev/null || true
        return 1
    fi
    if mv "$1" "$lock_root/.dead.$$" 2>/dev/null; then
        rm -rf "$lock_root/.dead.$$"
    fi
    rmdir "$_break" 2>/dev/null || true
    return 0
}
acquire_excl() {
    # $1 = encoded path, $2 = display path
    _excl="$lock_root/$1+lock"
    _excl_tries=0
    while ! mkdir "$_excl" 2>/dev/null; do
        if [ ! -d "$_excl" ]; then
            die "cannot create lock $_excl — the lock name may exceed a filesystem limit; shorten the worktree name"
        fi
        _excl_owner="$(cat "$_excl/owner" 2>/dev/null || true)"
        _excl_tries=$((_excl_tries + 1))
        if [ "$_excl_tries" -le 2 ]; then
            if [ -n "$_excl_owner" ] && ! lock_owner_alive "$_excl_owner"; then
                lock_try_break "$_excl" "$_excl_owner" || true
                continue
            fi
            if [ -z "$_excl_owner" ] &&
                [ -n "$(find "$_excl" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
                lock_try_break "$_excl" "" || true
                continue
            fi
        fi
        die "another worktree operation holds '$2' (${_excl_owner:-owner not yet recorded}; lock $_excl) — if that process is gone, remove the lock directory and re-run"
    done
    lock_stamp >"$_excl/owner"
    held_excl="$1"
    # Exclusive also means: no live descendant operation may be holding
    # this path shared. Dead holders are pruned; a live one refuses (the
    # EXIT trap releases the exclusive lock just taken).
    for _marker in "$lock_root/$1+holders"/*; do
        [ -e "$_marker" ] || continue
        _marker_owner="$(cat "$_marker" 2>/dev/null || true)"
        # An empty marker is a holder killed inside its own two-statement
        # publication window — aged, it is swept like an ownerless lock;
        # fresh, it is a live publication and refuses below.
        if [ -z "$_marker_owner" ] &&
            [ -n "$(find "$_marker" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rm -f "$_marker"
            continue
        fi
        if lock_owner_alive "${_marker_owner:-0 unreadable}"; then
            die "a worktree operation under '$2/' is in progress (${_marker_owner:-holder unreadable}; $_marker) — if that process is gone, remove the marker file and re-run"
        fi
        rm -f "$_marker"
    done
}
acquire_shared() {
    # $1 = encoded path, $2 = display path. Marker first, exclusive-check
    # second — the exclusive side checks in the opposite order, so however
    # the two interleave at least one of them sees the other and refuses.
    mkdir -p "$lock_root/$1+holders" 2>/dev/null ||
        die "cannot create lock marker under $lock_root/$1+holders — the lock name may exceed a filesystem limit; shorten the worktree name"
    lock_stamp >"$lock_root/$1+holders/$$.marker"
    held_shared="$held_shared $1"
    _shared_excl="$lock_root/$1+lock"
    if [ -d "$_shared_excl" ]; then
        _shared_owner="$(cat "$_shared_excl/owner" 2>/dev/null || true)"
        if lock_owner_alive "${_shared_owner:-0 unreadable}"; then
            die "another worktree operation holds '$2' (${_shared_owner:-owner not yet recorded}; lock $_shared_excl) — if that process is gone, remove the lock directory and re-run"
        fi
        lock_try_break "$_shared_excl" "$_shared_owner" || true
    fi
}
acquire_path_locks() {
    _lock_rest="$1"
    _lock_prefix=""
    mkdir -p "$lock_root"
    while [ -n "$_lock_rest" ]; do
        _lock_seg="${_lock_rest%%/*}"
        case "$_lock_rest" in
        */*) _lock_rest="${_lock_rest#*/}" ;;
        *) _lock_rest="" ;;
        esac
        _lock_prefix="${_lock_prefix:+$_lock_prefix/}$_lock_seg"
        _lock_enc="$(printf '%s' "$_lock_prefix" | tr '/' '%')"
        if [ -z "$_lock_rest" ]; then
            acquire_excl "$_lock_enc" "$_lock_prefix"
        else
            acquire_shared "$_lock_enc" "$_lock_prefix"
        fi
    done
}
# The traps are armed BEFORE the first acquisition, so a signal or failure
# landing mid-acquisition still releases whatever partial set was taken.
# Held from before the entry snapshots to script exit, so no step of the
# removal ever acts on a worktree that appeared at this path after the
# command started.
trap release_locks EXIT
trap 'exit 129' HUP INT TERM
acquire_path_locks "$name"

# Liveness comes from the worktree REGISTRY, not from running git inside the
# directory: `git -C <dir> rev-parse` walks upward and happily finds the
# enclosing main repository, so an abandoned empty reservation from an
# interrupted create would read as a live worktree and `git worktree remove`
# would fail with "not a working tree" — leaving the path unrecoverable through
# the very command worktree:new tells you to run.
registered="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')"
tree_is_registered=0
case "
$registered
" in *"
$tree
"*) tree_is_registered=1 ;; esac

# Snapshot the shape of the target ONCE, at entry, and drive every branch below
# off that snapshot. The registry cleanup at the end used to re-derive "is
# anything registered here?" at the moment it ran, which answers yes for a
# worktree a CONCURRENT `worktree:new` created at the same name in between —
# and removing it is then somebody else's tree deleted while this run reports
# success. These entrypoints exist for parallel work, so the window is real.
tree_exists=0
[ -d "$tree" ] && tree_exists=1
# The only case the final cleanup is ever allowed to act on: a record that
# outlived its directory *at entry*. Everything else either had its record
# removed by git during the removal below, or never had one.
stale_record=0
if [ "$tree_is_registered" -eq 1 ] && [ "$tree_exists" -eq 0 ]; then
    stale_record=1
fi

# A worktree registered BELOW this path is a separate worktree, not this one's
# disposable contents. `git worktree remove --force` would delete its
# uncommitted work and the record cleanup below would drop its registry record,
# yet --force only ever promised to discard *this* tree's changes — so the
# refusal holds in both modes. `worktree:new` cannot create such a nesting; one
# predates this entrypoint or was made by hand, which is exactly why removal has
# to look for it rather than assume it away.
nested_found=0
while IFS= read -r registered_tree; do
    case "$registered_tree" in
    "$tree"/*) : ;;
    *) continue ;;
    esac
    if [ "$nested_found" -eq 0 ]; then
        echo "worktree:rm: $tree contains registered worktrees of its own:" >&2
        nested_found=1
    fi
    echo "  $registered_tree" >&2
done <<EOF
$registered
EOF
if [ "$nested_found" -eq 1 ]; then
    die "remove those first (task worktree:rm -- <name> for each) — they are separate worktrees, not this one's contents, and --force does not override this"
fi

if [ "$tree_exists" -eq 0 ]; then
    # A stale record is not automatically worthless. Its administrative
    # directory holds the HEAD the worktree was on, and when that HEAD is a
    # detached commit no shared ref contains, the record is the ONLY thing
    # keeping it alive — dropping it silently is the same data-loss path the
    # live branch below already refuses, just reached with the directory gone.
    # (`git worktree prune` lost it too; scoping the cleanup narrowed the blast
    # radius without giving this path the guard the live one has.)
    if [ "$force" -eq 0 ] && [ "$stale_record" -eq 1 ]; then
        stale_admin="$(record_admin_dir "$tree" || true)"
        if [ -n "$stale_admin" ] && [ -f "$stale_admin/HEAD" ]; then
            stale_head="$(cat "$stale_admin/HEAD" 2>/dev/null || true)"
            case "$stale_head" in
            ref:* | '') : ;; # attached to a branch: the branch keeps the commits
            *)
                if git rev-parse --quiet --verify "$stale_head^{commit}" >/dev/null 2>&1 &&
                    [ -z "$(shared_refs_containing "$stale_head")" ]; then
                    die "$tree is gone but its record still holds detached commit $stale_head, which no branch, tag or remote-tracking ref contains — branch or tag it ('git branch <name> $stale_head'), or re-run with --force to discard it"
                fi
                ;;
            esac
        fi
    fi
    echo "==> $tree does not exist; clearing its registry record anyway"
elif [ "$tree_is_registered" -eq 0 ]; then
    # The directory is not a registered worktree: either it outlived its record
    # (a stale gitlink) or it is an empty reservation an interrupted create left
    # behind. `git worktree remove` would only report "is not a working tree";
    # prune plus the debris sweep below is the actual fix for both.
    echo "==> $tree is not a live worktree (stale gitlink or abandoned reservation) — cleaning it up"
else
    if [ "$force" -eq 0 ] && [ -n "$(git -C "$tree" status --porcelain)" ]; then
        die "$tree has uncommitted changes — commit or push them, or re-run with --force to discard them"
    fi
    # An in-progress rebase/merge/cherry-pick leaves a CLEAN status once it
    # stops at an edit, so the check above waves it through — while the
    # per-worktree git dir still holds the sequencer state and, after a `commit
    # --amend` at that stop, a commit reachable from nothing else. Removing the
    # tree drops that state, and gc eventually collects the commit. Likewise a
    # detached HEAD ahead of every branch: nothing else references it.
    if [ "$force" -eq 0 ]; then
        tree_git_dir="$(git -C "$tree" rev-parse --path-format=absolute --git-dir)"
        for op_state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
            if [ -e "$tree_git_dir/$op_state" ]; then
                die "$tree has an in-progress git operation ($op_state) — finish or abort it, or re-run with --force to discard it"
            fi
        done
        # `for-each-ref`, not `branch --contains`: the latter lists the current
        # detached HEAD itself as a `(HEAD detached at ...)` pseudo-entry, so it
        # is never empty here and the guard would never fire.
        #
        # SHARED refs, which is wider than refs/heads and narrower than "all".
        # A tag or a remote-tracking ref keeps the commit just as reachable as a
        # branch does, so restricting to branches would refuse a perfectly safe
        # removal — pushing people toward --force for a tree that was never at
        # risk, which is how a guard stops being believed. But "all refs" counts
        # this worktree's own `refs/worktree/*`, which dies with it; see
        # shared_refs_containing.
        if ! git -C "$tree" symbolic-ref -q HEAD >/dev/null &&
            [ -z "$(shared_refs_containing "$(git -C "$tree" rev-parse HEAD)")" ]; then
            die "$tree is on a detached HEAD no branch contains — the commits there would become unreachable; branch or note them, or re-run with --force"
        fi
    fi
    # `git worktree remove` counts modified and untracked files, but NOT ignored
    # ones — so without this a plain remove silently deletes a `.env`, an
    # `.envrc.local`, or ignored notes, which is not what "--force to discard
    # uncommitted work" promises.
    #
    # The exemption is an ALLOWLIST of directories a tool can rebuild, not "any
    # ignored directory": a repo that gitignores `local-data/` or `fixtures/`
    # keeps its only copy there, and waving those through would be the same
    # data-loss path one level up. Everything not on the list — files and
    # directories alike — needs --force. The list is deliberately dull:
    # package-manager and build output, which `worktree:new`, `task install`, or
    # `task build` regenerate.
    #
    # Matching is per FILE, on whether any path component is a reinstallable
    # directory — `(^|/)name/` — rather than on collapsed directory entries.
    # `git ls-files --directory` collapses at the highest wholly-untracked
    # directory, so a monorepo's `packages/api/node_modules/...` arrives as
    # plain `packages/`, which no allowlist of cache names can recognise. Per
    # component it also handles depth for free: a `__pycache__` beside every
    # module, node_modules under every package.
    if [ "$force" -eq 0 ]; then
        reinstallable='(^|/)(node_modules|\.venv|venv|\.task|\.turbo|\.next|\.astro|\.nuxt|\.svelte-kit|\.parcel-cache|\.pytest_cache|\.mypy_cache|\.ruff_cache|__pycache__|dist|build|target|coverage|playwright-report|test-results|\.terraform)/'
        ignored_state="$(
            git -C "$tree" ls-files --others --ignored --exclude-standard |
                grep -Ev "$reinstallable" | head -n 20 || true
        )"
        if [ -n "$ignored_state" ]; then
            echo "worktree:rm: $tree holds ignored local state that removal would delete:" >&2
            printf '%s\n' "$ignored_state" | sed 's/^/  /' >&2
            die "move or copy it out, or re-run with --force to discard it"
        fi
    fi
    # Step out of the tree before deleting it. Finishing work inside the
    # worktree and removing it from there is the natural gesture, and it would
    # otherwise delete this process's own cwd — after which `git worktree prune`
    # below dies with "Unable to read current working directory" and the task
    # reports failure having already removed the tree.
    cd "$main_root" || die "could not change to $main_root"
    if [ "$force" -eq 1 ]; then
        git worktree remove --force "$tree"
    else
        git worktree remove "$tree"
    fi
fi

# Drop the registry record for THIS path when it outlived its directory. This is
# the #716 class: a stale record (or a leftover directory holding only a .git
# gitlink file) makes later tooling treat a dead path as a live checkout.
#
# Deliberately NOT `git worktree prune`: prune takes no path and is
# repository-WIDE, so removing one worktree would also drop every OTHER stale
# record — and such a record can be the only thing referencing a detached HEAD,
# which is precisely the metadata `worktree:new` now refuses to provision over.
# Removing one worktree must never reach into another's state.
#
# `git worktree remove` accepts a path whose directory is already gone and drops
# just that record, so it is the scoped form of the prune. It refuses a LOCKED
# record, which the check below turns into an actionable message rather than a
# false "removed".
#
# Gated on the ENTRY snapshot, not on "is anything registered here now". Only
# the stale-record branch above leaves a record for this step to clear: a live
# removal already dropped its own, and an unregistered path never had one. Re-
# deriving it here would let a concurrent `worktree:new` that claimed this name
# in the meantime have its brand-new worktree removed by this run. The
# directory is re-checked immediately before acting for the same reason — a
# recreated worktree has one, a genuinely stale record does not.
prune_err=""
if [ "$stale_record" -eq 1 ] && git worktree list --porcelain | grep -qxF "worktree $tree"; then
    if [ -d "$tree" ]; then
        die "$tree was recreated while this removal was running (another 'task worktree:new'?) — refusing to remove a worktree this run did not"
    fi
    prune_err="$(git worktree remove "$tree" 2>&1 >/dev/null)" || true
    if git worktree list --porcelain | grep -qxF "worktree $tree"; then
        # `remove --force` is NOT enough for a locked record — git answers a
        # single force with "use 'remove -f -f' to override or unlock first" —
        # so the instruction leads with the unlock, which is the path that also
        # works when the directory is already gone.
        die "$tree is still registered after cleanup (${prune_err:-git reported no reason}) — if its record is locked, run 'git worktree unlock \"$tree\"' then re-run, or force past the lock with 'git worktree remove -f -f \"$tree\"'"
    fi
fi

# `git worktree remove` leaves the directory in place when it failed or when the
# registry record was already gone. Clear it only when nothing but git's own
# gitlink remains, and only under .worktrees/ — never guess at a wider path.
#
# A `.git` DIRECTORY is not that: a linked worktree's gitlink is a FILE, so a
# directory there means a standalone repository or an interrupted clone lives at
# this path, and its `.git` holds the only copy of that repository's objects.
# Auto-cleaning the file shape is safe; the directory shape gets the same
# refusal as any other unexpected content.
if [ -d "$tree" ]; then
    leftovers="$(find "$tree" -mindepth 1 -maxdepth 1 ! -name .git | head -n 1)"
    if [ -z "$leftovers" ] && [ ! -d "$tree/.git" ]; then
        rm -rf "$tree"
        echo "==> Removed leftover gitlink directory $tree"
    elif [ -d "$tree/.git" ]; then
        die "$tree holds a .git DIRECTORY, so it is a repository of its own rather than worktree debris — inspect it and delete it by hand"
    else
        die "$tree still holds files after removal — inspect it and delete it by hand"
    fi
fi

# Empty leftovers are noise. A slash-delimited name like `feat/foo` leaves an
# empty `.worktrees/feat` behind, so walk up from the removed tree, stopping at
# .worktrees/ itself (which is also removed when it was the last tree). rmdir
# only ever removes an EMPTY directory, so this cannot take a live tree with it.
parent="$(dirname "$tree")"
while [ "$parent" != "$main_root" ] && [ "$parent" != "/" ]; do
    rmdir "$parent" 2>/dev/null || break
    parent="$(dirname "$parent")"
done

echo "Worktree removed: $tree"
