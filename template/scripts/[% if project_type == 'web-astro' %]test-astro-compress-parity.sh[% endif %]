#!/usr/bin/env bash
# test-astro-compress-parity.sh — fail when prettier's astroCompressHTML
# disagrees with Astro's own compressHTML, instead of discovering it only
# after prettier-plugin-astro silently reflows whitespace-sensitive inline
# markup into a visibly different rendered page (harmon-init#1350,
# ponderousdev/lawnomator-site#192 commit b74aaaf: "privacy policy .",
# "9:41 ··").
#
# prettier-plugin-astro's `astroCompressHTML` option and Astro's own
# `compressHTML` build option are two independent settings that MUST agree.
# The actual comparison (test-astro-compress-parity.mjs) REQUIRES/imports
# both config files rather than pattern-matching their source text — a
# regex-based reader was tried first and repeatedly defeated by ordinary,
# valid JS (a URL containing `//`, a multiline property, a mutable binding,
# a value supplied through an import — harmon-init#1350 Codex review
# rounds 2-3). This wrapper only resolves which files exist and skips
# cleanly before Astro is scaffolded (fresh repo, no astro.config.* yet)
# — like lint:eslint / lint:prettier — so `task check` stays green until
# then.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_root"

prettier_config="prettier.config.cjs"
astro_config=""
for candidate in astro.config.mjs astro.config.ts astro.config.cjs astro.config.js astro.config.mts astro.config.cts; do
    if [ -f "$candidate" ]; then
        astro_config="$candidate"
        break
    fi
done

if [ -z "$astro_config" ]; then
    echo "test-astro-compress-parity: no astro.config.* yet -- skipping (scaffold Astro first, see docs/CHECKLIST.md)"
    exit 0
fi

# Astro is scaffolded, so prettier.config.cjs (template-shipped from day one)
# is expected to exist. Missing here means it was deleted or renamed after
# Astro was scaffolded — fail closed rather than silently skip, or `task
# verify` would pass with no proof astroCompressHTML matches Astro at all.
if [ ! -f "$prettier_config" ]; then
    echo "test-astro-compress-parity: astro.config.* exists but ${prettier_config} does not -- cannot verify astroCompressHTML matches compressHTML" >&2
    exit 1
fi

node "${script_dir}/test-astro-compress-parity.mjs" "$astro_config" "$prettier_config"
