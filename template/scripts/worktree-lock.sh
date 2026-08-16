#!/usr/bin/env bash
# worktree-lock.sh — the per-path lifecycle lock protocol SHARED by
# worktree-new.sh and worktree-rm.sh, which source this file. One
# implementation on purpose: both commands must run identical lock
# semantics, and a correction applied to one copy of a duplicated protocol
# is a divergence, not a fix. Requires the sourcing script to define die()
# and to run under set -euo pipefail.
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
lock_uid="$(id -u)"
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
    # The start stamp is recorded and compared under one pinned locale and
    # timezone: lstart renders via the locale's %c, so two invocations
    # differing in LC_TIME or TZ would otherwise disagree about the same
    # process and misread it as PID reuse.
    printf '%s %s %s %s\n' "$$" "$lock_host" "$lock_uid" \
        "$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')"
}
lock_owner_alive() {
    # $1 = recorded "pid host uid [start-time]". Anything unparseable, and
    # any owner from another host, is treated as alive: breaking is only
    # ever allowed on positive evidence of death.
    _own_pid="${1%% *}"
    _own_rest="${1#* }"
    _own_host="${_own_rest%% *}"
    _own_uid=""
    _own_start=""
    case "$_own_rest" in *" "*) _own_rest="${_own_rest#* }" ;; *) _own_rest="" ;; esac
    _own_uid="${_own_rest%% *}"
    case "$_own_rest" in *" "*) _own_start="${_own_rest#* }" ;; esac
    [ "$_own_host" = "$lock_host" ] || return 0
    case "$_own_pid" in "" | *[!0-9]*) return 0 ;; esac
    # Liveness is judged only for owners recorded with OUR OWN uid: no
    # hidepid-style restriction hides a user's processes from that same
    # user, so a same-uid absence is real death, while a foreign or
    # unrecorded uid can never be distinguished from permission filtering
    # and fails closed. ps is additionally probed against our own pid so a
    # sandbox denying ps entirely reads as indeterminate, not dead.
    [ "$_own_uid" = "$lock_uid" ] || return 0
    [ -n "$(ps -p $$ -o pid= 2>/dev/null)" ] || return 0
    [ -n "$(ps -p "$_own_pid" -o pid= 2>/dev/null)" ] || return 1
    if [ -n "$_own_start" ]; then
        _now_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$_own_pid" 2>/dev/null | sed 's/^ *//;s/ *$//')"
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
        # A break lock is swept only on the same evidence as any other
        # entry — a recorded owner proven dead, or ownerless AND aged — and
        # by RENAME-aside, never rm-by-pathname: a contender holding a
        # stale observation must not be able to delete the fresh break
        # mutex a live breaker re-created after the sweep (the same TOCTOU
        # the outer break closes the same way).
        _break_owner="$(cat "$_break/owner" 2>/dev/null || true)"
        _break_dead=0
        if [ -n "$_break_owner" ]; then
            lock_owner_alive "$_break_owner" || _break_dead=1
        elif [ -n "$(find "$_break" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            _break_dead=1
        fi
        if [ "$_break_dead" -eq 1 ] &&
            mv "$_break" "$lock_root/.deadbreak.$$" 2>/dev/null; then
            rm -rf "$lock_root/.deadbreak.$$"
        fi
        return 1
    fi
    lock_stamp >"$_break/owner"
    _break_now="$(cat "$1/owner" 2>/dev/null || true)"
    if [ "$_break_now" != "$2" ]; then
        rm -rf "$_break"
        return 1
    fi
    if [ -z "$2" ] && [ -z "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rm -rf "$_break"
        return 1
    fi
    if mv "$1" "$lock_root/.dead.$$" 2>/dev/null; then
        rm -rf "$lock_root/.dead.$$"
    fi
    rm -rf "$_break"
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
        # A very long nested name would exceed NAME_MAX as one flat lock
        # basename although every real path component is valid — and such a
        # worktree may already exist, so refusing would strand it. Long
        # encodings collapse to a checksum key; a (astronomically unlikely)
        # collision only over-serializes two names, never under-locks one.
        if [ "${#_lock_enc}" -gt 200 ]; then
            _lock_enc="h$(printf '%s' "$_lock_prefix" | cksum | tr ' \t' '--')"
        fi
        if [ -z "$_lock_rest" ]; then
            acquire_excl "$_lock_enc" "$_lock_prefix"
        else
            acquire_shared "$_lock_enc" "$_lock_prefix"
        fi
    done
}
