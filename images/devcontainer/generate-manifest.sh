#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <revision> <architecture> <name=version>..." >&2
    exit 2
}

[ "$#" -ge 3 ] || usage

revision="$1"
architecture="$2"
shift 2

case "$revision" in
????????????????????????????????????????)
    case "$revision" in *[!0-9a-f]*) usage ;; esac
    ;;
*) usage ;;
esac

case "$architecture" in
amd64 | arm64) ;;
*) usage ;;
esac

manifest_dir="${HARMON_MANIFEST_DIR:-/usr/local/share/harmon-devcontainer}"
manifest_file="${manifest_dir}/manifest.json"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

{
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "image": {\n'
    printf '    "name": "ghcr.io/evanharmon1/harmon-devcontainer",\n'
    printf '    "revision": "%s",\n' "$revision"
    printf '    "architecture": "%s"\n' "$architecture"
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
install -m 0644 "$tmp_file" "$manifest_file"
