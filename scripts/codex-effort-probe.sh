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
# A second, distinct effort. One request cannot attribute the header to `-c`:
# a persistent user or project config already holding PROBE_EFFORT produces the
# same output from a CLI that ignores the flag entirely. No single stored value
# can satisfy both of these, so honouring both is the attribution.
readonly PROBE_EFFORT_ALT="${CODEX_PROBE_EFFORT_ALT:-low}"
# Refuse to run where the layered config is absent. The probe exists to prove
# that the devcontainer's two-layer install lets a requested effort through; on
# a bare host there is no /etc/codex/managed_config.toml to override anything,
# so the run tests a different CLI against a different configuration and passes
# trivially -- it would report success while the pinned devcontainer still
# carried the original unoverridable pin. A tool whose whole job is detecting
# that must not be able to pass by being run in the wrong place.
default_effort_file=/etc/codex/config.toml
managed_file=/etc/codex/managed_config.toml
if [ "${CODEX_PROBE_ALLOW_HOST:-0}" != "1" ]; then
    # BOTH layers, not just the defaults one. With no managed_config.toml there
    # is no unoverridable layer to take precedence, so every override trivially
    # "wins" and the probe proves nothing -- the same vacuous pass as a host run,
    # just harder to notice.
    for probe_required in "$default_effort_file" "$managed_file"; do
        [ -r "$probe_required" ] || {
            echo "codex-effort-probe: ${probe_required} not found — this is not a" >&2
            echo "  fully configured devcontainer. Both Codex config layers must be present" >&2
            echo "  or there is no precedence to test. Run it inside the devcontainer, or set" >&2
            echo "  CODEX_PROBE_ALLOW_HOST=1 to probe this machine's CLI deliberately." >&2
            exit 1
        }
    done
fi

# Read the shipped default from the live defaults layer rather than hardcoding
# it. A literal that drifts to equal PROBE_EFFORT would make the anti-vacuity
# check below pass while proving nothing.
if [ -z "${CODEX_PROBE_DEFAULT_EFFORT:-}" ] && [ -r "$default_effort_file" ]; then
    CODEX_PROBE_DEFAULT_EFFORT="$(sed -n 's/^[[:space:]]*"\{0,1\}model_reasoning_effort"\{0,1\}[[:space:]]*=[[:space:]]*"\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' \
        "$default_effort_file" | head -1)"
fi
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
echo "==> requesting reasoning efforts: ${PROBE_EFFORT} and ${PROBE_EFFORT_ALT}"

# The real binary, never a shell function: interactive shells wrap `codex` to
# inject a --profile, and a profile is exactly the kind of hidden precedence
# this probe exists to detect. `command -v` is not enough -- for an exported
# function it returns the NAME, which would re-invoke the wrapper this comment
# promises to bypass. `type -P` searches PATH only.
codex_bin="$(type -P codex || true)"
[ -n "$codex_bin" ] && [ -x "$codex_bin" ] ||
    fail "could not resolve a real codex executable on PATH (a shell function is not enough)"

probe_one() {
    local model="$1" want="$2" run_log rc header effective
    run_log="$(mktemp)"

    # Capture and check Codex's OWN exit status. Piping straight into grep
    # would discard it, and a run that prints its header and then fails on
    # auth, network, or the API would be read as a pass.
    set +e
    "$codex_bin" exec \
        -m "$model" \
        -c "model_reasoning_effort=\"${want}\"" \
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
        fail "no 'reasoning effort:' header for model '${model}' at '${want}'; cannot confirm the effort"

    # "reasoning effort: xhigh" -> "xhigh"
    effective="$(printf '%s\n' "$header" | sed -n 's/.*[Rr]easoning effort:[[:space:]]*//p' | head -1)"
    echo "    ${model} @ ${want}: run header reports ${effective}"

    if [ "$effective" != "$want" ]; then
        fail "model '${model}': requested '${want}' but the run uses '${effective}'.
A managed config is overriding it. Check that model_reasoning_effort is NOT in
/etc/codex/managed_config.toml (it belongs in /etc/codex/config.toml, the
overridable defaults layer) -- see docs/guides/codex-review.md."
    fi
}

[ "$PROBE_EFFORT_ALT" != "$PROBE_EFFORT" ] ||
    fail "the two probe efforts are identical; a single value cannot prove the override applied"

for probe_model in $PROBE_MODELS; do
    probe_one "$probe_model" "$PROBE_EFFORT"
    probe_one "$probe_model" "$PROBE_EFFORT_ALT"
done

echo "codex-effort-probe: OK — both requested efforts reached every probed model"
