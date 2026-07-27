#!/usr/bin/env bash
# test-sync-devkit-release.sh — offline unit tests for sync-devkit-release.sh,
# the harmon-devkit release -> harmon-init pin-and-sync PR automation.
#
# Every case runs the REAL helper against a throwaway git repo (with a bare
# `origin` so pushes are observable) while `gh` and `task` are replaced by stubs
# on PATH. Nothing here touches the network, this repository, or GitHub.
#
# The stubs are deliberately thin: `task guard:release-title` delegates to the
# real guard, and `task sync:skills` simulates a vendoring run whose blast
# radius the fixture controls — so the scope check is exercised against real
# git state rather than a mock. Run via `task test:sync-devkit-release`.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

HELPER="scripts/sync-devkit-release.sh"
TEMPLATE_MANIFEST='template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja'
SYNC_BRANCH="bot/sync-harmon-devkit"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

cases=0
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# ── Fixture ───────────────────────────────────────────────────────────
# new_fixture NAME [PIN] [TEMPLATE_PIN] [PROVENANCE_PIN] — a repo pinned at PIN
# whose skills dir holds one vendored skill and one local skill the sync must
# never touch. TEMPLATE_PIN/PROVENANCE_PIN default to PIN; setting them apart
# models pre-existing drift. Echoes the fixture path.
new_fixture() {
    _nf_dir="$TMPROOT/$1"
    _nf_pin="${2:-v0.8.7}"
    _nf_tpl_pin="${3:-$_nf_pin}"
    _nf_prov_pin="${4:-$_nf_pin}"
    mkdir -p "$_nf_dir/scripts" "$_nf_dir/template" \
        "$_nf_dir/.claude/skills/standardize-repo" \
        "$_nf_dir/.claude/skills/local-only"

    cat >"$_nf_dir/$ROOT_MANIFEST_NAME" <<EOF
source:
  repo: https://github.com/evanharmon1/harmon-devkit.git
  # a comment line sits directly above the pin in the real manifests
  ref: $_nf_pin # pinned tag — bump deliberately to a released harmon-devkit tag
categories:
  - repo
dest: .claude/skills
EOF
    cat >"$_nf_dir/$TEMPLATE_MANIFEST" <<EOF
source:
  repo: https://github.com/evanharmon1/harmon-devkit.git
  # a comment line sits directly above the pin in the real manifests
  ref: $_nf_tpl_pin # pinned tag — bump deliberately to a released harmon-devkit tag
categories:
[% for cat in skill_categories %]
  - [[ cat ]]
[% endfor %]
dest: .claude/skills
EOF
    printf 'vendored at %s\n' "$_nf_pin" >"$_nf_dir/.claude/skills/standardize-repo/SKILL.md"
    printf 'a local skill the sync must never touch\n' >"$_nf_dir/.claude/skills/local-only/SKILL.md"
    cat >"$_nf_dir/.claude/skills/.SKILLS_PROVENANCE" <<EOF
# VENDORED from harmon-devkit — DO NOT EDIT the managed skills here.
# source: https://github.com/evanharmon1/harmon-devkit.git
# ref: $_nf_prov_pin (1111111111111111111111111111111111111111)
# path: ai/skills
# categories: repo
# managed: standardize-repo
EOF

    cp "$REPO_ROOT/$HELPER" "$_nf_dir/scripts/"
    cp "$REPO_ROOT/scripts/require-release-title.sh" "$_nf_dir/scripts/"

    git init --quiet --initial-branch=main "$_nf_dir"
    git -C "$_nf_dir" config user.name "fixture"
    git -C "$_nf_dir" config user.email "fixture@example.invalid"
    git -C "$_nf_dir" add -A
    git -C "$_nf_dir" commit --quiet -m "fixture"

    git init --quiet --bare "$_nf_dir.origin.git"
    git -C "$_nf_dir" remote add origin "$_nf_dir.origin.git"
    git -C "$_nf_dir" push --quiet origin main
    printf '%s\n' "$_nf_dir"
}
ROOT_MANIFEST_NAME=".skills-sync.yaml"

