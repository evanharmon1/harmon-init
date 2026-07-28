#!/usr/bin/env bash
# e2e-run.sh — run the Playwright end-to-end suite for `task test:e2e`.
#
# Two responsibilities, in order:
#   1. Skip cleanly when the app has no playwright.config.* yet, so a freshly
#      scaffolded repo keeps `task ci` (and the blocking `e2e` CI job) green.
#   2. Once a config exists, run the FAIL-CLOSED environment guard before
#      Playwright. The guard ships unconfigured and fails on purpose — that is
#      a real failure, never a skip. See scripts/e2e-env-guard.sh.
#   3. Ensure browsers are installed, matching what the CI e2e job does —
#      otherwise local `task ci` fails where CI passes — unless the browser
#      cache is image-owned (the devcontainer's), which we must not write to.
#   4. Run the suite WITHOUT the @a11y specs: accessibility is its own,
#      deliberately non-blocking tier (`task test:a11y`).
#
# This is the port-binding test tier (Playwright serves the app), which is why
# it is kept out of `check`/`test`/`verify`. It does NOT build: `task ci` runs
# `build` earlier, and a direct run relies on the app's playwright.config.ts
# `webServer`. See docs/architecture/tests.md.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! find . -maxdepth 1 -name 'playwright.config.*' 2>/dev/null | grep -q .; then
    echo "test:e2e: no Playwright config yet -- skipping (add playwright.config.ts after scaffolding the app)"
    exit 0
fi

./scripts/e2e-env-guard.sh

# Mirror the CI job's browser install so `task ci` actually runs the suite on a
# clean checkout instead of dying on "Executable doesn't exist". Idempotent and
# offline once the browsers are present.
#
# WITHOUT --with-deps: that shells out to apt via sudo, and OS packages are not
# something a local task may assume it can install. CI's hosted-runner step
# passes --with-deps; its self-hosted branch does not, for the same reason.
#
# And never against an IMAGE-OWNED cache: the devcontainer bakes chromium into
# PLAYWRIGHT_BROWSERS_PATH=/ms-playwright as root and grants o+rx, not write, so
# an unconditional install there fails with EACCES before a single test runs.
# When the cache is read-only the image owns it — use what it baked, and add
# browsers by rebuilding the image, not from inside a task.
browsers_path="${PLAYWRIGHT_BROWSERS_PATH:-}"
if [ -n "$browsers_path" ] && [ -d "$browsers_path" ] && [ ! -w "$browsers_path" ]; then
    echo "test:e2e: browser cache ${browsers_path} is image-owned and read-only -- using the browsers it ships."
    echo "test:e2e: if this config needs browsers the image lacks, add them to the"
    echo "test:e2e: devcontainer Dockerfile and rebuild, or point PLAYWRIGHT_BROWSERS_PATH"
    echo "test:e2e: at a writable directory. Do NOT run 'npx playwright install' here --"
    echo "test:e2e: it cannot write to ${browsers_path} and will fail with EACCES."
else
    npx playwright install
fi

# --grep-invert @a11y: the a11y specs are a SEPARATE, deliberately non-blocking
# tier (`task test:a11y`, and a CI job kept out of verify.needs — see
# docs/architecture/branch-protection.md). An unfiltered run here would sweep
# tests/a11y.spec.ts into this BLOCKING check and promote a11y to a required
# gate through the back door. It precedes "$@" so an explicit override still
# wins.
#
# --pass-with-no-tests is REQUIRED alongside that filter. docs/CHECKLIST.md tells
# you to add a playwright.config.* purely to switch the a11y job on; at that
# moment the shipped tests/a11y.spec.ts is the only spec, the filter removes it,
# and Playwright treats "no tests found" as an error — wedging the blocking e2e
# check for following the checklist. No e2e specs yet means nothing to gate on,
# which is the same rule as every other skip-cleanly gate here.
exec npx playwright test --grep-invert @a11y --pass-with-no-tests "$@"
