#!/usr/bin/env bash
# sync-devkit-release.sh — turn a published harmon-devkit release into a
# complete, verified harmon-init pin-and-sync PR.
#
# harmon-init vendors harmon-devkit's shared agent skills at a pinned tag
# (.skills-sync.yaml plus its template twin). Bumping that pin by hand is a
# six-step chore, and the two release-PR merges at either end are intentional
# human gates. Everything BETWEEN them is deterministic, so this helper does it:
#
#   resolve + validate a stable upstream release
#     -> rewrite BOTH pins
#     -> `task sync:skills`
#     -> assert the diff touched nothing but the expected paths
#     -> verify
#     -> commit, force-push the rolling bot branch, open/update exactly ONE PR
#
# It never merges anything, and it never writes the base branch. A validation,
# scope, or verification failure aborts BEFORE the push, so a broken sync can
# never surface as an open PR.
#
# Root-only: this is harmon-platform integration glue (the harmon-init <->
# harmon-devkit edge) and is deliberately NOT shipped to generated repos —
# there is no template/ twin. See docs/architecture/ci-cd.md.
#
# Usage:
#   sync-devkit-release.sh resolve [TAG]   # validate + print the tag to sync to
#   sync-devkit-release.sh pinned          # print the agreed current pin
#   sync-devkit-release.sh run [TAG]       # the whole pipeline
#
# TAG defaults to $SYNC_DEVKIT_TAG, then to the latest stable upstream release.
# Env: GH_APP_SLUG — when set, the bot commit identity is derived from the App.
#      SYNC_DEVKIT_ALLOW_DOWNGRADE=true — permit pinning an older release than
#      the current one (manual recovery only; the event path refuses it).
# Depends on: git, gh, task. Unit-tested by scripts/test-sync-devkit-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVKIT_REPO="evanharmon1/harmon-devkit"
ROOT_MANIFEST=".skills-sync.yaml"
TEMPLATE_MANIFEST='template/[% if use_skills_sync %].skills-sync.yaml[% endif %].jinja'
BASE_BRANCH="main"
# One deterministic branch -> one rolling PR. A newer release rewrites it
# instead of opening a second PR (see the force-push in cmd_run).
SYNC_BRANCH="bot/sync-harmon-devkit"

LF="
"

BODY_FILE=""
cleanup() {
    [ -n "$BODY_FILE" ] && rm -f "$BODY_FILE"
    return 0
}
trap cleanup EXIT

die() {
    echo "sync-devkit-release: $*" >&2
    exit 1
}

note() {
    echo "sync-devkit-release: $*"
}

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need_manifests() {
    [ -f "$ROOT_MANIFEST" ] || die "manifest '$ROOT_MANIFEST' not found"
    [ -f "$TEMPLATE_MANIFEST" ] || die "manifest '$TEMPLATE_MANIFEST' not found"
}

# ── Tag validation ────────────────────────────────────────────────────
# A dispatch payload is untrusted input, so the tag is checked for SHAPE before
# it is used anywhere and for EXISTENCE against the upstream API before it is
# believed. Deliberately pure shell: no pipe into grep, so there is no way for
# an embedded newline to satisfy a per-line anchored regex and slip through.
looks_like_tag() {
    case "${1:-}" in
    v*) ;;
    *) return 1 ;;
    esac
    _llt_rest="${1#v}"
    # Only digits and dots may follow the 'v'. This one gate also rejects
    # newlines, whitespace, and every shell metacharacter.
    case "$_llt_rest" in
    "" | *[!0-9.]* | .* | *.) return 1 ;;
    esac
    case "$_llt_rest" in
    *..*) return 1 ;;
    esac
    _llt_dots="${_llt_rest//[!.]/}"
    [ "${#_llt_dots}" -eq 2 ]
}

assert_tag_shape() {
    [ -n "${1:-}" ] || die "empty harmon-devkit tag"
    looks_like_tag "$1" ||
        die "refusing tag '$1' — expected a stable v<major>.<minor>.<patch> harmon-devkit tag"
}

