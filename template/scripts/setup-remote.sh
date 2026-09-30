#!/usr/bin/env bash
# setup-remote.sh — prepare THIS checkout for the dev loop on a remote platform.
#
# A devcontainer does this in post-create/post-start; remote platforms (Claude
# Code on the web, Codex cloud, ...) run neither and no hook fires, so an agent
# runs `task setup:remote` once on a fresh checkout. Every step is idempotent and
# a safe no-op when already done:
#
#   1. lefthook install     so the pre-commit / commit-msg / pre-push gates run
#   2. frozen dependencies  pnpm-lock.yaml -> pnpm, uv.lock -> uv (only for a
#                           lockfile that exists; none is a no-op)
#   3. related repos        .devcontainer/related-repos.txt cloned beside this
#                           checkout (its PARENT directory), by the same script
#                           the devcontainer uses
#
# Never prompts. A step whose tool is missing is reported as skipped; the exit
# status is non-zero only when a step that could run failed. A related repo that
# cannot be cloned is a warning from the bootstrap script, not a failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Never prompt or hang on missing credentials or behind egress filters.
export GIT_TERMINAL_PROMPT=0
unset NODE_OPTIONS

did=""
skipped=""
failed=""

note_did() { did="${did}  + $1"$'\n'; }
note_skipped() { skipped="${skipped}  - $1"$'\n'; }
note_failed() { failed="${failed}  ! $1"$'\n'; }

# run_step <label> <command...> — run it, record the outcome, never abort.
run_step() {
    local label="$1"
    shift
    echo "==> ${label}"
    if "$@"; then
        note_did "$label"
    else
        echo "==> ERROR: ${label} failed" >&2
        note_failed "$label"
    fi
}

echo "==> setup:remote in ${ROOT}"

# --- 1. git hooks ---
if [ ! -f lefthook.yml ] && [ ! -f lefthook.yaml ] && [ ! -f .lefthook.yml ]; then
    note_skipped "git hooks: no lefthook config in this repository"
elif ! command -v lefthook >/dev/null 2>&1; then
    note_skipped "git hooks: lefthook is not on PATH (no pre-commit/pre-push gate will run; install lefthook, then re-run)"
else
    run_step "lefthook install" lefthook install
fi

# --- 2. dependencies, frozen to the lockfile ---
if [ -f pnpm-lock.yaml ]; then
    if command -v pnpm >/dev/null 2>&1; then
        # CI=true makes pnpm fail instead of prompting (e.g. before purging node_modules).
        run_step "pnpm install --frozen-lockfile" env CI="${CI:-true}" pnpm install --frozen-lockfile
    else
        note_skipped "dependencies: pnpm-lock.yaml present but pnpm is not on PATH"
    fi
else
    note_skipped "dependencies: no pnpm-lock.yaml"
fi
if [ -f uv.lock ]; then
    if command -v uv >/dev/null 2>&1; then
        run_step "uv sync --frozen" uv sync --frozen
    else
        note_skipped "dependencies: uv.lock present but uv is not on PATH"
    fi
else
    note_skipped "dependencies: no uv.lock"
fi

# --- 3. related repositories, beside this checkout ---
BOOTSTRAP=".devcontainer/scripts/bootstrap-related-repos.sh"
if [ ! -f .devcontainer/related-repos.txt ]; then
    note_skipped "related repos: no .devcontainer/related-repos.txt"
elif [ ! -f "$BOOTSTRAP" ]; then
    note_skipped "related repos: ${BOOTSTRAP} is not present in this repository"
else
    PARENT="$(dirname "$ROOT")"
    if [ ! -w "$PARENT" ]; then
        echo "==> WARNING: ${PARENT} is not writable; related repos cannot be cloned there." >&2
    fi
    echo "==> Related repos are cloned into ${PARENT}"
    # The bootstrap exits 0 whatever it could not clone (it warns on stderr), so a
    # missing sibling never fails setup; only a crash of the script itself does.
    run_step "related repos -> ${PARENT}" bash "$BOOTSTRAP" "$PARENT"
    echo "==> Sibling repos are reference context. Claude Code on the web only allows pushes to"
    echo "    the session's own repository and branch, so changes to a sibling cannot be pushed from here."
fi

# --- summary ---
echo
echo "==> setup:remote summary"
if [ -n "$did" ]; then
    echo "Ran:"
    printf '%s' "$did"
fi
if [ -n "$skipped" ]; then
    echo "Skipped:"
    printf '%s' "$skipped"
fi
if [ -n "$failed" ]; then
    echo "Failed:" >&2
    printf '%s' "$failed" >&2
    exit 1
fi
echo "==> setup:remote complete. Run 'task verify' to check the checkout."
