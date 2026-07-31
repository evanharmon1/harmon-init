#!/usr/bin/env bash
# Turn a validated shared-image publication into one reviewed rolling pin PR.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="ghcr.io/evanharmon1/harmon-devcontainer"
ROOT_DOCKERFILE=".devcontainer/Dockerfile"
TEMPLATE_DOCKERFILE='template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile'
BASE_BRANCH="main"
SYNC_BRANCH="bot/sync-harmon-devcontainer"

BODY_FILE=""
cleanup() {
    [ -z "$BODY_FILE" ] || rm -f "$BODY_FILE"
}
trap cleanup EXIT

die() {
    echo "sync-devcontainer-image: $*" >&2
    exit 1
}

note() {
    echo "sync-devcontainer-image: $*"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

assert_sha() {
    case "${1:-}" in
    ????????????????????????????????????????)
        case "$1" in *[!0-9a-f]*) die "invalid source revision '$1'" ;; esac
        ;;
    *) die "invalid source revision '${1:-}'" ;;
    esac
}

assert_digest() {
    case "${1:-}" in
    sha256:????????????????????????????????????????????????????????????????)
        case "${1#sha256:}" in *[!0-9a-f]*) die "invalid manifest digest '$1'" ;; esac
        ;;
    *) die "invalid manifest digest '${1:-}'" ;;
    esac
}

reference() {
    assert_sha "$1"
    assert_digest "$2"
    printf '%s:sha-%s@%s\n' "$IMAGE" "$1" "$2"
}

read_pin() {
    _rp_file="$1"
    [ -f "$_rp_file" ] || die "consumer Dockerfile not found: $_rp_file"
    _rp_from="$(sed -n 's/^FROM[[:space:]][[:space:]]*//p' "$_rp_file")"
    _rp_count="$(grep -c '^FROM[[:space:]]' "$_rp_file" || true)"
    [ "$_rp_count" = 1 ] || die "expected exactly one FROM line in $_rp_file"
    case "$_rp_from" in
    "$IMAGE":sha-????????????????????????????????????????@sha256:????????????????????????????????????????????????????????????????)
        _rp_source="${_rp_from#*:sha-}"
        _rp_source="${_rp_source%%@*}"
        _rp_digest="${_rp_from##*@}"
        assert_sha "$_rp_source"
        assert_digest "$_rp_digest"
        printf '%s %s\n' "$_rp_source" "$_rp_digest"
        ;;
    *) return 3 ;;
    esac
}

cmd_pinned() {
    cmp -s "$ROOT_DOCKERFILE" "$TEMPLATE_DOCKERFILE" ||
        die "root/template consumer Dockerfiles differ"
    _cp_root_rc=0
    _cp_root="$(read_pin "$ROOT_DOCKERFILE")" || _cp_root_rc=$?
    _cp_template_rc=0
    _cp_template="$(read_pin "$TEMPLATE_DOCKERFILE")" || _cp_template_rc=$?
    if [ "$_cp_root_rc" -eq 3 ] && [ "$_cp_template_rc" -eq 3 ]; then
        return 3
    fi
    [ "$_cp_root_rc" -eq 0 ] || die "$ROOT_DOCKERFILE is not a valid thin consumer"
    [ "$_cp_template_rc" -eq 0 ] || die "$TEMPLATE_DOCKERFILE is not a valid thin consumer"
    [ "$_cp_root" = "$_cp_template" ] ||
        die "root/template consumer pins disagree: $_cp_root vs $_cp_template"
    printf '%s\n' "$_cp_root"
}

render_consumer() {
    _rc_ref="$1"
    cat <<EOF
FROM ${_rc_ref}

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
EOF
}

