#!/usr/bin/env bash
# Open GitHub CLI authentication links on the devcontainer host when possible.
# GH_BROWSER points here only in the human profile. Do not fall back to generic
# browser discovery: the image contains terminal browsers that trap the device
# flow inside the container.

set -u

url="${1:-}"
if [ -z "$url" ]; then
    echo "gh-browser: no URL was provided" >&2
    exit 1
fi

if command -v code >/dev/null 2>&1; then
    if code --open-url "$url"; then
        exit 0
    fi
    echo "gh-browser: VS Code could not open the URL on the host." >&2
fi

printf 'Open this URL in your browser:\n%s\n' "$url" >&2
