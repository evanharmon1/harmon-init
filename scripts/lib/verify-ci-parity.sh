#!/usr/bin/env bash
# verify-ci-parity.sh — shared comparison logic for the verify/CI parity guard
# (harmon-init#962). Sourced by scripts/test-verify-ci-parity.sh (root layer)
# and scripts/test-template.sh (template layer, once per rendered profile) so
# the extraction/comparison rules live in exactly one place.
#
# Every function here either returns a boolean via exit status or prints to
# stdout; failures that mean "the extraction itself is broken" are printed as
# FAIL and exit the whole process — never silently treated as "nothing to
# check" or "exempt". A caller sources this file and then calls check_layer,
# which sets the caller's own `fail` variable (both current callers already
# maintain one) rather than tracking its own state.

verify_ci_parity_require_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        echo "FAIL: yq is required to inspect Taskfile.yml/build.yml (brew bundle / see Brewfile)" >&2
        exit 1
    fi
    if ! yq --version 2>&1 | grep -q 'github.com/mikefarah/yq'; then
        echo "FAIL: yq on PATH is not mikefarah/yq — cannot evaluate: $(yq --version 2>&1 | head -1)" >&2
        exit 1
    fi
}
verify_ci_parity_require_yq

# Extract the flat list of `task: <name>` targets under `tasks.verify.cmds` in
# a Taskfile. A malformed extraction returning nothing must FAIL loudly, never
# read as "verify runs zero targets" — that is exactly the silent-zero trap
# this guard exists to avoid repeating.
verify_ci_parity_extract_verify_targets() {
    local taskfile="$1"
    local out
    out="$(yq '.tasks.verify.cmds[] | select(has("task")) | .task' "$taskfile" 2>/dev/null)" || {
        echo "FAIL: yq could not read tasks.verify.cmds from ${taskfile}" >&2
        exit 1
    }
    if [ -z "$out" ]; then
        echo "FAIL: extracted zero verify targets from ${taskfile} — the extraction is broken, not the Taskfile" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

# Extract every `task <name>` invocation from every job's `run:` steps in a
# workflow, across ALL jobs (not just lint) — a target verify runs might be
# covered under a DIFFERENT job's invocation (test:template's matrix alias in
# template-test, gated by `if` conditions grep alone can't see through). A
# trailing colon (left over from a `task <name>:${{ …` capture) is stripped so
# a namespaced matrix invocation resolves to its base target.
verify_ci_parity_extract_ci_targets() {
    local workflow="$1"
    local out
    out="$(yq -o=json '.jobs.*.steps[] | select(has("run")) | .run' "$workflow" 2>/dev/null)" || {
        echo "FAIL: yq could not read job steps from ${workflow}" >&2
        exit 1
    }
    if [ -z "$out" ]; then
        echo "FAIL: extracted zero CI run steps from ${workflow} — the extraction is broken, not the workflow" >&2
        exit 1
    fi
    printf '%s' "$out" | grep -oE 'task [a-zA-Z0-9_:-]+' | sed 's/^task //; s/:*$//' | sort -u
}

# Is a single `cmds[]` entry (already extracted as a raw yq scalar string) a
# genuinely inert placeholder — "echo <literal quoted string>" and nothing
# else? Deliberately narrow: no command substitution ($( ), `), no variable
# interpolation ($), no chaining (&&, ||, ;, |) outside the quoted literal.
# Anything wider than this pattern MUST be treated as real work, because the
# whole point is that a task whose body can run something other than an echo
# must be covered by CI, not waved through by name.
verify_ci_parity_body_is_inert_echo() {
    local body="$1"
    printf '%s' "$body" | grep -Eq '^echo "[^"$`]*"$' && return 0
    printf '%s' "$body" | grep -Eq "^echo '[^'\$\`]*'\$" && return 0
    return 1
}

# Is `target` in `taskfile` a placeholder with nothing for CI to run? True
# only when its rendered `cmds` is EXACTLY one entry, that entry is a plain
# string (not a `task:` reference — a real sub-task is never inert by
# definition), and the string is a bare literal echo per the pattern above.
# A read that fails outright (yq errors, missing field) is a hard FAIL, not a
# silent "not inert" or "inert" default — the whole reason this replaced a
# name-based allowlist was that a name-based exemption can't tell an inert
# placeholder from a profile where the same task does real work.
verify_ci_parity_task_is_inert() {
    local taskfile="$1" target="$2"
    local count kind body

    count="$(yq ".tasks.\"${target}\".cmds | length" "$taskfile" 2>/dev/null)" || {
        echo "FAIL: could not read cmds for task '${target}' in ${taskfile} — cannot determine inertness" >&2
        exit 1
    }
    case "$count" in
    '' | *[!0-9]*)
        echo "FAIL: could not determine cmds length for task '${target}' in ${taskfile} — cannot determine inertness" >&2
        exit 1
        ;;
    esac
    if [ "$count" -ne 1 ]; then
        return 1
    fi

    kind="$(yq '.tasks."'"${target}"'".cmds[0] | tag' "$taskfile" 2>/dev/null)" || {
        echo "FAIL: could not read cmds[0] type for task '${target}' in ${taskfile} — cannot determine inertness" >&2
        exit 1
    }
    if [ "$kind" != '!!str' ]; then
        # A map (a `task:` reference) is real delegated work by construction.
        return 1
    fi

    body="$(yq '.tasks."'"${target}"'".cmds[0]' "$taskfile" 2>/dev/null)" || {
        echo "FAIL: could not read cmds[0] body for task '${target}' in ${taskfile} — cannot determine inertness" >&2
        exit 1
    }
    verify_ci_parity_body_is_inert_echo "$body"
}

# Compare one Taskfile/workflow pair. Sets the CALLER's `fail` variable (both
# current callers already maintain one) — never its own — so this can be
# sourced into either script's existing accumulate-and-report loop rather than
# forcing a second reporting convention. $3 is a label for FAIL output. $4,
# if given, is the NAME of a function the caller defines that takes a target
# name and returns 0 for a named exception (a genuine gap explicitly
# allowlisted with a stated reason — see each caller's own allowlist) —
# checked ONLY as a fallback after CI-reachability and inertness both fail,
# so a name-based exception can never mask a target CI actually reaches.
verify_ci_parity_check_layer() {
    local taskfile="$1" workflow="$2" label="$3" allow_fn="${4:-}"
    local verify_targets ci_targets target

    if [ ! -f "$taskfile" ]; then
        echo "FAIL: ${taskfile} not found — nothing to check for ${label}" >&2
        fail=1
        return
    fi
    if [ ! -f "$workflow" ]; then
        echo "FAIL: ${workflow} not found — nothing to check for ${label}" >&2
        fail=1
        return
    fi

    verify_targets="$(verify_ci_parity_extract_verify_targets "$taskfile")"
    ci_targets="$(verify_ci_parity_extract_ci_targets "$workflow")"

    while IFS= read -r target; do
        [ -n "$target" ] || continue
        case "
$ci_targets
" in *"
$target
"*) continue ;; esac
        if verify_ci_parity_task_is_inert "$taskfile" "$target"; then
            continue
        fi
        if [ -n "$allow_fn" ] && "$allow_fn" "$target"; then
            continue
        fi
        echo "FAIL (${label}): task verify runs '${target}' but no CI job in $(basename "$workflow") invokes it" >&2
        fail=1
    done < <(printf '%s\n' "$verify_targets" | sort -u)
}
