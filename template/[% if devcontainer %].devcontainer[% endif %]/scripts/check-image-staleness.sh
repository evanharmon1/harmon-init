#!/usr/bin/env bash
# check-image-staleness.sh — warn when the running image's baked config has
# drifted from the checkout's `.devcontainer/config/`.
#
# The Dockerfile copies `.devcontainer/config/` into the image at
# /usr/local/share/devcontainer-config/, and `install-harmon-repo-config`
# distributes copies from there (~/.config/starship.toml, the statusline, the
# shell setup, the hooks). So the baked directory IS a snapshot of what the
# checkout said when the image was built, and a recursive compare against the
# checkout answers one question exactly: is this container running config the
# repo has since moved past?
#
# Why that question is worth asking. A container can outlive its image by
# weeks — the Coder attach path reattaches to whatever container exists rather
# than building from the checkout (see docs/guides/devcontainers.md, "Attach
# paths and container managers") — and the symptoms are content-level, not
# crash-level: a prompt drawn by an older starship.toml, a statusline in a
# retired design. Those read as client-side rendering faults, and diagnosing
# them as such costs hours. One line naming the drift ends that.
#
# Warn-only, by construction:
#   * silent when the trees agree, and silent when the baked directory is
#     absent (an image built without this convention, or a run outside the
#     container) — absence is not staleness;
#   * names only file PATHS, never contents: config here references tokens,
#     hostnames, and machine paths, and a lifecycle log is not the place for
#     them;
#   * always exits 0. It runs from post-start and from the status board, both
#     of which are `set -e`, and a diagnostic that can abort the lifecycle it
#     diagnoses is worse than no diagnostic.
#
# The two roots are overridable so scripts/test-image-staleness.sh can point
# them at fixtures; unset, they are the real ones.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

baked="${DEVCONTAINER_BAKED_CONFIG_DIR:-/usr/local/share/devcontainer-config}"
checkout="${DEVCONTAINER_REPO_CONFIG_DIR:-${script_dir}/../config}"

# Strip trailing slashes so the prefix arithmetic below has one form to handle.
while [ "${baked}" != "/" ] && [ "${baked%/}" != "${baked}" ]; do baked="${baked%/}"; done
while [ "${checkout}" != "/" ] && [ "${checkout%/}" != "${checkout}" ]; do checkout="${checkout%/}"; done

# Either side missing means there is nothing to compare, not that something is
# wrong. Outside the container the baked copy simply does not exist.
[ -d "${baked}" ] || exit 0
[ -d "${checkout}" ] || exit 0

# rel_to_root <dir> <name> — the path of <dir>/<name> relative to whichever
# root contains it, for `Only in` lines (which report a directory and a name).
rel_to_root() {
    local dir="$1" name="$2"
    case "${dir}" in
    "${baked}" | "${checkout}") printf '%s' "${name}" ;;
    "${baked}"/*) printf '%s/%s' "${dir#"${baked}"/}" "${name}" ;;
    "${checkout}"/*) printf '%s/%s' "${dir#"${checkout}"/}" "${name}" ;;
    *) printf '%s' "${name}" ;;
    esac
}

# `diff -q -r` is POSIX and reports both differing files and one-sided ones, so
# files ADDED to the checkout since the build and files DROPPED from it both
# count as drift — which is the point of comparing trees instead of a
# hardcoded file list that rots as the config set grows.
#
# LC_ALL=C pins the message wording the parser below matches: these strings are
# localized, and a translated `diff` would silently report zero drift forever.
# A nonzero exit means "differences found", the expected case, so it is not an
# error here; a genuine failure yields no parseable lines and stays silent.
count=0
names=""
while IFS= read -r line; do
    case "${line}" in
    "Files "*" differ")
        rest="${line#Files }"
        rest="${rest% differ}"
        rel="${rest%% and *}"
        rel="${rel#"${baked}"/}"
        ;;
    "Only in "*)
        rest="${line#Only in }"
        rel="$(rel_to_root "${rest%%: *}" "${rest#*: }")"
        ;;
    "File "*" while "*)
        # A path that changed TYPE between image and checkout (regular file on
        # one side, directory on the other): GNU diff -q -r reports it as
        # "File A is a directory while file B is a regular file" — a third
        # message form, and drift like any other. Take the first path.
        rest="${line#File }"
        rel="${rest%% is a *}"
        rel="${rel#"${baked}"/}"
        rel="${rel#"${checkout}"/}"
        ;;
    *) continue ;;
    esac
    count=$((count + 1))
    names="${names}      ${rel}
"
done < <(LC_ALL=C diff -q -r "${baked}" "${checkout}" 2>/dev/null || true)

[ "${count}" -gt 0 ] || exit 0

if [ "${count}" -eq 1 ]; then
    echo "==> image is stale: 1 baked config differs from the checkout — rebuild the container"
else
    echo "==> image is stale: ${count} baked configs differ from the checkout — rebuild the container"
fi
printf '%s' "${names}"

exit 0
