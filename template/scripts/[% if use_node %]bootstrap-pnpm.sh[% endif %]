#!/usr/bin/env bash
# Ensure Homebrew owns the active pnpm links, including after legacy bootstraps.
set -euo pipefail

export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1

brew install node

# A legacy npm-global link can make `brew install` fail after staging the keg.
# Continue only when Homebrew confirms the formula is installed; a real install
# failure with no available keg remains fatal.
if ! brew install pnpm; then
    if ! brew list --formula pnpm >/dev/null 2>&1; then
        echo "bootstrap: Homebrew could not install pnpm" >&2
        exit 1
    fi
fi

brew_prefix=$(brew --prefix)
legacy_pnpm="${brew_prefix}/lib/node_modules/pnpm"

# Retire only the npm-global package installed into Homebrew's own prefix by
# older bootstrap versions. An explicit prefix prevents whichever npm happens
# to be first on PATH from touching nvm, Volta, or another managed toolchain.
if [ -d "$legacy_pnpm" ]; then
    npm uninstall --global --prefix "$brew_prefix" pnpm
fi

# Recreate the links instead of trusting stale linked-keg metadata. Overwriting
# only Homebrew-prefix links avoids deleting packages managed by npm, nvm, Volta,
# or another toolchain and leaves Homebrew as the active owner in its prefix.
brew unlink pnpm >/dev/null 2>&1 || true
brew link --overwrite pnpm

resolve_path() {
    path=$1
    while [ -L "$path" ]; do
        target=$(readlink "$path")
        case "$target" in
        /*) path=$target ;;
        *) path="$(dirname "$path")/$target" ;;
        esac
    done
    directory=$(cd -P "$(dirname "$path")" && pwd)
    printf '%s/%s\n' "$directory" "$(basename "$path")"
}

pnpm_prefix=$(resolve_path "$(brew --prefix pnpm)")
pnpm_executable=$(resolve_path "${brew_prefix}/bin/pnpm")
case "$pnpm_executable" in
"${pnpm_prefix}"/*) ;;
*)
    echo "bootstrap: pnpm does not resolve to Homebrew's pnpm keg" >&2
    exit 1
    ;;
esac