# ── Stubs ─────────────────────────────────────────────────────────────
# STUB_RELEASES lines are "<tag> <draft> <prerelease>"; a tag that is absent
# stands in for GitHub's 404. STUB_LATEST answers /releases/latest.
make_stubs() {
    _ms_bin="$TMPROOT/bin"
    mkdir -p "$_ms_bin"

    cat >"$_ms_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'gh %s\n' "$*" >>"$STUB_LOG"
case "${1:-}" in
api)
    path="${2:-}"
    case "$path" in
    */releases/latest)
        [ -n "${STUB_LATEST:-}" ] || exit 1
        printf '%s\n' "$STUB_LATEST"
        ;;
    */releases/tags/*)
        tag="${path##*/}"
        while read -r t draft pre; do
            [ "$t" = "$tag" ] || continue
            printf '%s %s %s\n' "$t" "$draft" "$pre"
            exit 0
        done <<EOF
${STUB_RELEASES:-}
EOF
        echo "stub gh: no release for $tag" >&2
        exit 1
        ;;
    /users/*)
        printf '%s\n' "${STUB_BOT_UID:-12345}"
        ;;
    *)
        echo "stub gh: unhandled api path $path" >&2
        exit 1
        ;;
    esac
    ;;
pr)
    case "${2:-}" in
    list)
        # Emulate `--json number,isCrossRepository --jq …` without depending on
        # a jq binary: STUB_PR_LIST lines are "<number> <isCrossRepository>".
        # The same-repo filter is applied only when the caller actually asked
        # for that field, so dropping the guard from the helper fails the test.
        want_same_repo=0
        case "$*" in *isCrossRepository*) want_same_repo=1 ;; esac
        while read -r num cross; do
            [ -n "$num" ] || continue
            if [ "$want_same_repo" = 1 ] && [ "$cross" = "true" ]; then
                continue
            fi
            printf '%s' "$num"
            exit 0
        done <<EOF
${STUB_PR_LIST:-}
EOF
        ;;
    create | edit) printf 'https://example.invalid/pr\n' ;;
    *)
        echo "stub gh: unhandled pr subcommand ${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
*)
    echo "stub gh: unhandled command ${1:-}" >&2
    exit 1
    ;;
esac
STUB

    cat >"$_ms_bin/task" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'task %s\n' "$*" >>"$STUB_LOG"
target="${1:-}"
case ",${STUB_FAIL_TASKS:-}," in
*",$target,"*)
    echo "stub task: $target failed on purpose" >&2
    exit 1
    ;;
esac
case "$target" in
guard:release-title)
    exec ./scripts/require-release-title.sh template
    ;;
sync:skills)
    ref=$(sed -n 's/^[[:space:]]*ref:[[:space:]]*\([^[:space:]#]*\).*/\1/p' .skills-sync.yaml)
    managed="standardize-repo"
    mkdir -p .claude/skills/standardize-repo
    printf 'vendored at %s\n' "$ref" >.claude/skills/standardize-repo/SKILL.md
    if [ -n "${STUB_SYNC_ADD_SKILL:-}" ]; then
        mkdir -p ".claude/skills/${STUB_SYNC_ADD_SKILL}"
        printf 'new skill at %s\n' "$ref" >".claude/skills/${STUB_SYNC_ADD_SKILL}/SKILL.md"
        managed="$managed, ${STUB_SYNC_ADD_SKILL}"
    fi
    if [ -n "${STUB_SYNC_DROP_SKILL:-}" ]; then
        rm -rf ".claude/skills/${STUB_SYNC_DROP_SKILL}"
        managed="standardize-repo"
    fi
    {
        echo "# VENDORED from harmon-devkit — DO NOT EDIT the managed skills here."
        echo "# source: https://github.com/evanharmon1/harmon-devkit.git"
        echo "# ref: $ref (2222222222222222222222222222222222222222)"
        echo "# path: ai/skills"
        echo "# categories: repo"
        echo "# managed: $managed"
    } >.claude/skills/.SKILLS_PROVENANCE
    [ -z "${STUB_SYNC_TOUCH_UNRELATED:-}" ] || echo "oops" >"${STUB_SYNC_TOUCH_UNRELATED}"
    [ -z "${STUB_SYNC_DELETE_LOCAL:-}" ] || rm -rf .claude/skills/local-only
    ;;
esac
exit 0
STUB

    chmod +x "$_ms_bin/gh" "$_ms_bin/task"
    printf '%s\n' "$_ms_bin"
}