# cmd_resolve [TAG] — echo the harmon-devkit tag to sync to, and NOTHING else
# on stdout: callers capture it.
cmd_resolve() {
    _cr_tag="${1:-}"
    if [ -z "$_cr_tag" ]; then
        _cr_tag="$(gh api "repos/$DEVKIT_REPO/releases/latest" --jq '.tag_name')" ||
            die "could not resolve the latest stable $DEVKIT_REPO release"
    fi
    assert_tag_shape "$_cr_tag"
    # Independent confirmation that the tag is a real, published, stable
    # release — never take the payload's word for it. GitHub's
    # get-release-by-tag already 404s on drafts; the explicit checks keep the
    # rejection loud rather than incidental.
    _cr_meta="$(gh api "repos/$DEVKIT_REPO/releases/tags/$_cr_tag" \
        --jq '[.tag_name, (.draft|tostring), (.prerelease|tostring)] | join(" ")')" ||
        die "no published $DEVKIT_REPO release found for tag '$_cr_tag'"
    _cr_name="" _cr_draft="" _cr_pre=""
    read -r _cr_name _cr_draft _cr_pre <<EOF
$_cr_meta
EOF
    [ "$_cr_name" = "$_cr_tag" ] ||
        die "upstream release for '$_cr_tag' reports tag_name '$_cr_name' — refusing"
    [ "$_cr_draft" = "false" ] || die "refusing tag '$_cr_tag' — it is a draft release"
    [ "$_cr_pre" = "false" ] || die "refusing tag '$_cr_tag' — it is a prerelease"
    printf '%s\n' "$_cr_tag"
}

# ── Manifests ─────────────────────────────────────────────────────────
# Read with sed rather than yq: the template twin is jinja (its `categories:`
# block is a `[% for %]` loop), so it is not parseable YAML until rendered.
manifest_field() {
    _mf_file="$1" _mf_key="$2"
    _mf_n="$(grep -c "^[[:space:]]*${_mf_key}:" "$_mf_file" || true)"
    [ "$_mf_n" = "1" ] ||
        die "expected exactly one '${_mf_key}:' line in $_mf_file (found $_mf_n)"
    sed -n "s/^[[:space:]]*${_mf_key}:[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p" "$_mf_file"
}

set_pin() {
    _sp_file="$1" _sp_tag="$2"
    _sp_n="$(grep -c '^[[:space:]]*ref:' "$_sp_file" || true)"
    [ "$_sp_n" = "1" ] || die "expected exactly one 'ref:' line in $_sp_file (found $_sp_n)"
    # In-place via a temp copy: BSD and GNU `sed -i` take different arguments.
    # The tag passed assert_tag_shape, so it holds no sed replacement
    # metacharacter (&, \, |).
    _sp_tmp="$(mktemp)"
    sed "s|^\\([[:space:]]*ref:[[:space:]]*\\)[^[:space:]#]*|\\1${_sp_tag}|" "$_sp_file" >"$_sp_tmp"
    cat "$_sp_tmp" >"$_sp_file"
    rm -f "$_sp_tmp"
}

# cmd_pinned — the tag both manifests agree on. Pre-existing disagreement is a
# human problem: bumping one side of an already-drifted pair would hide it.
cmd_pinned() {
    _cp_root="$(manifest_field "$ROOT_MANIFEST" ref)"
    _cp_tpl="$(manifest_field "$TEMPLATE_MANIFEST" ref)"
    [ "$_cp_root" = "$_cp_tpl" ] ||
        die "pin disagreement: $ROOT_MANIFEST pins '$_cp_root' but the template twin pins '$_cp_tpl' — reconcile by hand before automating a bump"
    printf '%s\n' "$_cp_root"
}

