#!/usr/bin/env bash
# Build, publish, and validate the canonical public multi-architecture image.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="ghcr.io/evanharmon1/harmon-devcontainer"
PUBLISH_WORKFLOW=".github/workflows/publish-harmon-devcontainer.yml"

die() {
    echo "publish-devcontainer-image: $*" >&2
    exit 1
}

note() {
    echo "publish-devcontainer-image: $*" >&2
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

image_ref() {
    assert_sha "$1"
    printf '%s:sha-%s\n' "$IMAGE" "$1"
}

inspect_manifest() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}'
}

# A credential-free config directory for anonymous registry operations. CLI
# plugins (buildx) are discovered through the config directory on per-user
# installs, so expose them via symlink — plugins are binaries, not credentials.
anon_config() {
    _ac_dir="$(mktemp -d)"
    _ac_plugins="${DOCKER_CONFIG:-${HOME}/.docker}/cli-plugins"
    [ -d "$_ac_plugins" ] && ln -s "$_ac_plugins" "$_ac_dir/cli-plugins"
    printf '%s\n' "$_ac_dir"
}

inspect_existing() {
    _ie_ref="$1"
    _ie_error="$(mktemp)"
    _ie_rc=0
    _ie_manifest="$(inspect_manifest "$_ie_ref" 2>"$_ie_error")" || _ie_rc=$?
    if [ "$_ie_rc" -eq 0 ]; then
        rm -f "$_ie_error"
        printf '%s\n' "$_ie_manifest"
        return 0
    fi

    _ie_message="$(cat "$_ie_error")"
    rm -f "$_ie_error"
    case "$_ie_message" in
    *"manifest unknown"* | *"MANIFEST_UNKNOWN"* | *"not found"*)
        return 3
        ;;
    *)
        printf '%s\n' "$_ie_message" >&2
        return 1
        ;;
    esac
}

validate_index() {
    _vi_source="$1"
    _vi_expected="$2"
    assert_sha "$_vi_source"
    assert_digest "$_vi_expected"
    _vi_ref="$(image_ref "$_vi_source")"
    _vi_config="$(anon_config)"
    _vi_manifest="$(DOCKER_CONFIG="$_vi_config" inspect_manifest "$_vi_ref")" || {
        rm -rf "$_vi_config"
        die "$_vi_ref is not anonymously inspectable"
    }
    rm -rf "$_vi_config"

    _vi_actual="$(printf '%s' "$_vi_manifest" | jq -r '.digest // empty')"
    [ "$_vi_actual" = "$_vi_expected" ] ||
        die "source tag resolves to $_vi_actual, expected $_vi_expected"
    for _vi_arch in amd64 arm64; do
        printf '%s' "$_vi_manifest" |
            jq -e --arg arch "$_vi_arch" \
                'any(.manifests[]?; .platform.os == "linux" and .platform.architecture == $arch)' \
                >/dev/null || die "manifest $_vi_expected has no linux/$_vi_arch image"
    done
    printf '%s\n' "$_vi_expected"
}

platform_child_digest() {
    _pc_index="$1"
    _pc_arch="$2"
    _pc_child="$(printf '%s' "$_pc_index" | jq -r --arg arch "$_pc_arch" \
        'first(.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest) // empty')"
    assert_digest "$_pc_child"
    printf '%s\n' "$_pc_child"
}

validate_public_image() {
    _vp_source="$1"
    _vp_digest="$2"
    validate_index "$_vp_source" "$_vp_digest" >/dev/null
    _vp_ref="$(image_ref "$_vp_source")@${_vp_digest}"
    _vp_config="$(anon_config)"
    _vp_index="$(DOCKER_CONFIG="$_vp_config" inspect_manifest "$_vp_ref")" || {
        rm -rf "$_vp_config"
        die "$_vp_ref is not anonymously inspectable"
    }
    rm -rf "$_vp_config"

    # Pull each platform by its unique child-manifest digest. Pulling both
    # platforms through the shared top-level reference makes the second pull
    # fail locally with "cannot overwrite digest" after Docker binds the first
    # platform's child to that reference — a client-side collision that is
    # indistinguishable from a registry denial in the exit status alone.
    _vp_amd64_child="$(platform_child_digest "$_vp_index" amd64)"
    _vp_arm64_child="$(platform_child_digest "$_vp_index" arm64)"
    [ "$_vp_amd64_child" != "$_vp_arm64_child" ] ||
        die "index $_vp_digest resolves amd64 and arm64 to one child digest $_vp_amd64_child"
    for _vp_arch in amd64 arm64; do
        if [ "$_vp_arch" = amd64 ]; then
            _vp_child_ref="${IMAGE}@${_vp_amd64_child}"
        else
            _vp_child_ref="${IMAGE}@${_vp_arm64_child}"
        fi
        _vp_config="$(anon_config)"
        if ! DOCKER_CONFIG="$_vp_config" docker pull --platform "linux/${_vp_arch}" "$_vp_child_ref" >/dev/null; then
            rm -rf "$_vp_config"
            die "anonymous linux/${_vp_arch} pull of $_vp_child_ref was refused by the registry or network (child-digest pulls cannot collide with a local reference)"
        fi
        rm -rf "$_vp_config"

        _vp_revision="$(docker image inspect "$_vp_child_ref" \
            --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
        [ "$_vp_revision" = "$_vp_source" ] ||
            die "published ${_vp_arch} label revision '$_vp_revision' does not match '$_vp_source'"
        docker run --rm --pull=never --platform "linux/${_vp_arch}" \
            --env "EXPECTED_REVISION=${_vp_source}" \
            --env "EXPECTED_ARCHITECTURE=${_vp_arch}" \
            "$_vp_child_ref" /usr/local/sbin/smoke.sh >/dev/null ||
            die "published ${_vp_arch} smoke check failed for $_vp_child_ref"
        docker image rm "$_vp_child_ref" >/dev/null 2>&1 || true
    done
    note "validated public amd64/arm64 image $_vp_ref"
}

