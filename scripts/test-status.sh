#!/usr/bin/env bash
# test-status.sh — unit-test status.sh's "Project board writes" check: the token
# scope the claim lifecycle needs is reported from the section that session-start
# orientation actually runs (`task status:gh`), in every scope state. Run via
# `task test:status`.
#
# Hermetic in two directions:
#
#   * every `gh` call is answered by a stub on PATH, so this makes no network
#     requests and cannot depend on the scopes of the developer's own token —
#     which is the whole point. The bug it guards (a claim that silently no-ops
#     on a token without the scope) is INVISIBLE when tested with a token that
#     has it.
#   * the checks run against fixture roots this script builds, never against the
#     repo it lives in. status.sh resolves its own root from BASH_SOURCE and
#     feature-detects the board tooling from it, so a test that used the host
#     repo would assert one profile's layout and fail in every other — a repo
#     generated with `project_management: none` correctly omits the check.
set -euo pipefail
cd "$(dirname "$0")/.."
status="./scripts/status.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Two fixture roots, each holding a copy of the script under test:
#   with-board — has the board tooling, so the check applies
#   no-board   — has none of it, so the check must not render at all
for fixture in with-board no-board; do
    mkdir -p "${TMP}/${fixture}/scripts"
    cp "${status}" "${TMP}/${fixture}/scripts/status.sh"
done
# The marker status.sh feature-detects on. Contents are never read.
: >"${TMP}/with-board/scripts/setup-github-project.sh"

WITH_BOARD="${TMP}/with-board/scripts/status.sh"
NO_BOARD="${TMP}/no-board/scripts/status.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# make_stub SCENARIO — write $TMP/bin/gh answering `auth status` per SCENARIO.
# Every other gh call returns an empty JSON array: status.sh reads pr/run lists
# through jq, and a stub that failed them would exercise the wrong code path.
# An unrecognized call exits non-zero rather than defaulting to success, so a
# future probe added to this section shows up here instead of passing silently.
make_stub() {
    local scenario="$1"
    mkdir -p "${TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'if [ "$1" = "auth" ] && [ "$2" = "status" ]; then'
        case "$scenario" in
        project)
            echo "    echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    exit 0'
            ;;
        read-only)
            echo "    echo \"  - Token scopes: 'gist', 'read:project', 'repo'\""
            echo '    exit 0'
            ;;
        none)
            echo "    echo \"  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'\""
            echo '    exit 0'
            ;;
        unparseable)
            # Authenticated, but the scopes are not reported in the form we
            # parse — a GitHub App installation token, or a future gh that
            # renames the line. Must read as "unknown", never as satisfied.
            echo '    echo "  x Logged in to github.com"'
            echo '    exit 0'
            ;;
        unauthenticated)
            echo '    echo "You are not logged into any GitHub hosts." >&2'
            echo '    exit 1'
            ;;
        hangs)
            # Outlives the probe's deadline. Driven with NETWORK_TIMEOUT=1 so
            # the case costs a second rather than the default five.
            echo '    sleep 30'
            echo '    exit 0'
            ;;
        *) fail "unknown stub scenario: ${scenario}" ;;
        esac
        echo 'fi'
        echo 'case "$*" in'
        echo '*"pr list"* | *"run list"*) echo "[]" ;;'
        echo '*) echo "stub: unexpected gh call: $*" >&2; exit 1 ;;'
        echo 'esac'
    } >"${TMP}/bin/gh"
    chmod +x "${TMP}/bin/gh"
}

# run_gh_section SCENARIO [SCRIPT] — status.sh's gh section, with the stub on
# PATH. SCRIPT defaults to the with-board fixture. NO_COLOR keeps the assertions
# free of ANSI escapes.
run_gh_section() {
    make_stub "$1"
    local script="${2:-${WITH_BOARD}}"
    PATH="${TMP}/bin:${PATH}" NO_COLOR=1 "${script}" gh 2>&1
}

echo "==> a token with 'project' reports the board as writable"
out="$(run_gh_section project)"
case "$out" in
*"Project board writes"*"token has 'project'"*) ;;
*) fail "expected a satisfied board-writes line, got: ${out}" ;;
esac

echo "==> read-only 'read:project' is NOT reported as satisfied"
# The state most easily mistaken for working: --show reads the card fine, so the
# board looks reachable right up to the write that moves it.
out="$(run_gh_section read-only)"
case "$out" in
*"token has 'project'"*) fail "read:project must not satisfy a WRITE check: ${out}" ;;
*"read-only"*"gh auth refresh -s project"*) ;;
*) fail "expected a read-only warning naming the remedy, got: ${out}" ;;
esac

echo "==> a token with neither scope warns and names the remedy"
out="$(run_gh_section none)"
case "$out" in
*"lacks 'project'"*"gh auth refresh -s project"*) ;;
*) fail "expected a missing-scope warning naming the remedy, got: ${out}" ;;
esac

echo "==> unreadable scopes read as unknown, not as satisfied"
out="$(run_gh_section unparseable)"
case "$out" in
*"token has 'project'"*) fail "an unparseable scope list must not pass: ${out}" ;;
*"could not read token scopes"*) ;;
*) fail "expected an unknown-scopes line, got: ${out}" ;;
esac

echo "==> an unauthenticated gh skips the section without erroring"
out="$(run_gh_section unauthenticated)"
case "$out" in
*"not authenticated"*) ;;
*) fail "expected the unauthenticated skip, got: ${out}" ;;
esac
case "$out" in
*"Project board writes"*) fail "board-writes line rendered without auth: ${out}" ;;
esac

echo "==> a repo with no project tooling omits the check entirely"
# Not-applicable is not the same as fine: a repo generated with
# `project_management: none` has no board to write to, and a warning there would
# be noise the reader cannot act on.
out="$(run_gh_section project "${NO_BOARD}")"
case "$out" in
*"Project board writes"*) fail "board-writes line rendered in a repo with no board tooling: ${out}" ;;
esac

echo "==> a probe that outlives its deadline says so, not 'not authenticated'"
# Bounding the auth probe made a slow network look exactly like a missing login.
# Reporting the latter for the former sends the reader to fix the wrong thing.
# Skipped where no `timeout` binary exists (stock macOS): run_timeout then runs
# the probe unbounded by design, and there is no deadline to hit.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    make_stub hangs
    out="$(PATH="${TMP}/bin:${PATH}" NO_COLOR=1 NETWORK_TIMEOUT=1 "${WITH_BOARD}" gh 2>&1)"
    case "$out" in
    *"timed out"*) ;;
    *"not authenticated"*) fail "a timeout must not be reported as missing auth: ${out}" ;;
    *) fail "expected a timeout notice, got: ${out}" ;;
    esac
else
    echo "    (skipped: no timeout binary — the probe is unbounded here)"
fi

echo "==> the check never runs the setup section's Projects query"
# The line is fed by the auth probe the section already makes. If it ever grows a
# GraphQL call, the network cost lands in every session start — the reason the
# setup section is excluded from the default dashboard in the first place.
out="$(run_gh_section project)"
case "$out" in
*"stub: unexpected gh call"*) fail "the gh section made an unstubbed call: ${out}" ;;
esac

echo "status.sh tests passed"
