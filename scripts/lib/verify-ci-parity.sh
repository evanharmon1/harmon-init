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
#
# DESIGN, round 2 (harmon-init#962 adversarial review): every extraction rule
# below recognizes one small, explicit shape and FAILS LOUDLY on anything
# else. Earlier drafts tried to parse more cases correctly (scan every job,
# regex-match "task X" anywhere in a run body, collapse a matrix invocation to
# its base name); each of those turned out to have a false-pass path — a way
# for the guard to report parity while CI is genuinely weaker than local
# `verify`. A guard that refuses to guess is smaller, more reviewable, and
# cannot silently false-pass; it can only ever refuse to render a verdict.

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

# ── Verify-side extraction (D1) ─────────────────────────────────────────────
# Extract the flat list of `task: <name>` targets under `tasks.verify.cmds` in
# a Taskfile. EVERY entry must be a `task:` reference — the Taskfile
# convention (AGENTS.md "Keep Taskfile cmds: trivial") explicitly permits a
# direct script invocation (`- ./scripts/foo.sh`) instead, and such an entry
# cannot be parity-checked by this guard: it has no target name to look up in
# CI. A verify made entirely of `task:` entries is not an incidental property
# of this repo today, it is the shape this guard depends on — so a non-`task:`
# entry FAILS loudly and names the offending index, rather than being
# silently dropped (which is exactly how the direct-command entry evaded
# parity in the first place).
verify_ci_parity_extract_verify_targets() {
    local taskfile="$1"
    local count i is_task_ref entry_repr out=""

    count="$(yq '.tasks.verify.cmds | length' "$taskfile" 2>/dev/null)" || {
        echo "FAIL: yq could not read tasks.verify.cmds from ${taskfile}" >&2
        exit 1
    }
    case "$count" in
    '' | *[!0-9]*)
        echo "FAIL: could not determine tasks.verify.cmds length in ${taskfile}" >&2
        exit 1
        ;;
    esac
    if [ "$count" -eq 0 ]; then
        echo "FAIL: extracted zero verify cmds entries from ${taskfile} — the extraction is broken, not the Taskfile" >&2
        exit 1
    fi

    i=0
    while [ "$i" -lt "$count" ]; do
        is_task_ref="$(yq ".tasks.verify.cmds[${i}] | has(\"task\")" "$taskfile" 2>/dev/null)" || {
            echo "FAIL: could not inspect tasks.verify.cmds[${i}] in ${taskfile}" >&2
            exit 1
        }
        if [ "$is_task_ref" != "true" ]; then
            entry_repr="$(yq -o=json ".tasks.verify.cmds[${i}]" "$taskfile" 2>/dev/null)"
            echo "FAIL: tasks.verify.cmds[${i}] in ${taskfile} is not a 'task: <name>' reference (got: ${entry_repr})." >&2
            echo "      A direct command in verify cannot be parity-checked against CI by name. Convert it to a" >&2
            echo "      task (preferred), or if it is genuinely local-only, make that an explicit, reviewed exemption" >&2
            echo "      rather than letting the extraction drop it silently." >&2
            exit 1
        fi
        out="${out}$(yq ".tasks.verify.cmds[${i}].task" "$taskfile" 2>/dev/null)
"
        i=$((i + 1))
    done

    if [ -z "$out" ]; then
        echo "FAIL: extracted zero verify targets from ${taskfile} — the extraction is broken, not the Taskfile" >&2
        exit 1
    fi
    printf '%s' "$out"
}

