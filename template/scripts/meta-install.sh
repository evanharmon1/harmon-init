#!/usr/bin/env bash
# meta-install.sh — move a .meta sidecar (a Bunch launcher or an Obsidian
# project note) into its system folder and leave a symlink behind in .meta/, so
# the file lives where its app expects it while staying visible in the repo.
# Run via `task util:bunch-install` / `task util:obsidian-install`; pair with
# `meta-create.sh`, which scaffolds the file this moves.
#
# The destination is a copier answer rendered into the Taskfile inside single
# quotes, so the shell never expands a leading `~`. Expanding it here — rather
# than in the Taskfile string — is what keeps the answer defaults free of any
# one user's absolute home path (see issue #552).
#
# macOS only: both destinations (iCloud Drive, an Obsidian vault) are macOS
# conventions, and `task util:*-install` is documented as such.
#
# Usage:
#   meta-install.sh bunch    <project_name> <bunches_directory>
#   meta-install.sh obsidian <project_name> <obsidian_directory>
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "meta-install: $*" >&2
    exit 1
}

# Expand a leading `~` or `~/` to $HOME. A `~user/` prefix is left alone: we
# cannot resolve another user's home portably, and the answer is meant to point
# at the calling user's own directories.
expand_home() {
    case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
    esac
}

kind="${1:-}"

case "$kind" in
bunch)
    name="${2:?project name required}"
    dest_dir="$(expand_home "${3:?bunches directory required}")"
    file="Code Project - ${name}.bunch"
    ;;
obsidian)
    name="${2:?project name required}"
    dest_dir="$(expand_home "${3:?obsidian directory required}")"
    file="${name}.md"
    ;;
*)
    fail "usage: meta-install.sh {bunch|obsidian} <project_name> <destination_directory>"
    ;;
esac

[ "$(uname -s)" = "Darwin" ] || fail "macOS only (found $(uname -s))"

src=".meta/${file}"
dest="${dest_dir}/${file}"

# Already installed: .meta/<file> is the symlink pointing at an existing dest.
if [ -L "$src" ] && [ "$(readlink "$src")" = "$dest" ] && [ -e "$dest" ]; then
    echo "meta-install: $src already links to $dest"
    exit 0
fi

# `-e` follows symlinks, so test for a link first: a dangling or misdirected
# symlink at .meta/<file> is a broken install, not a missing one.
if [ -L "$src" ]; then
    fail "$src is a symlink to $(readlink "$src"), not to $dest"
fi
if [ ! -e "$src" ]; then
    fail "$src not found — run 'task util:${kind}-add' first"
fi
if [ ! -d "$dest_dir" ]; then
    fail "destination directory does not exist: $dest_dir"
fi
if [ -e "$dest" ]; then
    fail "$dest already exists"
fi

mv "$src" "$dest"
ln -s "$dest" "$src"
echo "meta-install: moved $file to $dest_dir and linked it back into .meta/"