STUB_BIN="$(make_stubs)"

# run_helper DIR ARGS... — invoke the helper in DIR with the stubs on PATH and
# the current STUB_* fixture settings. Echoes the exit code; combined output
# lands in $LAST_OUT. (Callers capture the echo, so run_helper runs in a
# subshell — $LAST_OUT is fixed here rather than assigned inside it.)
LAST_OUT="$TMPROOT/out"
run_helper() {
    _rh_dir="$1"
    shift
    _rh_rc=0
    (
        cd "$_rh_dir"
        PATH="$STUB_BIN:$PATH" \
            STUB_LOG="$STUB_LOG" \
            STUB_LATEST="${STUB_LATEST:-}" \
            STUB_RELEASES="${STUB_RELEASES:-}" \
            STUB_PR_LIST="${STUB_PR_LIST:-}" \
            STUB_BOT_UID="${STUB_BOT_UID:-12345}" \
            STUB_FAIL_TASKS="${STUB_FAIL_TASKS:-}" \
            STUB_SYNC_TOUCH_UNRELATED="${STUB_SYNC_TOUCH_UNRELATED:-}" \
            STUB_SYNC_DELETE_LOCAL="${STUB_SYNC_DELETE_LOCAL:-}" \
            STUB_SYNC_ADD_SKILL="${STUB_SYNC_ADD_SKILL:-}" \
            STUB_SYNC_DROP_SKILL="${STUB_SYNC_DROP_SKILL:-}" \
            GH_APP_SLUG="${GH_APP_SLUG:-}" \
            SYNC_DEVKIT_TAG="${SYNC_DEVKIT_TAG:-}" \
            SYNC_DEVKIT_ALLOW_DOWNGRADE="${SYNC_DEVKIT_ALLOW_DOWNGRADE:-}" \
            ./scripts/sync-devkit-release.sh "$@"
    ) >"$LAST_OUT" 2>&1 || _rh_rc=$?
    echo "$_rh_rc"
}

reset_stub_state() {
    STUB_LOG="$TMPROOT/log.$cases"
    : >"$STUB_LOG"
    STUB_LATEST=""
    STUB_RELEASES="v0.8.7 false false
v0.9.0 false false
v0.9.1 false false
v0.9.2-rc.1 false true
v1.0.0 true false"
    STUB_PR_LIST=""
    STUB_FAIL_TASKS=""
    STUB_SYNC_TOUCH_UNRELATED=""
    STUB_SYNC_DELETE_LOCAL=""
    STUB_SYNC_ADD_SKILL=""
    STUB_SYNC_DROP_SKILL=""
    GH_APP_SLUG=""
    SYNC_DEVKIT_TAG=""
    SYNC_DEVKIT_ALLOW_DOWNGRADE=""
}

# start NAME — begin a case; echoes a fresh fixture path.
start() {
    cases=$((cases + 1))
    reset_stub_state
    echo "==> $1"
}

logged() { grep -qF -- "$1" "$STUB_LOG"; }
# A PR was created or updated — as opposed to merely queried, which the
# no-churn check does before verification runs.
pr_written() { grep -qE '^gh pr (create|edit)' "$STUB_LOG"; }
pushed() { git -C "$1.origin.git" show-ref --verify --quiet "refs/heads/$SYNC_BRANCH"; }
pin_of() { sed -n 's/^[[:space:]]*ref:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$1"; }

# ── Cases ─────────────────────────────────────────────────────────────

start "a stable release payload produces one verified, pushed sync PR"
fix="$(new_fixture happy)"
main_before="$(git -C "$fix" rev-parse main)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "happy path exited $rc: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.9.0 ] || fail "root pin not updated"
[ "$(pin_of "$fix/$TEMPLATE_MANIFEST")" = v0.9.0 ] || fail "template pin not updated"
grep -q '^# ref: v0.9.0 ' "$fix/.claude/skills/.SKILLS_PROVENANCE" || fail "provenance not refreshed"
[ -f "$fix/.claude/skills/local-only/SKILL.md" ] || fail "local skill was disturbed"
pushed "$fix" || fail "sync branch was never pushed"
logged "gh pr create" || fail "no PR was opened"
logged "fix(template): sync harmon-devkit skills to v0.9.0" || fail "PR title is not releasing"
logged "task verify" || fail "verification never ran"
[ "$(git -C "$fix" rev-parse main)" = "$main_before" ] || fail "main was modified"
# The commit must contain exactly the expected paths.
changed="$(git -C "$fix" diff --no-renames --name-only main "$SYNC_BRANCH" | sort | tr '\n' '|')"
[ "$changed" = ".claude/skills/.SKILLS_PROVENANCE|.claude/skills/standardize-repo/SKILL.md|.skills-sync.yaml|template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja|" ] ||
    fail "unexpected commit contents: $changed"

