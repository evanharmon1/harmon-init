#!/usr/bin/env bash
# install-browsers.sh — the BROWSERS tier (opt-in).
#
# Playwright plus its Chromium build. Opt-in because Chromium and its system
# dependencies are far larger than the rest of the toolchain put together and
# most remote sessions never drive a browser — the core+agents default has a
# five-minute cached-setup budget to meet.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harmon_load_versions
harmon_ensure_bin

command -v npm >/dev/null 2>&1 ||
    harmon_die "npm is missing — run the core tier before the browsers tier"

# A shared, world-readable browser path: the image runs as `vscode` at runtime
# while these install as root, and a remote VM may hand the session to a
# different user again.
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"

harmon_npm_global @playwright/test "$PLAYWRIGHT_VERSION" playwright
harmon_npm_global @playwright/cli "$PLAYWRIGHT_CLI_VERSION" playwright-cli

# Ask Playwright where it would put each artifact rather than guessing at a
# directory name or dropping a marker file: `--dry-run` prints one
# `Install location:` per browser, so "already installed" is the tool's own
# answer and stays correct when a Playwright bump moves the chromium revision.
#
# Without this the tier re-downloaded Chromium on every run and recorded a
# change every time, so `--tiers core,agents,browsers` could never report
# HARMON_BOOTSTRAP_CHANGES=0 — contradicting the idempotence this bootstrap
# claims for every tier, not just the default ones.
chromium_targets="$(npx playwright install --dry-run chromium 2>/dev/null |
    sed -n 's/^[[:space:]]*Install location:[[:space:]]*//p')"

browsers_missing=0
if [ -z "$chromium_targets" ]; then
    # A probe that answered nothing is not evidence of an install. Fall
    # through and let Playwright decide, rather than skipping on a failure.
    browsers_missing=1
else
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ -d "$target" ] || browsers_missing=1
    done <<TARGETS
${chromium_targets}
TARGETS
fi

if [ "$browsers_missing" -eq 0 ]; then
    harmon_skip "playwright chromium"
else
    harmon_changed "playwright chromium"
    npx playwright install --with-deps chromium
    # playwright-cli's own browser bootstrap is best-effort: it shares the
    # PLAYWRIGHT_BROWSERS_PATH above, so a failure here costs nothing already
    # installed by the line before it.
    playwright-cli install --with-deps chromium 2>/dev/null || true
    chmod -R o+rx "$PLAYWRIGHT_BROWSERS_PATH"
fi

harmon_cleanup_caches
harmon_log "browsers tier complete"