# prov_field PROV FIELD — a `# FIELD: …` provenance header value. Single awk
# process on purpose: a `sed | head` pipeline can raise SIGPIPE and, under
# `pipefail`, turn a successful read into a script-killing failure.
prov_field() {
    [ -f "$1" ] || return 0
    awk -v k="$2" 'index($0, "# " k ":") == 1 {
        sub("^# " k ":[[:space:]]*", ""); print; exit
    }' "$1"
}

prov_ref() {
    [ -f "$1" ] || return 0
    awk 'index($0, "# ref:") == 1 {
        sub(/^# ref:[[:space:]]*/, ""); sub(/[[:space:]]*\(.*/, ""); print; exit
    }' "$1"
}

# version_key TAG — a fixed-width, lexicographically comparable key. String
# comparison, never arithmetic: a zero-padded key would be read as octal by
# `[ -lt ]`. printf's %d parses each component as base 10, so a tag written
# v1.08.0 still keys correctly.
version_key() {
    _vk_rest="${1#v}"
    _vk_tail="${_vk_rest#*.}"
    printf '%05d%05d%05d\n' "${_vk_rest%%.*}" "${_vk_tail%%.*}" "${_vk_tail#*.}"
}

# assert_not_a_downgrade TARGET CURRENT — a dispatch can be delivered late or
# out of order, and `concurrency` serializes runs without ordering them, so an
# older tag can arrive after the pin has already advanced. Rolling the pin
# backwards would open a bogus rollback PR that the next scheduled run (which
# resolves the LATEST release) immediately flips back. Manual dispatch is a
# deliberate act, so it may still downgrade — that is the recovery path off a
# bad release.
assert_not_a_downgrade() {
    [ "${SYNC_DEVKIT_ALLOW_DOWNGRADE:-}" != "true" ] || return 0
    if [[ "$(version_key "$1")" < "$(version_key "$2")" ]]; then
        die "refusing to move the pin backwards ($2 -> $1) — replay a current release, or re-run the workflow manually with that tag to downgrade deliberately"
    fi
}

assert_safe_dest() {
    case "$1" in
    "" | "/" | "." | "..") die "refusing unsafe skills dest '$1'" ;;
    /*) die "refusing absolute skills dest '$1'" ;;
    ../* | */../* | */..) die "refusing skills dest with a '..' component: '$1'" ;;
    esac
}

# ── Diff scope ────────────────────────────────────────────────────────
# --no-renames so every change is exactly one path; -z so a path is never
# quoted or split (the template manifest's filename contains spaces).
changed_paths_z() {
    git diff --no-renames --name-only -z HEAD
    git ls-files --others --exclude-standard -z
}

changed_paths_nl() {
    git diff --no-renames --name-only HEAD
    git ls-files --others --exclude-standard
}