start "an event replayed after the sync PR merged is a clean no-op"
fix="$(new_fixture replay_merged v0.9.0)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "replay exited $rc: $(cat "$LAST_OUT")"
grep -q "already pinned and vendored at v0.9.0" "$LAST_OUT" || fail "replay did not short-circuit"
! logged "gh pr" || fail "replay touched a PR"
! pushed "$fix" || fail "replay pushed a branch"

start "a re-run while the sync PR is open leaves the branch and PR untouched"
fix="$(new_fixture reconcile)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "first run exited $rc: $(cat "$LAST_OUT")"
pushed_before="$(git -C "$fix.origin.git" rev-parse "$SYNC_BRANCH")"
# A fresh CI checkout always starts on the base branch; the pins there stay
# stale until the PR merges, so the daily reconciliation rebuilds this same
# commit. It must not force-push it again.
git -C "$fix" checkout --quiet main
STUB_PR_LIST="42 false"
: >"$STUB_LOG"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "reconciliation run exited $rc: $(cat "$LAST_OUT")"
grep -q "already carries this exact sync" "$LAST_OUT" || fail "reconciliation did not short-circuit"
[ "$(git -C "$fix.origin.git" rev-parse "$SYNC_BRANCH")" = "$pushed_before" ] ||
    fail "reconciliation force-pushed an identical tree"
! logged "gh pr edit" || fail "reconciliation churned the open PR"
! logged "task verify" || fail "reconciliation re-ran the expensive verification"

start "a re-run with no open PR re-opens one from the pushed branch"
fix="$(new_fixture reopen)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "first run exited $rc: $(cat "$LAST_OUT")"
git -C "$fix" checkout --quiet main
STUB_PR_LIST=""
: >"$STUB_LOG"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "re-open run exited $rc: $(cat "$LAST_OUT")"
logged "gh pr create" || fail "a closed/missing PR was not re-opened"

start "an already-pinned tag whose provenance is stale still re-syncs"
fix="$(new_fixture stale_prov v0.9.0 v0.9.0 v0.8.7)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "stale-provenance run exited $rc: $(cat "$LAST_OUT")"
logged "gh pr create" || fail "stale provenance did not produce a PR"

start "an open sync PR is updated, never duplicated"
fix="$(new_fixture existing_pr)"
STUB_PR_LIST="42 false"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "existing-PR run exited $rc: $(cat "$LAST_OUT")"
logged "gh pr edit 42" || fail "the open PR was not updated"
! logged "gh pr create" || fail "a duplicate PR was created"

start "a fork PR sharing the bot branch name is never mistaken for the sync PR"
fix="$(new_fixture fork_pr)"
# gh's --head filters by branch NAME only, so an untrusted fork PR whose head
# branch is called bot/sync-harmon-devkit shows up in the same listing.
STUB_PR_LIST="9001 true"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "fork-PR run exited $rc: $(cat "$LAST_OUT")"
! logged "gh pr edit 9001" || fail "the automation rewrote an unrelated fork PR"
logged "gh pr create" || fail "the real sync PR was not opened"

start "a stale or out-of-order release event cannot roll the pin backwards"
fix="$(new_fixture downgrade v0.9.1)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "a downgrade was accepted on the event path"
grep -q "backwards" "$LAST_OUT" || fail "downgrade rejection was not reported: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.9.1 ] || fail "a refused downgrade still moved the pin"
! pushed "$fix" || fail "a refused downgrade still pushed"
# Manual dispatch is deliberate, so it may downgrade — the recovery path.
SYNC_DEVKIT_ALLOW_DOWNGRADE="true"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "a deliberate manual downgrade was refused: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.9.0 ] || fail "the manual downgrade did not move the pin"

