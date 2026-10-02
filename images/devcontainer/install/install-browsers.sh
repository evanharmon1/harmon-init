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

# The markers say the DOWNLOAD finished. They say nothing about the OTHER half
# of what this tier promises: that the unprivileged runtime user can read the
# shared cache. These install as root, the image runs as `vscode`, and a remote
# VM may hand the session to another account again — so an interruption between
# the markers and the recursive chmod below, or a restrictive umask, leaves a
# cache that looks complete and cannot be opened. Inferring the permission from
# the marker would take the skip branch on every later run and never repair it.
# So the permission is CHECKED, with the same test the repair makes true:
# `chmod -R o+rx` leaves o+r and o+x set on every entry, and the first entry
# without both is what this finds. On a tree that is already correct the walk
# finds nothing and the tier still skips.
browsers_unreadable=""
if [ -d "$PLAYWRIGHT_BROWSERS_PATH" ]; then
    browsers_unreadable="$(find "$PLAYWRIGHT_BROWSERS_PATH" \! -perm -o+rx -print -quit 2>/dev/null || true)"
fi

# A re-run is a repair for the permissions and a skip for everything else: the
# documented remedy for a browser broken AFTER the marker was written (a system
# dependency removed, say) is still to remove the install location or its
# INSTALLATION_COMPLETE, because reinstalling Chromium on the strength of a
# marker being present is what made this tier non-idempotent in the first place.
if [ "$browsers_missing" -eq 0 ] && [ -z "$browsers_unreadable" ]; then
    harmon_skip "playwright chromium"
elif [ "$browsers_missing" -eq 0 ]; then
    # Downloaded but not readable: repair the permissions alone. No re-download
    # — the markers are trustworthy about what they actually attest.
    harmon_changed "playwright chromium cache permissions (${browsers_unreadable} was not readable by other users)"
    chmod -R o+rx "$PLAYWRIGHT_BROWSERS_PATH"
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