write_twins() {
    _wt_ref="$1"
    _wt_mode="${2:-update}"
    _wt_backup="$(mktemp -d)"
    cp "$ROOT_DOCKERFILE" "$_wt_backup/root"
    cp "$TEMPLATE_DOCKERFILE" "$_wt_backup/template"

    _wt_rc=0
    (
        _wt_done=0
        # shellcheck disable=SC2317 # Invoked indirectly by the trap below.
        restore_twins() {
            if [ "$_wt_done" -eq 0 ]; then
                cp "$_wt_backup/root" "$ROOT_DOCKERFILE"
                cp "$_wt_backup/template" "$TEMPLATE_DOCKERFILE"
            fi
            rm -f "${ROOT_DOCKERFILE}.tmp.$$" "${TEMPLATE_DOCKERFILE}.tmp.$$"
        }
        # Signal traps are resumable unless they terminate explicitly. Disable
        # all traps first, restore the pair once, and exit nonzero so execution
        # cannot continue with only the second mv after an interrupted first mv.
        # shellcheck disable=SC2317 # Invoked indirectly by the trap below.
        abort_twins() {
            trap - EXIT HUP INT TERM
            restore_twins
            exit 1
        }
        trap restore_twins EXIT
        trap abort_twins HUP INT TERM
        case "$_wt_mode" in
        bootstrap)
            render_consumer "$_wt_ref" >"${ROOT_DOCKERFILE}.tmp.$$"
            render_consumer "$_wt_ref" >"${TEMPLATE_DOCKERFILE}.tmp.$$"
            ;;
        update)
            sed "s|^FROM[[:space:]][[:space:]]*.*$|FROM ${_wt_ref}|" \
                "$ROOT_DOCKERFILE" >"${ROOT_DOCKERFILE}.tmp.$$"
            sed "s|^FROM[[:space:]][[:space:]]*.*$|FROM ${_wt_ref}|" \
                "$TEMPLATE_DOCKERFILE" >"${TEMPLATE_DOCKERFILE}.tmp.$$"
            ;;
        *) die "unknown twin-write mode '$_wt_mode'" ;;
        esac
        cmp -s "${ROOT_DOCKERFILE}.tmp.$$" "${TEMPLATE_DOCKERFILE}.tmp.$$" ||
            die "generated consumer twins differ"
        mv "${ROOT_DOCKERFILE}.tmp.$$" "$ROOT_DOCKERFILE"
        if [ "${SYNC_DEVCONTAINER_TEST_FAIL_AFTER_ROOT_WRITE:-}" = "true" ]; then
            die "injected failure after the first twin write"
        fi
        if [ "${SYNC_DEVCONTAINER_TEST_SIGNAL_AFTER_ROOT_WRITE:-}" = "true" ]; then
            kill -TERM "$BASHPID"
        fi
        mv "${TEMPLATE_DOCKERFILE}.tmp.$$" "$TEMPLATE_DOCKERFILE"
        _wt_done=1
    ) || _wt_rc=$?
    rm -rf "$_wt_backup"
    return "$_wt_rc"
}

validate_remote() {
    env -u GH_TOKEN -u GITHUB_TOKEN \
        ./scripts/publish-devcontainer-image.sh validate-index "$1" "$2" >/dev/null
}

cmd_bootstrap() {
    _cb_source="$1"
    _cb_digest="$2"
    [ -z "$(git status --porcelain -- "$ROOT_DOCKERFILE" "$TEMPLATE_DOCKERFILE")" ] ||
        die "bootstrap refuses uncommitted consumer Dockerfile edits"
    validate_remote "$_cb_source" "$_cb_digest"
    _cb_rc=0
    cmd_pinned >/dev/null || _cb_rc=$?
    [ "$_cb_rc" -eq 3 ] || die "bootstrap is only valid before thin consumers exist"
    write_twins "$(reference "$_cb_source" "$_cb_digest")" bootstrap
    note "bootstrapped root/template consumers at $_cb_source $_cb_digest"
}

cmd_apply() {
    _ca_source="$1"
    _ca_digest="$2"
    validate_remote "$_ca_source" "$_ca_digest"
    cmd_pinned >/dev/null || die "thin consumers are not bootstrapped; use the reviewed bootstrap migration"
    write_twins "$(reference "$_ca_source" "$_ca_digest")" update
    note "updated root/template consumers to $_ca_source $_ca_digest"
}

run_untrusted() {
    env -u GH_TOKEN -u GITHUB_TOKEN "$@"
}

changed_paths() {
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
}

assert_scope() {
    _as_bad=""
    while IFS= read -r _as_path; do
        [ -n "$_as_path" ] || continue
        case "$_as_path" in
        "$ROOT_DOCKERFILE" | "$TEMPLATE_DOCKERFILE") ;;
        *) _as_bad="${_as_bad}  - ${_as_path}\n" ;;
        esac
    done <<EOF
