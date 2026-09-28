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
# directory name: `--dry-run` prints one `Install location:` per browser, so
# the set of locations is the tool's own answer and stays correct when a
# Playwright bump moves the chromium revision.
#
# Without this the tier re-downloaded Chromium on every run and recorded a
# change every time, so `--tiers core,agents,browsers` could never report
# HARMON_BOOTSTRAP_CHANGES=0 — contradicting the idempotence this bootstrap
# claims for every tier, not just the default ones.
#
# Both calls name the pinned binary by absolute path, never through npm's
# package runner: that runner prefers a project-local node_modules/.bin in
# the caller's cwd, so on a VM with a checkout it would run that project's
# Playwright and install ITS Chromium revision. harmon_npm_global above has
# just proved the pinned one resolves at ${HARMON_BIN}/playwright.
#
# The probe's exit status is read explicitly. Under `set -euo pipefail` a
# failing probe inside `x="$(... | sed)"` aborts the script before any `if`
# can look at $x, so a fallback written after the substitution never ran.
probe_log="$(mktemp)"
trap 'rm -f "$probe_log"' EXIT
probe_ok=1
"${HARMON_BIN}/playwright" install --dry-run chromium >"$probe_log" 2>/dev/null || probe_ok=0
chromium_targets="$(sed -n 's/^[[:space:]]*Install location:[[:space:]]*//p' "$probe_log")"

browsers_missing=0
if [ "$probe_ok" -ne 1 ] || [ -z "$chromium_targets" ]; then
    # A probe that failed or answered nothing is not evidence of an install.
    # Fall through and let Playwright decide, rather than skipping on a failure.
    browsers_missing=1
else
    # A directory is not an install: an interrupted download leaves one
    # behind. Playwright writes INSTALLATION_COMPLETE into each location as
    # the last step of a successful install (verified against the pinned
    # @playwright/test: chromium, chromium_headless_shell and ffmpeg each
    # carry it), and that marker is what "already installed" means here.
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ -f "${target}/INSTALLATION_COMPLETE" ] || browsers_missing=1
    done <<TARGETS
${chromium_targets}
TARGETS
fi

if [ "$browsers_missing" -eq 0 ]; then
    harmon_skip "playwright chromium"
else
    harmon_changed "playwright chromium"
    "${HARMON_BIN}/playwright" install --with-deps chromium
    # playwright-cli's own browser bootstrap is best-effort: it shares the
    # PLAYWRIGHT_BROWSERS_PATH above, so a failure here costs nothing already
    # installed by the line before it.
    playwright-cli install --with-deps chromium 2>/dev/null || true
    chmod -R o+rx "$PLAYWRIGHT_BROWSERS_PATH"
fi

harmon_cleanup_caches
harmon_log "browsers tier complete"