start "a newer release supersedes an open sync PR from one commit off main"
fix="$(new_fixture supersede)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "first sync exited $rc: $(cat "$LAST_OUT")"
git -C "$fix" checkout --quiet main
STUB_PR_LIST="7 false"
: >"$STUB_LOG"
rc="$(run_helper "$fix" run v0.9.1)"
[ "$rc" = 0 ] || fail "superseding sync exited $rc: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.9.1 ] || fail "pin not moved to the newer release"
logged "gh pr edit 7" || fail "the open PR was not retargeted at the newer release"
depth="$(git -C "$fix" rev-list --count "main..$SYNC_BRANCH")"
[ "$depth" = 1 ] || fail "sync branch stacked $depth commits instead of rebuilding from main"

start "no tag given resolves the latest stable release"
fix="$(new_fixture latest)"
STUB_LATEST="v0.9.1"
rc="$(run_helper "$fix" run)"
[ "$rc" = 0 ] || fail "latest-resolution run exited $rc: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.9.1 ] || fail "latest release was not pinned"

start "SYNC_DEVKIT_TAG supplies the tag when no argument is given"
fix="$(new_fixture env_tag)"
SYNC_DEVKIT_TAG="v0.9.0"
rc="$(run_helper "$fix" run)"
[ "$rc" = 0 ] || fail "env-tag run exited $rc: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.9.0 ] || fail "SYNC_DEVKIT_TAG was ignored"

start "malformed and metacharacter-bearing tags are rejected before any write"
fix="$(new_fixture bad_tags)"
for bad in "v1.2" "1.2.3" "v1.2.3.4" "v1.2.3-rc.1" "v1.2.3; rm -rf /" 'v1.2.3 && touch pwned' \
    "v1.2.3$(printf '\n')v0.9.0" "v" "vv1.2.3" "" "../../etc/passwd"; do
    rc="$(run_helper "$fix" run "$bad")"
    [ "$rc" != 0 ] || fail "tag '$bad' was accepted"
done
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.8.7 ] || fail "a rejected tag still moved the pin"
[ ! -e "$fix/pwned" ] || fail "a metacharacter payload reached a shell"
! pushed "$fix" || fail "a rejected tag still pushed a branch"
! logged "gh pr" || fail "a rejected tag still touched a PR"

start "draft, prerelease, and unknown releases are rejected"
fix="$(new_fixture bad_releases)"
rc="$(run_helper "$fix" run v1.0.0)"
[ "$rc" != 0 ] || fail "a draft release was accepted"
grep -q "draft release" "$LAST_OUT" || fail "draft rejection was not reported: $(cat "$LAST_OUT")"
rc="$(run_helper "$fix" run v0.9.2-rc.1)"
[ "$rc" != 0 ] || fail "a prerelease tag was accepted"
rc="$(run_helper "$fix" run v9.9.9)"
[ "$rc" != 0 ] || fail "an unpublished tag was accepted"
grep -q "no published" "$LAST_OUT" || fail "missing-release rejection was not reported"
! pushed "$fix" || fail "a rejected release still pushed a branch"

start "a prerelease that passes the shape gate is still refused"
fix="$(new_fixture prerelease_shaped)"
STUB_RELEASES="v0.9.0 false true"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "a well-shaped prerelease was accepted"
grep -q "prerelease" "$LAST_OUT" || fail "prerelease rejection was not reported"

start "root/template pin disagreement fails loudly before anything is written"
fix="$(new_fixture drift v0.8.7 v0.8.5)"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "pre-existing pin drift was not detected"
grep -q "pin disagreement" "$LAST_OUT" || fail "drift rejection was not reported: $(cat "$LAST_OUT")"
[ "$(pin_of "$fix/.skills-sync.yaml")" = v0.8.7 ] || fail "drifted repo was still modified"
! pushed "$fix" || fail "drifted repo still pushed a branch"

start "a sync that writes an unrelated path fails closed"
fix="$(new_fixture scope_extra)"
STUB_SYNC_TOUCH_UNRELATED="README.md"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "an out-of-scope write was accepted"
grep -q "paths it does not own" "$LAST_OUT" || fail "scope rejection was not reported: $(cat "$LAST_OUT")"
! pushed "$fix" || fail "an out-of-scope sync still pushed"
! logged "gh pr" || fail "an out-of-scope sync still touched a PR"