$(changed_paths)
EOF
    [ -z "$_as_bad" ] || {
        printf 'sync-devcontainer-image: unexpected changed paths:\n%b' "$_as_bad" >&2
        die "the pin sync may only update the two consumer Dockerfiles"
    }
}

configure_identity() {
    _ci_slug="${GH_APP_SLUG:-}"
    [ -n "$_ci_slug" ] || return 0
    case "$_ci_slug" in *[!a-zA-Z0-9-]*) die "unexpected GitHub App slug '$_ci_slug'" ;; esac
    _ci_uid="$(gh api "/users/${_ci_slug}[bot]" --jq '.id')" || die "cannot resolve App bot identity"
    case "$_ci_uid" in "" | *[!0-9]*) die "unexpected App bot id '$_ci_uid'" ;; esac
    git config user.name "${_ci_slug}[bot]"
    git config user.email "${_ci_uid}+${_ci_slug}[bot]@users.noreply.github.com"
}

git_remote() {
    if [ -n "${GH_TOKEN:-}" ]; then
        # shellcheck disable=SC2016
        git -c credential.helper= \
            -c credential.helper='!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f' \
            "$@"
    else
        git "$@"
    fi
}

assert_on_base() {
    [ "$(git branch --show-current)" = "$BASE_BRANCH" ] || die "run must start on $BASE_BRANCH"
    fetch_base
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")" ] ||
        die "local $BASE_BRANCH is not at origin/$BASE_BRANCH"
}

fetch_base() {
    git_remote fetch --quiet origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" ||
        die "cannot fetch origin/$BASE_BRANCH"
}

fetch_sync_branch() {
    git update-ref -d "refs/remotes/origin/$SYNC_BRANCH" 2>/dev/null || true
    _fs_rc=0
    git_remote ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1 || _fs_rc=$?
    case "$_fs_rc" in
    0)
        git_remote fetch --quiet origin "+refs/heads/$SYNC_BRANCH:refs/remotes/origin/$SYNC_BRANCH" ||
            die "cannot fetch $SYNC_BRANCH"
        ;;
    2) ;;
    *) die "cannot determine whether $SYNC_BRANCH exists" ;;
    esac
}

pin_pair_from_ref() {
    _pfr_ref="$1"
    _pfr_file="$(git show "${_pfr_ref}:${ROOT_DOCKERFILE}" 2>/dev/null)" || return 0
    _pfr_from="$(printf '%s\n' "$_pfr_file" | sed -n 's/^FROM[[:space:]][[:space:]]*//p')"
    case "$_pfr_from" in
    "$IMAGE":sha-????????????????????????????????????????@sha256:????????????????????????????????????????????????????????????????)
        _pfr_source="${_pfr_from#*:sha-}"
        _pfr_source="${_pfr_source%%@*}"
        _pfr_digest="${_pfr_from##*@}"
        assert_sha "$_pfr_source"
        assert_digest "$_pfr_digest"
        printf '%s %s\n' "$_pfr_source" "$_pfr_digest"
        ;;
    esac
}

pin_from_ref() {
    _pfr_pair="$(pin_pair_from_ref "$1")"
    printf '%s\n' "${_pfr_pair%% *}"
}

newer_floor() {
    _nf_left="$1"
    _nf_right="$2"
    [ -n "$_nf_right" ] || {
        printf '%s\n' "$_nf_left"
        return
    }
    assert_sha "$_nf_left"
    assert_sha "$_nf_right"
    if git merge-base --is-ancestor "$_nf_left" "$_nf_right"; then
        printf '%s\n' "$_nf_right"
    elif git merge-base --is-ancestor "$_nf_right" "$_nf_left"; then
        printf '%s\n' "$_nf_left"
    else
        die "consumer pins refer to unrelated source histories"
    fi
}

assert_monotonic() {
    _am_target="$1"
    _am_floor="$2"
    git merge-base --is-ancestor "$_am_target" "refs/remotes/origin/$BASE_BRANCH" ||
        die "target source $_am_target is not on origin/$BASE_BRANCH"
    [ "${SYNC_DEVCONTAINER_ALLOW_DOWNGRADE:-}" != "true" ] || return 0
    if [ "$_am_target" = "$_am_floor" ]; then
        return 0
    fi
    if git merge-base --is-ancestor "$_am_floor" "$_am_target"; then
        return 0
    fi
    if git merge-base --is-ancestor "$_am_target" "$_am_floor"; then
        die "refusing stale image source $_am_target; pin floor is newer at $_am_floor"
    fi
    die "target $_am_target and pin floor $_am_floor are unrelated"
}