# assert_expected_scope DEST — fail closed unless every changed path is one of
# the two manifests, the provenance stamp, or a vendored skill the sync owns.
# The owned set is the UNION of the pre-sync (HEAD) and post-sync `# managed:`
# lines: a skill the new pin dropped appears only in the old list, one it added
# only in the new. Anything else — a local skill, an unrelated file — is an
# unexpected write and aborts the run before anything is committed or pushed.
assert_expected_scope() {
    _aes_dest="$1"
    _aes_prov="$_aes_dest/.SKILLS_PROVENANCE"
    _aes_allow="$(
        {
            git show "HEAD:$_aes_prov" 2>/dev/null || true
            cat "$_aes_prov" 2>/dev/null || true
        } | awk 'index($0, "# managed:") == 1 {
                sub(/^# managed:[[:space:]]*/, "")
                n = split($0, parts, ",")
                for (i = 1; i <= n; i++) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
                    if (parts[i] != "") print parts[i]
                }
            }'
    )"
    # Delimited membership test (no `grep` subprocess): a pipeline whose reader
    # exits early can report SIGPIPE under `pipefail` and reject a legitimate
    # path.
    _aes_haystack="${LF}${_aes_allow}${LF}"

    _aes_bad=""
    while IFS= read -r -d '' _aes_p; do
        [ -n "$_aes_p" ] || continue
        # Quoted case patterns are literal matches — essential for the template
        # manifest, whose name contains `[%`, a glob bracket expression.
        case "$_aes_p" in
        "$ROOT_MANIFEST" | "$TEMPLATE_MANIFEST" | "$_aes_prov") continue ;;
        esac
        _aes_ok=0
        case "$_aes_p" in
        "$_aes_dest"/*)
            _aes_name="${_aes_p#"$_aes_dest"/}"
            _aes_name="${_aes_name%%/*}"
            case "$_aes_haystack" in
            *"${LF}${_aes_name}${LF}"*) _aes_ok=1 ;;
            esac
            ;;
        esac
        [ "$_aes_ok" -eq 1 ] || _aes_bad="${_aes_bad}  - ${_aes_p}${LF}"
    done < <(changed_paths_z)

    if [ -n "$_aes_bad" ]; then
        echo "sync-devkit-release: the sync wrote paths it does not own:" >&2
        printf '%s' "$_aes_bad" >&2
        die "expected only the two skills-sync manifests, $_aes_prov, and managed skills under $_aes_dest/ — inspect by hand"
    fi
}

# ── Verification ──────────────────────────────────────────────────────
# run_untrusted CMD… — run a subprocess WITHOUT the repo-write App token.
#
# The sync clones another repository and the verification gate renders the
# copier template, running npx, uvx and rendered scripts. Those inherit this
# process's environment, so leaving GH_TOKEN in it would hand a
# contents:write + pull-requests:write credential to every one of them — the
# exact exposure the non-persisted push credential exists to avoid. Everything
# they reach is public (harmon-devkit, the npm and PyPI registries), so nothing
# here needs the token; only `gh` and the single `git push` do.
run_untrusted() {
    env -u GH_TOKEN -u GITHUB_TOKEN "$@"
}

# Cheapest first. `verify` is the repo's definition-of-done gate and already
# contains test:dogfood-parity, test:dogfood-structure and the whole
# test:template render matrix; verify:skills is the NETWORK drift check that
# `verify` deliberately leaves out (see the Taskfile's `ci` comment).
#
# security:secrets is here rather than left to the PR's own CI because this
# step vendors files from another repository and the next step PUBLISHES them:
# a credential that reached a harmon-devkit release would be in harmon-init's
# remote history — and need rotating — before any PR check could object.
run_verification() {
    for _rv_target in verify:skills:offline security:secrets verify:skills verify; do
        note "verifying: task $_rv_target"
        run_untrusted task "$_rv_target" ||
            die "verification failed at 'task $_rv_target' — nothing pushed, no PR touched"
    done
}

# preflight_title TITLE — the PR changes template/, so a non-releasing title
# would merge without cutting a tag and no downstream repo would ever receive
# the new skills. Run the same guard CI runs, before the branch is pushed.
preflight_title() {
    PR_TITLE="$1" PR_BODY="" CHANGED_FILES="$(changed_paths_nl)" \
        run_untrusted task guard:release-title ||
        die "PR title '$1' would not cut a release for a template/ change"
}

# configure_identity — commit as the CI GitHub App rather than as whatever the
# runner defaults to. A no-op when GH_APP_SLUG is unset (local runs, tests).
configure_identity() {
    _ci_slug="${GH_APP_SLUG:-}"
    [ -n "$_ci_slug" ] || return 0
    case "$_ci_slug" in
    *[!a-zA-Z0-9-]*) die "refusing unexpected GitHub App slug '$_ci_slug'" ;;
    esac
    _ci_uid="$(gh api "/users/${_ci_slug}[bot]" --jq '.id')" ||
        die "could not resolve the user id for '${_ci_slug}[bot]'"
    case "$_ci_uid" in
    "" | *[!0-9]*) die "unexpected user id '$_ci_uid' for '${_ci_slug}[bot]'" ;;
    esac
    git config user.name "${_ci_slug}[bot]"
    git config user.email "${_ci_uid}+${_ci_slug}[bot]@users.noreply.github.com"
}

write_pr_body() {
    _wb_old="$1" _wb_new="$2" _wb_prov="$3"
    BODY_FILE="$(mktemp)"
    cat >"$BODY_FILE" <<EOF
Automated pin-and-sync of the vendored harmon-devkit agent skills.

| | |
| --- | --- |
| previous pin | \`${_wb_old}\` |
| new pin | \`${_wb_new}\` |
| upstream release | https://github.com/${DEVKIT_REPO}/releases/tag/${_wb_new} |
| categories | $(prov_field "$_wb_prov" categories) |
| vendored skills | $(prov_field "$_wb_prov" managed) |

## What changed

- \`${ROOT_MANIFEST}\` and the template twin pin \`${_wb_new}\`.
- \`${_wb_prov}\` and the managed skill directories were re-vendored from that tag.

Nothing else — the run aborts if the sync writes a path it does not own.

## Verification

\`task verify:skills:offline\`, \`task security:secrets\`, \`task verify:skills\`
and \`task verify\` all passed on this commit before the branch was pushed, and
the releasing PR title was pre-flighted through \`task guard:release-title\`.

## Merging

**Merging stays manual.** This PR is opened by \`sync-harmon-devkit.yml\`; no
workflow merges it, and none merges either repository's release PR. A newer
stable harmon-devkit release rewrites this same branch rather than opening a
second PR.
EOF
}

# open_pr_number — the number of the open sync PR, or empty.
#
# `--head` filters by branch NAME only — gh cannot qualify it with an owner —
# so a fork PR whose head branch happens to be called $SYNC_BRANCH is returned
# too. Editing that would rewrite an unrelated contributor's PR with a
# trusted-looking `fix(template): …` title and leave the real sync PR unopened,
# so cross-repository heads are dropped. `// empty` matters as well: without it
# jq prints the string "null" and the caller would go on to edit PR "null".
open_pr_number() {
    _pn="$(gh pr list --head "$SYNC_BRANCH" --base "$BASE_BRANCH" --state open \
        --json number,isCrossRepository \
        --jq 'map(select(.isCrossRepository == false)) | .[0].number // empty')" ||
        die "could not list open PRs for $SYNC_BRANCH"
    case "$_pn" in
    *[!0-9]*) die "unexpected PR number '$_pn' for $SYNC_BRANCH" ;;
    esac
    printf '%s\n' "$_pn"
}

open_or_update_pr() {
    _pr_title="$1" _pr_existing="$2"
    if [ -n "$_pr_existing" ]; then
        note "updating the open sync PR #$_pr_existing"
        gh pr edit "$_pr_existing" --title "$_pr_title" --body-file "$BODY_FILE" ||
            die "could not update PR #$_pr_existing"
    else
        note "opening a sync PR"
        gh pr create --base "$BASE_BRANCH" --head "$SYNC_BRANCH" \
            --title "$_pr_title" --body-file "$BODY_FILE" ||
            die "could not open the sync PR"
    fi
}

# fetch_sync_branch — refresh refs/remotes/origin/$SYNC_BRANCH exactly once.
# The ref is dropped first so that after this it exists if and only if the
# branch exists upstream: `actions/checkout --fetch-depth 0` populates
# remote-tracking refs, and a branch deleted since then would otherwise be read
# as still present.
SYNC_BRANCH_FETCHED=0
fetch_sync_branch() {
    [ "$SYNC_BRANCH_FETCHED" -eq 0 ] || return 0
    SYNC_BRANCH_FETCHED=1
    git update-ref -d "refs/remotes/origin/$SYNC_BRANCH" 2>/dev/null || true
    # "the branch is not there" and "origin was unreachable" must not look the
    # same: both would leave the ref absent, and the second silently disarms
    # the guards that read it — the older-tag floor and the no-churn check —
    # so a transient blip could regress an open sync PR. ls-remote --exit-code
    # separates them: 0 = present, 2 = genuinely absent, anything else = error.
    _fsb_rc=0
    git_remote ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1 || _fsb_rc=$?
    case "$_fsb_rc" in
    0) ;;
    2) return 0 ;;
    *) die "could not reach origin to look for $SYNC_BRANCH (git exit $_fsb_rc) — refusing to proceed as if no sync PR were in flight" ;;
    esac
    git_remote fetch --quiet origin "+refs/heads/$SYNC_BRANCH:refs/remotes/origin/$SYNC_BRANCH" ||
        die "could not fetch $SYNC_BRANCH from origin"
    return 0
}

# remote_sync_tree — the tree the pushed sync branch already holds, or empty
# when the branch does not exist upstream. Trees, not commit SHAs: a rebuilt
# commit differs only by committer timestamp, so comparing SHAs would report a
# change on every run.
remote_sync_tree() {
    fetch_sync_branch
    git rev-parse --quiet --verify "refs/remotes/origin/$SYNC_BRANCH^{tree}" 2>/dev/null || return 0
}

# sync_branch_pin — the tag an already-pushed sync branch carries, or empty.
# The base branch alone is not enough to detect an out-of-order event: while a
# sync PR is open, the base pin stays stale, so a delayed older dispatch would
# look like a legitimate move forward and force the open PR backwards.
sync_branch_pin() {
    fetch_sync_branch
    _sbp_yaml="$(git show "refs/remotes/origin/$SYNC_BRANCH:$ROOT_MANIFEST" 2>/dev/null)" ||
        return 0
    awk '/^[[:space:]]*ref:/ {
        sub(/^[[:space:]]*ref:[[:space:]]*/, ""); sub(/[[:space:]#].*/, ""); print; exit
    }' <<EOF
$_sbp_yaml
EOF
}

