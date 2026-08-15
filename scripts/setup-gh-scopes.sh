#!/usr/bin/env bash
# setup-gh-scopes.sh — give the OPERATOR's interactive gh credential every scope
# this repo's tooling needs, and prove the grant actually landed.
#
# Run via `task setup:gh-scopes`. The required list is not stated here — it
# comes from scripts/gh-scopes.sh, the one place status.sh, the devcontainer's
# gh_auth_help banner, and this script all read (issues #827, #596).
#
# OPERATOR / DEV PROFILE ONLY. This mints a human credential, so it refuses in
# the two contexts where doing that would be wrong:
#
#   1. An env token (GH_TOKEN / GITHUB_TOKEN and the enterprise variants) is
#      set. That token OVERRIDES the stored one, so `gh auth refresh` would
#      quietly repair a credential the current shell will never use — and in a
#      bot container it is the credential-escalation ADR 0004 exists to
#      prevent. The remedy there is to reissue the token at its source.
#   2. There is no TTY. The refresh is a browser device-code flow; an agent or
#      a CI job cannot complete it, and neither should re-mint the operator's
#      credential unattended.
#
# Read-only until the refresh: it prints the current scopes, then asks gh for
# the missing ones. Token VALUES are never printed or captured.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=scripts/gh-scopes.sh
. "${REPO_ROOT}/scripts/gh-scopes.sh"

die() {
    echo "setup:gh-scopes: $*" >&2
    exit 1
}

command -v gh >/dev/null 2>&1 || die "gh is not installed (brew install gh)"

# 1. Env-token refusal. Checked before anything else and named individually,
#    because the fix differs per variable and a generic message sends the
#    reader looking for the wrong one.
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    if [ -n "${!var:-}" ]; then
        die "${var} is set. An env token overrides the stored credential, so
  'gh auth refresh' would fix something this shell never uses. Reissue ${var}
  at its source with: $(gh_scopes_request_list)
  (In a bot container this is the intended state — see docs/guides/bot-account.md.)"
    fi
done

# 2. TTY refusal. Both directions are required: the device-code flow prints a
#    code to be read (stdout) and waits on a keypress (stdin).
if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "no TTY. The scope refresh is an interactive browser device-code flow —
  run 'task setup:gh-scopes' yourself in a terminal. Agents and CI must not
  re-mint the operator's credential."
fi

HOSTNAME_ARG="${GH_HOST:-github.com}"
REQUEST_LIST="$(gh_scopes_request_list)"

# `gh auth status` is the only place scopes are readable — they are a
# server-side property of the token, not something stored locally. Captured
# with 2>&1 because gh has moved this report between stdout and stderr across
# versions; only the scope LINE is ever printed back.
scopes_before=""
if status_out="$(gh auth status --hostname "${HOSTNAME_ARG}" 2>&1)"; then
    scopes_before="$(printf '%s\n' "${status_out}" |
        grep -i 'token scopes:' || true)"
else
    die "not logged in to ${HOSTNAME_ARG}. Run:
  gh auth login --hostname ${HOSTNAME_ARG} --git-protocol https --web --scopes \"${REQUEST_LIST}\""
fi

echo "==> Host:            ${HOSTNAME_ARG}"
echo "==> Current scopes:  ${scopes_before:-<none reported>}"
echo "==> Required:        $(gh_scopes_human "${GH_REQUIRED_SCOPES}")"
echo "==> Requesting:      ${REQUEST_LIST}"
echo ""

gh auth refresh --hostname "${HOSTNAME_ARG}" -s "${REQUEST_LIST}"

# 3. Verify the grant LANDED. `gh auth refresh` can exit 0 having granted less
#    than was asked for — a browser flow the operator edited, an org that
#    restricts the scope. Reporting success off the exit code alone would put
#    the session right back into the failure this task exists to end.
verify_out="$(gh auth status --hostname "${HOSTNAME_ARG}" 2>&1)" ||
    die "post-refresh 'gh auth status' failed — the credential may be broken."
scopes_after="$(printf '%s\n' "${verify_out}" | grep -i 'token scopes:' || true)"

echo ""
echo "==> New scopes:      ${scopes_after:-<none reported>}"

case "${scopes_after}" in
*"'"*) ;;
*)
    die "no OAuth scopes reported after the refresh. A fine-grained PAT or an
  App token carries permissions rather than scopes — grant Projects access
  where that token was issued instead."
    ;;
esac

missing="$(gh_scopes_missing "${scopes_after}")"
if [ -n "${missing}" ]; then
    die "the refresh did not grant: $(gh_scopes_human "${missing}").
  Re-run and approve every scope, or check whether the organization restricts
  them (Settings → Third-party access)."
fi

echo ""
echo "All required scopes present: $(gh_scopes_human "${GH_REQUIRED_SCOPES}")"