open_pr_number() {
    gh pr list --head "$SYNC_BRANCH" --base "$BASE_BRANCH" --state open \
        --json number,isCrossRepository \
        --jq 'map(select(.isCrossRepository == false)) | .[0].number // empty'
}

write_body() {
    _wb_old="$1"
    _wb_source="$2"
    _wb_digest="$3"
    BODY_FILE="$(mktemp)"
    cat >"$BODY_FILE" <<EOF
Automated update of the immutable Harmon devcontainer toolchain image.

| | |
| --- | --- |
| previous source | \`${_wb_old}\` |
| new source | \`${_wb_source}\` |
| manifest digest | \`${_wb_digest}\` |
| image | \`${IMAGE}:sha-${_wb_source}@${_wb_digest}\` |

## What changed

- The root and template thin Dockerfiles now consume the newly published image.
- The public manifest was validated for linux/amd64 and linux/arm64 before this branch was written.

## Verification

\`task test:devcontainer:permissions\` and \`task verify\` passed before push.

## Merging

Merging stays manual. A newer publication rewrites this one rolling branch and PR.
EOF
}

open_or_update_pr() {
    _op_title="$1"
    _op_number="$2"
    if [ -n "$_op_number" ]; then
        gh pr edit "$_op_number" --title "$_op_title" --body-file "$BODY_FILE"
    else
        gh pr create --base "$BASE_BRANCH" --head "$SYNC_BRANCH" \
            --title "$_op_title" --body-file "$BODY_FILE"
    fi
}

cmd_prepare() {
    _run_source="$1"
    _run_digest="$2"
    need task
    validate_remote "$_run_source" "$_run_digest"
    [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
    assert_on_base

    _run_pin_rc=0
    _run_current="$(cmd_pinned)" || _run_pin_rc=$?
    if [ "$_run_pin_rc" -eq 3 ]; then
        note "first image is published and valid; thin consumers are not bootstrapped yet"
        note "open the reviewed consumer-migration PR with: $0 bootstrap $_run_source $_run_digest"
        return 0
    fi
    [ "$_run_pin_rc" -eq 0 ] || die "cannot read the current consumer pin"
    _run_current_source="${_run_current%% *}"

    fetch_sync_branch
    _run_branch_source="$(pin_from_ref "refs/remotes/origin/$SYNC_BRANCH")"
    _run_floor="$(newer_floor "$_run_current_source" "$_run_branch_source")"
    assert_monotonic "$_run_source" "$_run_floor"

    if [ "$_run_source $_run_digest" = "$_run_current" ]; then
        note "consumers already pin $_run_source $_run_digest"
        return 0
    fi

    git checkout -B "$SYNC_BRANCH" "$BASE_BRANCH" >/dev/null
    cmd_apply "$_run_source" "$_run_digest"
    assert_scope

    _run_title="fix(devcontainer): update shared image to ${_run_source%????????????????????????????????}"
    PR_TITLE="$_run_title" PR_BODY="" CHANGED_FILES="$(changed_paths)" \
        run_untrusted task guard:release-title

    git add "$ROOT_DOCKERFILE" "$TEMPLATE_DOCKERFILE"
    git commit -m "$_run_title" >/dev/null
    run_untrusted task test:devcontainer:permissions
    run_untrusted task verify

    note "prepared and verified $SYNC_BRANCH for $_run_source $_run_digest"
}

cmd_publish_prepared() {
    _pp_source="$1"
    _pp_digest="$2"
    need gh
    # Registry validation already completed in the unprivileged publish and
    # prepare jobs. This token-bearing phase deliberately performs only local
    # Git checks and the narrowly scoped GitHub writes below.
    [ -z "$(git status --porcelain)" ] || die "prepared working tree is not clean"

    _pp_branch="$(git branch --show-current)"
    if [ "$_pp_branch" = "$BASE_BRANCH" ]; then
        _pp_base_rc=0
        _pp_base="$(cmd_pinned)" || _pp_base_rc=$?
        if [ "$_pp_base_rc" -eq 3 ]; then
            note "thin consumers are not bootstrapped; there is no pin PR to publish"
            return 0
        fi
        [ "$_pp_base_rc" -eq 0 ] || die "cannot read the current consumer pin"
        [ "$_pp_base" = "$_pp_source $_pp_digest" ] ||
            die "no prepared pin update is present"
        note "consumers already pin $_pp_source $_pp_digest"
        return 0
    fi
    [ "$_pp_branch" = "$SYNC_BRANCH" ] || die "expected prepared branch $SYNC_BRANCH, found $_pp_branch"
    [ "$(cmd_pinned)" = "$_pp_source $_pp_digest" ] ||
        die "prepared branch does not pin the requested image"

    fetch_base
    fetch_sync_branch
    _pp_base="$(pin_pair_from_ref "refs/remotes/origin/$BASE_BRANCH")"
    [ -n "$_pp_base" ] || die "origin/$BASE_BRANCH has no valid thin-consumer pin"
    if [ "$_pp_base" = "$_pp_source $_pp_digest" ]; then
        note "origin/$BASE_BRANCH already pins $_pp_source $_pp_digest"
        return 0
    fi
    _pp_base_source="${_pp_base%% *}"
    _pp_branch_source="$(pin_from_ref "refs/remotes/origin/$SYNC_BRANCH")"
    _pp_floor="$(newer_floor "$_pp_base_source" "$_pp_branch_source")"
    assert_monotonic "$_pp_source" "$_pp_floor"

    _pp_title="fix(devcontainer): update shared image to ${_pp_source%????????????????????????????????}"
    _pp_pr="$(open_pr_number)"
    _pp_remote_ref="refs/remotes/origin/$SYNC_BRANCH"
    _pp_remote_oid="$(git rev-parse --verify "$_pp_remote_ref" 2>/dev/null || true)"
    if [ -n "$_pp_remote_oid" ] &&
        [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse "${_pp_remote_ref}^{tree}")" ]; then
        write_body "$_pp_base_source" "$_pp_source" "$_pp_digest"
        open_or_update_pr "$_pp_title" "$_pp_pr"
        note "rolling branch already carries this exact pin; repaired its PR metadata"
        return 0
    fi

    if [ -n "${GH_APP_SLUG:-}" ]; then
        configure_identity
        git commit --amend --no-edit --reset-author >/dev/null
    fi
    if [ -n "$_pp_remote_oid" ]; then
        _pp_lease="--force-with-lease=refs/heads/${SYNC_BRANCH}:${_pp_remote_oid}"
    else
        _pp_lease="--force-with-lease=refs/heads/${SYNC_BRANCH}:"
    fi
    git_remote push "$_pp_lease" origin "HEAD:refs/heads/$SYNC_BRANCH"
    write_body "$_pp_base_source" "$_pp_source" "$_pp_digest"
    open_or_update_pr "$_pp_title" "$_pp_pr"
    note "updated $SYNC_BRANCH; merging stays a human decision"
}

case "${1:-}" in
reference)
    [ "$#" -eq 3 ] || die "usage: $0 reference <source-sha> <manifest-digest>"
    reference "$2" "$3"
    ;;
pinned)
    [ "$#" -eq 1 ] || die "usage: $0 pinned"
    cmd_pinned
    ;;
bootstrap)
    [ "$#" -eq 3 ] || die "usage: $0 bootstrap <source-sha> <manifest-digest>"
    cmd_bootstrap "$2" "$3"
    ;;
apply)
    [ "$#" -eq 3 ] || die "usage: $0 apply <source-sha> <manifest-digest>"
    cmd_apply "$2" "$3"
    ;;
prepare)
    [ "$#" -eq 3 ] || die "usage: $0 prepare <source-sha> <manifest-digest>"
    cmd_prepare "$2" "$3"
    ;;
publish)
    [ "$#" -eq 3 ] || die "usage: $0 publish <source-sha> <manifest-digest>"
    cmd_publish_prepared "$2" "$3"
    ;;
*) die "usage: $0 {reference|pinned|bootstrap|apply|prepare|publish} ..." ;;
esac