# ── CI-side job closure (D2) ─────────────────────────────────────────────────
# The required aggregate job is named `verify` in every workflow this guard
# checks (root build.yml and the rendered template build.yml.jinja alike —
# both define a final `verify:` job that branch protection actually requires).
# A job can only block that required check by being in its transitive `needs`
# closure; a job outside it (e.g. `a11y`, deliberately excluded from
# `verify.needs` so it reports without gating) can run `task test:a11y` all
# day without that ever being real CI coverage for a `verify` target of the
# same name. Scanning every job regardless of reachability was exactly the
# false-pass path this guard had (harmon-init#962 round 2, finding D2).
verify_ci_parity_job_closure() {
    local workflow="$1"
    local -a queue seen
    local job needs n already sj

    if ! yq -e '.jobs."verify"' "$workflow" >/dev/null 2>&1; then
        echo "FAIL: no job named 'verify' in ${workflow} — cannot identify the required aggregate to compute its needs closure" >&2
        exit 1
    fi

    queue=("verify")
    seen=("verify")
    while [ "${#queue[@]}" -gt 0 ]; do
        job="${queue[0]}"
        queue=("${queue[@]:1}")

        needs="$(yq "[.jobs.\"${job}\".needs] | flatten | .[]" "$workflow" 2>/dev/null)" || {
            echo "FAIL: could not read needs for job '${job}' in ${workflow}" >&2
            exit 1
        }
        # `needs` may be absent (null), a bare string, or an array — the
        # `[.needs] | flatten` wrapper normalizes all three to one name per
        # line (an absent/null needs prints the literal string "null", which
        # is filtered below rather than treated as a job named "null").
        while IFS= read -r n; do
            [ -n "$n" ] && [ "$n" != "null" ] || continue
            already=0
            for sj in "${seen[@]}"; do
                if [ "$sj" = "$n" ]; then
                    already=1
                    break
                fi
            done
            if [ "$already" -eq 0 ]; then
                seen+=("$n")
                queue+=("$n")
            fi
        done <<EOF
$needs
EOF
    done

    printf '%s\n' "${seen[@]}"
}

# ── CI-side run-body classification (D3) ────────────────────────────────────
# A run body counts as coverage for target X only if it contains a line,
# after stripping blank lines and full-line `#` comments, that is EXACTLY
# `task X` (optionally namespaced) and nothing else on that line — no
# chaining (&&, ||, ;, |), no redirection, no surrounding text. That is the
# house style every real `run:` step in both workflows already uses (verified
# empirically against build.yml and build.yml.jinja before writing this rule).
#
# A run body with no `task` word in it at all is unrelated to coverage
# (dependency installs, git config, …) and is silently skipped — it was never
# a candidate for covering a verify target. A run body that DOES contain the
# word `task` but on a line that is not the clean shape above (a comment
# mentioning a target, `echo "task gate"`, `task foo || true`, unreachable
# branches) is a shape this guard refuses to scan heuristically: it FAILS
# loudly, naming the job, the step, and the offending line, rather than
# guessing whether that line means the target is covered.
verify_ci_parity_line_is_plain_task() {
    local line="$1"
    [[ "$line" =~ ^task\ [A-Za-z0-9_:-]+$ ]]
}

verify_ci_parity_line_is_matrix_task() {
    local line="$1"
    [[ "$line" =~ ^task\ [A-Za-z0-9_:-]+:\$\{\{[[:space:]]*matrix\.[A-Za-z0-9_.-]+[[:space:]]*\}\}$ ]]
}

verify_ci_parity_line_mentions_task() {
    local line="$1"
    [[ "$line" =~ (^|[^A-Za-z0-9_-])task([^A-Za-z0-9_:-]|$) ]]
}