# git_remote ARGS… — a git command that talks to origin, authenticated when a
# token is available.
#
# The token is deliberately not persisted into .git/config (the repo-wide
# `persist-credentials: false` hardening — see docs/architecture/security.md).
# `-c` config is scoped to this one git process and the helper reads the token
# from the environment, so it lands in neither argv nor any file, and no other
# process inherits it — the sync and verification subprocesses run with
# GH_TOKEN scrubbed (see run_untrusted). The empty first helper clears any
# inherited helper list so ours answers.
git_remote() {
    if [ -n "${GH_TOKEN:-}" ]; then
        # shellcheck disable=SC2016 # $GH_TOKEN must expand inside git's helper, not here
        git -c credential.helper= \
            -c credential.helper='!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f' \
            "$@"
    else
        # Local/manual run: rely on whatever credentials the operator's git has.
        git "$@"
    fi
}

push_sync_branch() {
    git_remote push --force origin "HEAD:refs/heads/$SYNC_BRANCH"
}

# assert_on_base — everything below reads the WORKING TREE, and the force-push
# publishes whatever the sync branch inherits from its start point, so the
# checkout must actually be the base branch and must match what origin holds.
# `actions/checkout` guarantees both in CI; locally this refuses to build the
# bot branch on a stale or ahead `main`, which would otherwise publish
# unrelated local commits under a bot title. The scope check cannot catch that:
# it inspects the working tree against HEAD, not HEAD against origin.
assert_on_base() {
    _aob_head="$(git rev-parse --abbrev-ref HEAD)"
    [ "$_aob_head" = "$BASE_BRANCH" ] ||
        die "HEAD is '$_aob_head', not '$BASE_BRANCH' — run the sync from the base branch"
    git_remote fetch --quiet origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" ||
        die "could not fetch origin/$BASE_BRANCH — cannot confirm the sync would start from the real base"
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")" ] ||
        die "local $BASE_BRANCH is not at origin/$BASE_BRANCH — fetch and reset first (a force-push would publish the difference)"
}

