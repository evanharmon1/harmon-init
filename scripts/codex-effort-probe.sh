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
# Probing only the default model would let a combination pass where the default
# accepts xhigh but a dispatched worker model quietly falls back, which is the
# failure #1186 was actually about. Probe the models workers are dispatched as.
readonly PROBE_MODELS="${CODEX_PROBE_MODELS:-gpt-5.6-sol gpt-5.6-luna gpt-5.6-terra}"

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

probe_one() {
    local model="$1" run_log rc header effective
    run_log="$(mktemp)"

    # Capture and check Codex's OWN exit status. Piping straight into grep
    # would discard it, and a run that prints its header and then fails on
    # auth, network, or the API would be read as a pass.
    set +e
    "$codex_bin" exec \
        -m "$model" \
        -c "model_reasoning_effort=\"${PROBE_EFFORT}\"" \
        --skip-git-repo-check \
        'Reply with exactly: ok' </dev/null >"$run_log" 2>&1
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        echo "--- codex output (exit ${rc}) ---" >&2
        tail -20 "$run_log" >&2
        rm -f "$run_log"
        fail "codex exited ${rc} for model '${model}'; the probe cannot confirm anything (logged in?)"
    fi

    header="$(grep -i 'reasoning effort' "$run_log" | head -1 || true)"
    rm -f "$run_log"

    [ -n "$header" ] ||
        fail "no 'reasoning effort:' header for model '${model}'; cannot confirm the effort"

    # "reasoning effort: xhigh" -> "xhigh"
    effective="$(printf '%s\n' "$header" | sed -n 's/.*[Rr]easoning effort:[[:space:]]*//p' | head -1)"
    echo "    ${model}: run header reports ${effective}"

    if [ "$effective" != "$PROBE_EFFORT" ]; then
        fail "model '${model}': requested '${PROBE_EFFORT}' but the run uses '${effective}'.
A managed config is overriding it. Check that model_reasoning_effort is NOT in
/etc/codex/managed_config.toml (it belongs in /etc/codex/config.toml, the
overridable defaults layer) -- see docs/guides/codex-review.md."
    fi
}

for probe_model in $PROBE_MODELS; do
    probe_one "$probe_model"
done

echo "codex-effort-probe: OK — the requested effort reached every probed model"
