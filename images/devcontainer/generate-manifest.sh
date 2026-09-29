#!/usr/bin/env bash
# generate-manifest.sh — write the tool manifest. Run by the image build (into
# /usr/local/share/harmon-devcontainer) and by bootstrap-remote.sh on a VM
# (into HARMON_MANIFEST_DIR, named HARMON_MANIFEST_NAME), so the two can be
# compared field for field: same schema, same keys, same generator.
set -euo pipefail

usage() {
    echo "Usage: $0 <revision> <architecture> <name=version>..." >&2
    echo "  revision: a 40-hex commit (optionally suffixed -dirty by the remote bootstrap), or the release tag (vX.Y.Z) a bootstrap fetched from" >&2
    echo "  HARMON_MANIFEST_TIERS: optional comma-separated tier set the entries were produced from (the remote bootstrap sets it; the image build does not)" >&2
    exit 2
}

[ "$#" -ge 3 ] || usage

revision="$1"
architecture="$2"
shift 2

# A commit may carry a `-dirty` suffix: the remote bootstrap records it for
# a checkout with uncommitted changes, so the manifest never attests a clean
# commit for bytes that were not that commit. The image build always passes
# a clean commit or a release tag.
revision_core="${revision%-dirty}"
case "$revision_core" in
????????????????????????????????????????)
    case "$revision_core" in *[!0-9a-f]*) usage ;; esac
    ;;
*)
    [ "$revision_core" = "$revision" ] || usage
    printf '%s' "$revision" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || usage
    ;;
esac

case "$architecture" in
amd64 | arm64) ;;
*) usage ;;
esac

# The tier set is recorded because the VM manifest's entries are ONE RUN's
# records: `--tiers core` after a `--tiers core,agents,browsers` run legitimately
# writes fewer tools, and without this field a reader comparing two manifests
# cannot tell that narrowing apart from a tool having disappeared. Optional: the
# image build installs its whole toolchain and has no tier selection to name, so
# an unset value omits the field and leaves the image manifest as it was.
manifest_tiers="${HARMON_MANIFEST_TIERS:-}"
if [ -n "$manifest_tiers" ]; then
    case "$manifest_tiers" in
    *[!a-z0-9,-]* | ,* | *, | *,,*) usage ;;
    esac
fi

manifest_dir="${HARMON_MANIFEST_DIR:-/usr/local/share/harmon-devcontainer}"
manifest_name="${HARMON_MANIFEST_NAME:-ghcr.io/evanharmon1/harmon-devcontainer}"
manifest_file="${manifest_dir}/manifest.json"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

{
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "image": {\n'
    printf '    "name": "%s",\n' "$manifest_name"
    printf '    "revision": "%s",\n' "$revision"
    printf '    "architecture": "%s"' "$architecture"
    if [ -n "$manifest_tiers" ]; then
        printf ',\n    "tiers": "%s"\n' "$manifest_tiers"
    else
        printf '\n'
    fi
    printf '  },\n'
    printf '  "tools": {\n'

    separator=""
    for pair in "$@"; do
        name="${pair%%=*}"
        version="${pair#*=}"
        [ "$name" != "$pair" ] || usage
        case "$name" in "" | *[!a-z0-9_-]*) usage ;; esac
        case "$version" in "" | *[!A-Za-z0-9._+-]*) usage ;; esac
        printf '%s    "%s": "%s"' "$separator" "$name" "$version"
        separator=",
"
    done
    printf '\n  }\n}\n'
} >"$tmp_file"

jq -e . "$tmp_file" >/dev/null
install -d -m 0755 "$manifest_dir"

# writer_alive <pid> — true when a process with that pid exists, and true also
# when the question cannot be answered. /proc rather than `kill -0`, which
# reports the same failure for "no such process" and "not permitted to signal
# it": the cost of keeping a stale file is disk, and the cost of a wrong answer
# is deleting bytes a live writer is mid-way through staging — the exact race the
# pid in the name exists to prevent.
#
# This is lib.sh's harmon_writer_alive / harmon_reap_staging predicate, and it is
# duplicated here rather than called because lib.sh is not reachable from this
# script: both callers run it as its own PROCESS (`bash generate-manifest.sh`),
# which inherits no shell functions, and the image build has no lib.sh to source
# at all — the Dockerfile copies this one file into /usr/local/sbin. Sourcing
# lib.sh would also drag HARMON_PREFIX, HARMON_BIN and the uv tool-dir exports
# into the image build's manifest step for the sake of one predicate.
writer_alive() {
    case "${1:-}" in
    '' | *[!0-9]*) return 0 ;;
    esac
    [ -d /proc ] || return 0
    [ -d "/proc/$1" ]
}

# Staging files whose writer is GONE are removed here, by LIVENESS rather than by
# age or by name alone, and unconditionally — before the byte-identical check
# below, not inside it. A pid in the name is what stops two runs on one VM
# renaming each other's half-written copy into place, and on its own it also made
# every abandoned staging file permanently unreapable: a later run has a
# different pid, and the overwhelmingly common run writes nothing here at all
# because the manifest has not changed. Reaping only when a write happens is how
# an interrupted bootstrap leaves a full-size file in the prefix forever, on
# exactly the small VMs this toolchain targets.
for staging_file in "${manifest_file}".*.harmon-staging; do
    [ -f "$staging_file" ] || continue # an unmatched glob, or a stray directory
    staging_pid="${staging_file%.harmon-staging}"
    staging_pid="${staging_pid##*.}"
    writer_alive "$staging_pid" || rm -f "$staging_file"
done

# Byte-identical content is left alone: on a VM the bootstrap re-runs this and
# "a second run changed nothing" should hold for the file's mtime too.
if ! cmp -s "$tmp_file" "$manifest_file" 2>/dev/null; then
    # Staged beside the live file and renamed, the invariant lib.sh's
    # harmon_install_bin establishes for every binary install. install(1)
    # copies INTO its destination, so an interruption or a full disk part-way
    # through leaves a truncated manifest where the previous valid record was —
    # and this script runs on the VM, where that record is the only evidence of
    # what is installed there. The rename is in the same directory, so it is
    # atomic: the live path is the old manifest or the new one, never a
    # fragment of either. The staging name carries the pid for the same reason
    # harmon_install_bin's does — two runs on one VM must not rename each
    # other's half-written copy into place.
    #
    # Either step failing removes THIS run's staging path before the script
    # dies, exactly as harmon_install_bin does: a writer about to stop existing
    # should not leave behind a file only the sweep above can clean up, and that
    # sweep is the fallback for the interruptions no handler sees (a kill, a
    # power loss) rather than the routine path.
    staging="${manifest_file}.$$.harmon-staging"
    if ! install -m 0644 "$tmp_file" "$staging"; then
        rm -f "$staging"
        printf 'generate-manifest: could not stage %s\n' "$manifest_file" >&2
        exit 1
    fi
    if ! mv -f "$staging" "$manifest_file"; then
        rm -f "$staging"
        printf 'generate-manifest: could not publish %s\n' "$manifest_file" >&2
        exit 1
    fi
fi