cmd_run() {
    _run_tag="${1:-${SYNC_DEVKIT_TAG:-}}"
    need_bin git
    need_bin gh
    need_bin task
    need_manifests
    [ -z "$(git status --porcelain)" ] ||
        die "working tree is not clean — refusing to build a sync commit on top of local changes"
    assert_on_base

    _run_target="$(cmd_resolve "$_run_tag")"
    _run_current="$(cmd_pinned)"
    _run_dest="$(manifest_field "$ROOT_MANIFEST" dest)"
    assert_safe_dest "$_run_dest"
    _run_prov="$_run_dest/.SKILLS_PROVENANCE"

    if [ "$_run_current" = "$_run_target" ] && [ "$(prov_ref "$_run_prov")" = "$_run_target" ]; then
        note "already pinned and vendored at $_run_target — nothing to do"
        return 0
    fi
    # Called as a bare statement so a failure aborts here: inside the command
    # substitutions below, `set -e` would not see it and the run would continue
    # with the guards silently disarmed.
    fetch_sync_branch
    # The floor is the newest tag already in flight: the base pin, or the open
    # sync branch's pin when it is ahead (the PR has not merged yet).
    _run_floor="$_run_current"
    _run_branch_pin="$(sync_branch_pin)"
    if looks_like_tag "$_run_branch_pin" &&
        [[ "$(version_key "$_run_floor")" < "$(version_key "$_run_branch_pin")" ]]; then
        _run_floor="$_run_branch_pin"
    fi
    assert_not_a_downgrade "$_run_target" "$_run_floor"
    note "syncing $_run_current -> $_run_target"

    configure_identity
    # Always branch from the base, never from whatever the branch held last
    # run: that is what makes a newer release deterministically supersede an
    # older open sync PR instead of stacking on top of it.
    git checkout -B "$SYNC_BRANCH" "$BASE_BRANCH" >/dev/null

    set_pin "$ROOT_MANIFEST" "$_run_target"
    set_pin "$TEMPLATE_MANIFEST" "$_run_target"
    run_untrusted task sync:skills ||
        die "'task sync:skills' failed at $_run_target — nothing pushed"
    assert_expected_scope "$_run_dest"

    _run_title="fix(template): sync harmon-devkit skills to $_run_target"
    preflight_title "$_run_title"

    git add -A
    if git diff --cached --quiet; then
        note "the sync produced no change — nothing to commit"
        return 0
    fi
    git commit -m "$_run_title" >/dev/null

    # The scheduled reconciliation fires while the sync PR is still open, and
    # the pins on the base branch stay stale until it merges — so every run
    # rebuilds the identical commit. Stop here when the pushed branch already
    # holds that tree AND its PR is open: pushing would churn the branch, reset
    # review state, and re-trigger the PR's CI daily for no change. Verification
    # is skipped too — this exact tree already passed it on the open PR.
    _run_open_pr="$(open_pr_number)"
    if [ -n "$_run_open_pr" ] && [ "$(remote_sync_tree)" = "$(git rev-parse 'HEAD^{tree}')" ]; then
        note "PR #$_run_open_pr already carries this exact sync at $_run_target — leaving it untouched"
        return 0
    fi

    run_verification

    # Force-push: this branch is owned solely by this workflow and is rebuilt
    # from the base every run, so its remote history is disposable by design.
    # Only $SYNC_BRANCH is ever written — never $BASE_BRANCH.
    note "pushing $SYNC_BRANCH"
    push_sync_branch || die "could not push $SYNC_BRANCH"

    write_pr_body "$_run_current" "$_run_target" "$_run_prov"
    open_or_update_pr "$_run_title" "$_run_open_pr"
    note "done — merging $SYNC_BRANCH stays a human decision"
}

case "${1:-}" in
resolve)
    need_bin gh
    cmd_resolve "${2:-${SYNC_DEVKIT_TAG:-}}"
    ;;
pinned)
    need_manifests
    cmd_pinned
    ;;
run) cmd_run "${2:-}" ;;
*)
    echo "usage: sync-devkit-release.sh {resolve|pinned|run} [TAG]" >&2
    exit 2
    ;;
esac