# Resolve the local Taskfile aggregate's own sub-targets for a matrix alias
# line's prefix (e.g. `test:template`), so a matrix invocation can be checked
# against what verify ACTUALLY depends on rather than trusted by name. Follows
# a chain of single `task:`-only cmds (the same shape D1 now requires of
# verify.cmds itself) until it finds a task with a non-empty `deps` list.
# Bounded to avoid an unbounded/cyclic chain; FAILS loudly rather than
# guessing if no deps are ever found.
verify_ci_parity_resolve_deps() {
    local taskfile="$1" target="$2"
    local current="$target" hops=0 max_hops=5
    local cmd_count kind next dep_count

    while [ "$hops" -lt "$max_hops" ]; do
        dep_count="$(yq ".tasks.\"${current}\".deps | length" "$taskfile" 2>/dev/null)" || {
            echo "FAIL: could not read deps for task '${current}' (resolving matrix aggregate '${target}') in ${taskfile}" >&2
            exit 1
        }
        case "$dep_count" in
        '' | *[!0-9]*)
            echo "FAIL: could not determine deps length for task '${current}' (resolving matrix aggregate '${target}') in ${taskfile}" >&2
            exit 1
            ;;
        esac
        if [ "$dep_count" -gt 0 ]; then
            yq ".tasks.\"${current}\".deps[]" "$taskfile" 2>/dev/null
            return 0
        fi

        cmd_count="$(yq ".tasks.\"${current}\".cmds | length" "$taskfile" 2>/dev/null)" || {
            echo "FAIL: could not read cmds for task '${current}' (resolving matrix aggregate '${target}') in ${taskfile}" >&2
            exit 1
        }
        if [ "$cmd_count" != "1" ]; then
            break
        fi
        kind="$(yq ".tasks.\"${current}\".cmds[0] | tag" "$taskfile" 2>/dev/null)" || {
            echo "FAIL: could not read cmds[0] type for task '${current}' (resolving matrix aggregate '${target}') in ${taskfile}" >&2
            exit 1
        }
        if [ "$kind" != "!!map" ]; then
            break
        fi
        next="$(yq ".tasks.\"${current}\".cmds[0].task" "$taskfile" 2>/dev/null)" || {
            echo "FAIL: could not read cmds[0].task for task '${current}' (resolving matrix aggregate '${target}') in ${taskfile}" >&2
            exit 1
        }
        current="$next"
        hops=$((hops + 1))
    done

    echo "FAIL: could not resolve local sub-targets for matrix aggregate '${target}' in ${taskfile} — no task with 'deps' found within ${max_hops} hops (last: '${current}'). CI invokes it as a matrix alias, which this guard can only accept by comparing sub-targets to matrix members." >&2
    exit 1
}

# Validate a matrix-alias line (`task <prefix>:${{ matrix.<field> }}`) against
# the local Taskfile aggregate it claims to cover: every local sub-target
# (the last ':'-separated component of each dep) must have a corresponding
# member in the workflow's own `strategy.matrix.<field>` list for that job.
# One-directional, matching the guard's overall design: an extra matrix member
# with no local counterpart is not a defect this guard cares about; a local
# sub-target with no matrix member is exactly the false-pass D4 reported.
verify_ci_parity_check_matrix_alias() {
    local workflow="$1" taskfile="$2" job="$3" prefix="$4" field="$5"
    local deps dep suffix matrix_values found

    deps="$(verify_ci_parity_resolve_deps "$taskfile" "$prefix")"
    if [ -z "$deps" ]; then
        echo "FAIL: matrix aggregate '${prefix}' in ${taskfile} resolved to zero local sub-targets — cannot validate matrix coverage" >&2
        exit 1
    fi

    matrix_values="$(yq ".jobs.\"${job}\".strategy.matrix.\"${field}\"[]" "$workflow" 2>/dev/null)" || {
        echo "FAIL: could not read strategy.matrix.${field} for job '${job}' in ${workflow}" >&2
        exit 1
    }
    if [ -z "$matrix_values" ]; then
        echo "FAIL: job '${job}' in ${workflow} invokes 'task ${prefix}:\${{ matrix.${field} }}' but strategy.matrix.${field} is empty or missing — cannot validate matrix coverage" >&2
        exit 1
    fi

    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        suffix="${dep##*:}"
        found=0
        while IFS= read -r m; do
            [ -n "$m" ] || continue
            if [ "$m" = "$suffix" ]; then
                found=1
                break
            fi
        done <<EOF
$matrix_values
EOF
        if [ "$found" -eq 0 ]; then
            echo "FAIL (matrix parity): local task '${prefix}' depends on '${dep}' (member '${suffix}'), but job '${job}' in $(basename "$workflow")'s strategy.matrix.${field} does not include '${suffix}' — CI's matrix no longer covers a sub-target verify still runs." >&2
            exit 1
        fi
    done <<EOF