start "a sync that deletes a local skill fails closed"
fix="$(new_fixture scope_delete)"
STUB_SYNC_DELETE_LOCAL="1"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "deleting a local skill was accepted"
grep -q "local-only" "$LAST_OUT" || fail "the deleted local skill was not named: $(cat "$LAST_OUT")"
! pushed "$fix" || fail "a local-skill deletion still pushed"

start "a skill the new pin adds or drops stays in scope"
fix="$(new_fixture scope_managed)"
STUB_SYNC_ADD_SKILL="new-repo-skill"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "adding a managed skill was rejected: $(cat "$LAST_OUT")"
fix="$(new_fixture scope_dropped)"
STUB_SYNC_ADD_SKILL=""
STUB_SYNC_DROP_SKILL="standardize-repo"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "dropping a previously managed skill was rejected: $(cat "$LAST_OUT")"

start "a failing sync never pushes or opens a PR"
fix="$(new_fixture sync_fail)"
STUB_FAIL_TASKS="sync:skills"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "a failing sync:skills was ignored"
! pushed "$fix" || fail "a failing sync still pushed"
! logged "gh pr" || fail "a failing sync still touched a PR"

start "a failing verification never pushes or opens a PR"
for failing in verify:skills:offline verify:skills verify; do
    fix="$(new_fixture "verify_fail_${failing//:/_}")"
    STUB_FAIL_TASKS="$failing"
    rc="$(run_helper "$fix" run v0.9.0)"
    [ "$rc" != 0 ] || fail "a failing '$failing' was ignored"
    grep -q "verification failed at 'task $failing'" "$LAST_OUT" ||
        fail "'$failing' failure was not reported: $(cat "$LAST_OUT")"
    ! pushed "$fix" || fail "a failing '$failing' still pushed"
    ! pr_written || fail "a failing '$failing' still created or updated a PR"
    # The commit exists locally but main is untouched and nothing left the host.
    [ "$(git -C "$fix" rev-parse main)" = "$(git -C "$fix.origin.git" rev-parse main)" ] ||
        fail "main diverged from origin after a failed '$failing'"
done

start "a dirty working tree is refused"
fix="$(new_fixture dirty)"
echo "local edit" >>"$fix/.skills-sync.yaml"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "a dirty tree was accepted"
grep -q "working tree is not clean" "$LAST_OUT" || fail "dirty-tree rejection was not reported"

start "the bot identity comes from the GitHub App slug"
fix="$(new_fixture identity)"
GH_APP_SLUG="evanharmon1-ci"
STUB_BOT_UID="987654"
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" = 0 ] || fail "identity run exited $rc: $(cat "$LAST_OUT")"
author="$(git -C "$fix" log -1 --format='%an <%ae>' "$SYNC_BRANCH")"
[ "$author" = "evanharmon1-ci[bot] <987654+evanharmon1-ci[bot]@users.noreply.github.com>" ] ||
    fail "unexpected commit author: $author"

start "a bogus App slug is refused before it reaches git config"
fix="$(new_fixture bad_slug)"
GH_APP_SLUG='evil; touch pwned'
rc="$(run_helper "$fix" run v0.9.0)"
[ "$rc" != 0 ] || fail "a bogus App slug was accepted"
[ ! -e "$fix/pwned" ] || fail "an App slug payload reached a shell"

start "resolve and pinned are usable on their own"
fix="$(new_fixture subcommands)"
rc="$(run_helper "$fix" resolve v0.9.1)"
[ "$rc" = 0 ] || fail "resolve exited $rc: $(cat "$LAST_OUT")"
[ "$(cat "$LAST_OUT")" = "v0.9.1" ] || fail "resolve printed more than the tag: $(cat "$LAST_OUT")"
rc="$(run_helper "$fix" pinned)"
[ "$rc" = 0 ] || fail "pinned exited $rc: $(cat "$LAST_OUT")"
[ "$(cat "$LAST_OUT")" = "v0.8.7" ] || fail "pinned printed '$(cat "$LAST_OUT")'"
rc="$(run_helper "$fix" bogus)"
[ "$rc" = 2 ] || fail "an unknown subcommand should be a usage error (got $rc)"

echo "sync-devkit-release: all ${cases} cases passed"
