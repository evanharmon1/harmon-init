#!/usr/bin/env bash
# Build and smoke-test the canonical Harmon devcontainer image on the host
# architecture, then prove the current repository overlay installs on top.
set -euo pipefail
cd "$(dirname "$0")/.."

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "test-devcontainer-image: $1 is required" >&2
        exit 1
    }
}

need docker
need git

source_revision="${1:-$(git rev-parse HEAD)}"
case "$source_revision" in
????????????????????????????????????????)
    case "$source_revision" in *[!0-9a-f]*) exit 2 ;; esac
    ;;
*)
    echo "usage: $0 [40-character-source-revision]" >&2
    exit 2
    ;;
esac

case "$(docker info --format '{{.Architecture}}')" in
x86_64 | amd64) architecture=amd64 ;;
aarch64 | arm64) architecture=arm64 ;;
*)
    echo "test-devcontainer-image: unsupported Docker architecture" >&2
    exit 1
    ;;
esac

candidate="harmon-devcontainer-candidate:${source_revision}"
overlay="harmon-devcontainer-overlay-test:${source_revision}"

cleanup() {
    docker image rm --force "$overlay" "$candidate" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build --pull \
    --build-arg "IMAGE_REVISION=${source_revision}" \
    --tag "$candidate" \
    images/devcontainer

docker run --rm \
    --env "EXPECTED_REVISION=${source_revision}" \
    --env "EXPECTED_ARCHITECTURE=${architecture}" \
    "$candidate" \
    /usr/local/sbin/smoke.sh

docker build \
    --build-arg "BASE_IMAGE=${candidate}" \
    --file images/devcontainer/test-overlay.Dockerfile \
    --tag "$overlay" \
    .

# Run as vscode, which is what makes the terminfo assertion meaningful: the
# overlay compiles ghostty.terminfo as root, and Debian tic writes to
# /etc/terminfo only while it can — a regression that sent the entry to
# /root/.terminfo would still leave `tic` exiting 0 and the image building
# clean, while every Ghostty session in the container fell back to "unknown
# terminal type". Looking it up as the user who gets the shell is the check.
#
# The second lookup guards the entry's *content*, which resolution alone cannot:
# a refresh that dropped the dim branch from `sgr` would still compile and still
# resolve. It asserts the branch (`%p5` → `;2`), not the whole capability
# string, so an ordinary refresh does not have to update this test — and it is
# not a general staleness check, which cannot live in CI at all (no Ghostty on a
# Linux runner) and is tracked separately in #557.
docker run --rm "$overlay" sh -eu -c '
    [ "$(id -un)" = vscode ]
    [ -f /etc/claude-code/managed-settings.json ]
    [ -x /etc/claude-code/hooks/protect-files.sh ]
    [ -f /etc/codex/managed_config.toml ]
    [ -x /etc/codex/hooks/claude-compat.sh ]
    [ "$(yq ".model" /etc/codex/managed_config.toml)" = "gpt-5.6-sol" ]
    [ "$(yq ".sandbox_mode" /etc/codex/managed_config.toml)" = "workspace-write" ]
    ! grep -Eq "session-start-context|post-edit-format|enforce-conventional-commits" /etc/codex/managed_config.toml
    [ -f /etc/codex/managed_config.toml ]
    [ -x /etc/codex/hooks/claude-compat.sh ]
    [ "$(yq ".model" /etc/codex/managed_config.toml)" = "gpt-5.6-sol" ]
    [ "$(yq ".sandbox_mode" /etc/codex/managed_config.toml)" = "workspace-write" ]
    [ -f /home/vscode/.config/git/config ]
    [ -f /usr/local/share/devcontainer-config/claude-user-defaults.json ]
    infocmp -1 xterm-ghostty >/dev/null
    infocmp -1 xterm-ghostty | grep -q "sgr=.*%p5%t;2"
'

echo "test-devcontainer-image: candidate and repository overlay passed"