$deps
EOF
}

# Extract every CI-covered target reachable from the required `verify`
# aggregate's needs closure, applying the strict per-line shape above. A
# malformed extraction returning nothing must FAIL loudly, never read as "CI
# covers zero targets" — that is exactly the silent-zero trap this guard
# exists to avoid repeating.
verify_ci_parity_extract_ci_targets() {
    local workflow="$1" taskfile="$2"
    local -a jobs=()
    local job step_count i has_run step_name run_body
    local raw_line trimmed out=""

    while IFS= read -r job; do
        [ -n "$job" ] || continue
        jobs+=("$job")
    done < <(verify_ci_parity_job_closure "$workflow")

    for job in "${jobs[@]}"; do
        step_count="$(yq ".jobs.\"${job}\".steps | length" "$workflow" 2>/dev/null)" || {
            echo "FAIL: could not read steps for job '${job}' in ${workflow}" >&2
            exit 1
        }
        case "$step_count" in
        '' | *[!0-9]*)
            echo "FAIL: could not determine step count for job '${job}' in ${workflow}" >&2
            exit 1
            ;;
        esac

        i=0
        while [ "$i" -lt "$step_count" ]; do
            has_run="$(yq ".jobs.\"${job}\".steps[${i}] | has(\"run\")" "$workflow" 2>/dev/null)" || {
                echo "FAIL: could not inspect job '${job}' step ${i} in ${workflow}" >&2
                exit 1
            }
            if [ "$has_run" = "true" ]; then
                step_name="$(yq ".jobs.\"${job}\".steps[${i}].name" "$workflow" 2>/dev/null)"
                [ -n "$step_name" ] && [ "$step_name" != "null" ] || step_name="step #${i}"
                run_body="$(yq ".jobs.\"${job}\".steps[${i}].run" "$workflow" 2>/dev/null)" || {
                    echo "FAIL: could not read run body for job '${job}' step '${step_name}' in ${workflow}" >&2
                    exit 1
                }

                while IFS= read -r raw_line || [ -n "$raw_line" ]; do
                    trimmed="${raw_line#"${raw_line%%[![:space:]]*}"}"
                    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
                    [ -n "$trimmed" ] || continue
                    case "$trimmed" in
                    '#'*) continue ;;
                    esac

                    if verify_ci_parity_line_is_plain_task "$trimmed"; then
                        out="${out}${trimmed#task }
"
                    elif verify_ci_parity_line_is_matrix_task "$trimmed"; then
                        local mtarget mfield
                        mtarget="${trimmed#task }"
                        mtarget="${mtarget%%:\$\{\{*}"
                        mfield="${trimmed#*matrix.}"
                        mfield="${mfield%%[[:space:]]*}"
                        mfield="${mfield%\}\}}"
                        verify_ci_parity_check_matrix_alias "$workflow" "$taskfile" "$job" "$mtarget" "$mfield"
                        out="${out}${mtarget}
"
                    elif verify_ci_parity_line_mentions_task "$trimmed"; then
                        echo "FAIL: job '${job}' step '${step_name}' in ${workflow} has an unsupported run-line shape (mentions 'task' but is not a bare 'task <name>' invocation): '${trimmed}'" >&2
                        echo "      This guard only recognizes a run: body whose non-comment, non-blank lines are each a single 'task <name>' command (optionally a matrix alias). Rewrite the step to that shape, or the guard cannot tell whether it covers anything." >&2
                        exit 1
                    fi
                done <<EOF
$run_body
EOF
            fi
            i=$((i + 1))
        done
    done

    if [ -z "$out" ]; then
        echo "FAIL: extracted zero CI-covered targets from ${workflow}'s verify-needs closure — the extraction is broken, not the workflow" >&2
        exit 1
    fi
    printf '%s\n' "$out" | sort -u
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
    ci_targets="$(verify_ci_parity_extract_ci_targets "$workflow" "$taskfile")"

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
