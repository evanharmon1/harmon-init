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
legacy_overlay="harmon-devcontainer-legacy-overlay-test:${source_revision}"
legacy_context=""

cleanup() {
    docker image rm --force "$overlay" "$legacy_overlay" "$candidate" >/dev/null 2>&1 || true
    [ -n "$legacy_context" ] && rm -rf "$legacy_context"
    return 0
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
    [ -x /etc/claude-code/hooks/session-end-archive.sh ]
    # Every hook the managed settings REGISTER must resolve to an executable.
    # Reading the config rather than a hardcoded path is the point: a settings
    # entry naming a file the image never creates is inert, and silently so,
    # because these hooks are deliberately async and quiet (harmon-init#829 —
    # the hook was installed for a whole release without ever running). The
    # line above proves the installer placed a file; this proves the settings
    # point at one. The two are independent, and the second is what a session
    # actually executes.
    for cmd in $(jq -r ".hooks[][].hooks[].command" \
        /etc/claude-code/managed-settings.json | grep "^/" | sort -u); do
        [ -x "$cmd" ] || {
            echo "registered hook is not executable: $cmd" >&2
            exit 1
        }
    done
    # …and SessionEnd must be registered at its STAGED path specifically.
    # Checking for non-null is not enough: pointing it back at
    # /etc/claude-code/hooks/… would still pass here, because this candidate
    # image does install that copy — and would silently break the documented
    # one-line rollback the moment a consumer reverted to a pre-hook image.
    # Asserting the exact path is what guards that contract; the loop above
    # only proves whatever is registered resolves against THIS image.
    # Says why it failed — a bare test exits silently under `sh -eu`, leaving
    # the next reader to infer the cause from an exit code.
    [ "$(jq -r ".hooks.SessionEnd[0].hooks[0].command" \
        /etc/claude-code/managed-settings.json)" \
        = /usr/local/share/devcontainer-config/claude-hooks/session-end-archive.sh ] || {
        echo "SessionEnd must be registered at the staged hook path" >&2
        echo "  expected: /usr/local/share/devcontainer-config/claude-hooks/session-end-archive.sh" >&2
        echo "  an /etc/claude-code/… path breaks the one-line image rollback" >&2
        exit 1
    }
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

# LEGACY OVERLAY — the compatibility guarantee, retained.
#
# install-repo-config.sh installs some Claude hooks only when the consuming
# repository ships them, because ${config_dir} is that repository's config and
# repos generated from older templates do not have them. The overlay above
# cannot test that: it builds from this repo, where every optional hook is
# present, so it passes whether the guard works or not. Removing an `[ -f … ]`
# guard, or promoting an optional hook into required_files, would keep it green
# while the published image broke the devcontainer build of every repository
# that had not adopted the file yet.
#
# So build the overlay a second time against a config directory with the
# optional hooks stripped out. The build succeeding IS the assertion — the
# installer runs under `set -e`, so an unguarded install of a missing file
# fails here rather than in the fleet.
legacy_context="$(mktemp -d)"
mkdir -p "${legacy_context}/.devcontainer"
cp -R .devcontainer/config "${legacy_context}/.devcontainer/config"
rm -f "${legacy_context}/.devcontainer/config/claude-hooks/session-end-archive.sh"

docker build \
    --build-arg "BASE_IMAGE=${candidate}" \
    --file images/devcontainer/test-overlay.Dockerfile \
    --tag "$legacy_overlay" \
    "$legacy_context"

docker run --rm "$legacy_overlay" sh -eu -c '
    # The mandatory hooks still install …
    [ -x /etc/claude-code/hooks/protect-files.sh ]
    [ -f /etc/claude-code/managed-settings.json ]
    # … and the optional one is simply absent rather than a failed build.
    [ ! -e /etc/claude-code/hooks/session-end-archive.sh ]
'

echo "test-devcontainer-image: candidate, repository overlay, and legacy overlay passed"