resolve_source() {
    _rs_event="${1:-}"
    _rs_sha="${2:-}"
    if [ "$_rs_event" = "push" ]; then
        assert_sha "$_rs_sha"
        git cat-file -e "${_rs_sha}^{commit}" 2>/dev/null || die "source commit $_rs_sha is unavailable"
        _rs_head="$_rs_sha"
    else
        _rs_head="$(git rev-parse HEAD)"
        assert_sha "$_rs_head"
    fi
    # Push path filters operate over the whole pushed range, so github.sha can
    # be a later, unrelated commit in a multi-commit push. Resolve from the
    # event's immutable head using the same producer-path rule as scheduled
    # reconciliation; both event shapes must name the same image source.
    _rs_latest="$(git log -1 --format=%H "$_rs_head" -- \
        images/devcontainer scripts/publish-devcontainer-image.sh "$PUBLISH_WORKFLOW")"
    assert_sha "$_rs_latest"
    printf '%s\n' "$_rs_latest"
}

publish() {
    _pub_source="$1"
    assert_sha "$_pub_source"
    _pub_tag="$(image_ref "$_pub_source")"

    _pub_probe_rc=0
    _pub_existing="$(inspect_existing "$_pub_tag")" || _pub_probe_rc=$?
    if [ "$_pub_probe_rc" -eq 0 ]; then
        _pub_digest="$(printf '%s' "$_pub_existing" | jq -r '.digest // empty')"
        assert_digest "$_pub_digest"
        note "immutable tag already exists; validating without overwriting $_pub_tag"
    elif [ "$_pub_probe_rc" -eq 3 ]; then
        note "publishing $_pub_tag"
        docker buildx build \
            --pull \
            --platform linux/amd64,linux/arm64 \
            --build-arg "IMAGE_REVISION=${_pub_source}" \
            --provenance=true \
            --sbom=true \
            --tag "$_pub_tag" \
            --push \
            images/devcontainer
        _pub_manifest="$(inspect_manifest "$_pub_tag")" || die "published tag cannot be inspected"
        _pub_digest="$(printf '%s' "$_pub_manifest" | jq -r '.digest // empty')"
        assert_digest "$_pub_digest"
    else
        die "cannot determine whether immutable tag exists; refusing to publish $_pub_tag"
    fi

    validate_public_image "$_pub_source" "$_pub_digest"
    printf '%s\n' "$_pub_digest"
}

case "${1:-}" in
source)
    need git
    resolve_source "${2:-}" "${3:-}"
    ;;
reference)
    [ "$#" -eq 3 ] || die "usage: $0 reference <source-sha> <manifest-digest>"
    assert_digest "$3"
    printf '%s@%s\n' "$(image_ref "$2")" "$3"
    ;;
validate-index)
    need docker
    need jq
    [ "$#" -eq 3 ] || die "usage: $0 validate-index <source-sha> <manifest-digest>"
    validate_index "$2" "$3"
    ;;
validate)
    need docker
    need jq
    [ "$#" -eq 3 ] || die "usage: $0 validate <source-sha> <manifest-digest>"
    validate_public_image "$2" "$3"
    ;;
publish)
    need docker
    need jq
    [ "$#" -eq 2 ] || die "usage: $0 publish <source-sha>"
    publish "$2"
    ;;
*) die "usage: $0 {source|reference|validate-index|validate|publish} ..." ;;
esac
