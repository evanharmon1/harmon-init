#!/usr/bin/env bash
# Prove that a requested Codex reasoning effort actually takes effect.
#
# harmon-init#1186: /etc/codex/managed_config.toml is Codex's legacy MDM layer,
# where every key is an unoverridable REQUIREMENT. While model_reasoning_effort
# was pinned there, every worker dispatched at "xhigh" silently ran at the
# pinned "medium" -- no error, no warning, and the run header was the only
# place the truth appeared.
#
# The static half of the fix lives in scripts/devcontainer-assert.sh and
# scripts/test-template.sh: they fail if a preference drifts back into a
# managed config. That catches OUR regressions. This probe catches the other
# kind -- a Codex CLI whose precedence rules change under us -- by running the
# real binary and reading back the header it prints.
#
# Deliberately NOT part of `task verify` or `task ci`: it spends a real Codex
# call and needs a login, and no gate in this repo may depend on Codex
# (AGENTS.md, "Second-Model Review"). Run it on a CODEX_VERSION bump (the
# Renovate PR for the shared image) and after any login-method change.
set -euo pipefail

# The probe effort must DIFFER from the shipped default, or a run that ignores
# the override looks identical to one that honours it and the probe is vacuous.
readonly PROBE_EFFORT="${CODEX_PROBE_EFFORT:-xhigh}"
readonly DEFAULT_EFFORT="${CODEX_PROBE_DEFAULT_EFFORT:-medium}"

fail() {
    echo "codex-effort-probe: $*" >&2
    exit 1
}

command -v codex >/dev/null 2>&1 || fail "the codex CLI is not on PATH"

[ "$PROBE_EFFORT" != "$DEFAULT_EFFORT" ] ||
    fail "probe effort '${PROBE_EFFORT}' equals the default; the probe would prove nothing"

echo "==> codex $(codex --version 2>&1)"
echo "==> requesting reasoning effort: ${PROBE_EFFORT}"

# `codex`, not a shell function: interactive shells may wrap it to inject a
# --profile, and a profile is exactly the kind of hidden precedence this probe
# exists to detect. Scripts get the real binary because functions are not
# exported into them, but resolve it explicitly so that stays true.
codex_bin="$(command -v codex)"

header="$(
    "$codex_bin" exec \
        -c "model_reasoning_effort=\"${PROBE_EFFORT}\"" \
        --skip-git-repo-check \
        'Reply with exactly: ok' </dev/null 2>&1 |
        grep -i 'reasoning effort' || true
)"

[ -n "$header" ] ||
    fail "the run printed no 'reasoning effort:' header; cannot confirm the effort (is the CLI logged in?)"

# "reasoning effort: xhigh" -> "xhigh"
effective="$(printf '%s\n' "$header" | sed -n 's/.*[Rr]easoning effort:[[:space:]]*//p' | head -1)"

echo "==> run header reports: ${effective}"

if [ "$effective" != "$PROBE_EFFORT" ]; then
    fail "requested '${PROBE_EFFORT}' but the run uses '${effective}'.
A managed config is overriding it. Check that model_reasoning_effort is NOT in
/etc/codex/managed_config.toml (it belongs in /etc/codex/config.toml, the
overridable defaults layer) -- see docs/guides/codex-review.md."
fi

echo "codex-effort-probe: OK — the requested effort reached the run"
