#!/usr/bin/env bash
# Reject printf/echo producers piped into grep -q: under pipefail an early
# match can SIGPIPE the producer and turn a match into failure. Use a here-string.
# Scans shell scripts (including conditional Copier names and .sh.jinja),
# task-level Taskfile `cmds:`, `status:`, and `preconditions:` values, short
# task scalar and block-scalar body lines, short task command sequences,
# dynamic-var and precondition `sh:` values, one-line flow-mapping tasks, and
# workflow `run:` bodies. This line-oriented heuristic is not a YAML or shell
# parser: multiline flow collections, next-line plain scalars, task-level
# `if:`, quoted keys, and Taskfile `task:` actions are out of scope. Literal
# and folded block bodies are scanned line by line; continued `sh:` values and
# pipelines split across folded lines are not reconstructed. Quoted pipe text
# may false-positive. Generated repos need no `template/` tree.
# A same-line `# grep-q-pipe: allow -- REASON` exempts an intentional fixture;
# the reason must contain a non-whitespace character. Full-line comments do not
# execute and are ignored. Matching uses POSIX ERE, including flag clusters.
# The heuristic checks common printf/echo ... | grep -q forms. Pipe text inside
# shell quotes can false-positive (use the allow pragma); unsupported forms can
# slip through (preserve the pipe-free idiom by review).
set -euo pipefail
cd "$(dirname "$0")/.."

scan() {
    awk -v kind="$2" '
        function inspect(text, line) {
            if (text ~ /^[[:space:]]*#/) return
            if (text ~ /# grep-q-pipe: allow --[[:space:]]*[^[:space:]]/) return
            if (text ~ /(^|[[;&|()[:space:]\047"])(printf|echo)[[:space:]].*[|][[:space:]]*grep([[:space:]]+-[[:alpha:]]+)*[[:space:]]+-[[:alpha:]]*q[[:alpha:]]*([[:space:]]|$)/) {
                printf "%s:%d: producer piped into grep -q: %s\n", FILENAME, line, text
                bad = 1
            }
        }
        function command(text) {
            if (text ~ /^[[:space:]]*(#|$)/) return
            if (!pending) start = FNR
            pending = pending text
            if (pending ~ /([\\|])[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", pending)
                return
            }
            inspect(pending, start)
            pending = ""
        }
        {
            if (kind == "shell") { command($0); next }
            # Jinja control lines have no YAML indentation and no shell body.
            if ($0 ~ /^[[:space:]]*\[%/) next
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            indent = match($0, /[^ ]/) - 1
            if (active && indent <= boundary) {
                inspect(pending, start)
                pending = ""
                active = 0
            }
            if (kind == "task" && $0 ~ /^[[:space:]]*tasks:[[:space:]]*\{/) inspect($0, FNR)
            if (kind == "task" && $0 ~ /^[[:space:]]*tasks:[[:space:]]*($|#)/) {
                task_map = 1
                task_indent = indent
                task_entry_indent = -1
                task_field_indent = -1
                short_candidate = 0
                next
            }
            if (kind == "task" && task_map && indent <= task_indent) {
                task_map = 0
                task_entry_indent = -1
                task_field_indent = -1
                short_candidate = 0
            }
            if (kind == "task" && task_map) {
                if (task_entry_indent < 0 && indent > task_indent) {
                    task_entry_indent = indent
                }
                if (indent == task_entry_indent) {
                    task_field_indent = -1
                    short_candidate = 0
                    if (match($0, /:[[:space:]]/)) {
                        text = substr($0, RSTART + RLENGTH)
                        if (text ~ /^([#].*)?$/) {
                            short_candidate = 1
                        } else if (text ~ /^[|>][-+]?([1-9][-+]?)?[[:space:]]*(#.*)?$/) {
                            active = 1
                            boundary = indent
                        } else {
                            inspect(text, FNR)
                        }
                    } else if ($0 ~ /:$/) {
                        short_candidate = 1
                    }
                    next
                }
            }
            if (kind == "task" && task_map && short_candidate && indent > task_entry_indent) {
                short_candidate = 0
                if ($0 ~ /^[[:space:]]*-[[:space:]]+/) {
                    active = 1
                    boundary = task_entry_indent
                    command($0)
                    next
                }
            }
            if (kind == "task" && task_map && indent > task_entry_indent && task_field_indent < 0) {
                task_field_indent = indent
            }
            if (kind == "task" && ($0 ~ /^[[:space:]]*(-[[:space:]]+)?sh:[[:space:]]*/ ||
                $0 ~ /[{,][[:space:]]*sh:[[:space:]]*/)) {
                inspect($0, FNR)
                if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?sh:[[:space:]]*[|>][-+]?([1-9][-+]?)?[[:space:]]*(#.*)?$/ ||
                    $0 ~ /[{,][[:space:]]*sh:[[:space:]]*[|>][-+]?([1-9][-+]?)?[[:space:]]*(#.*)?[},]?[[:space:]]*$/) {
                    active = 1
                    boundary = indent
                }
            }
            if ((kind == "task" && task_map && indent == task_field_indent &&
                    $0 ~ /^[[:space:]]*(cmds|status|preconditions):/) ||
                (kind == "workflow" && $0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/)) {
                active = 1
                boundary = indent
                text = $0
                sub(/^[[:space:]]*(-[[:space:]]+)?(cmds|status|preconditions|run):[[:space:]]*/, "", text)
                if (text !~ /^([|>][-+]?|\[)?[[:space:]]*$/) command(text)
                next
            }
            if (active) command($0)
        }
        END { inspect(pending, start); exit bad }
    ' "$1"
}

# Exercise the same scanner before trusting its repository-wide result. Keep
# fixture pipes out of this source so the guard does not flag its own tests.
self_test() (
    fixtures="$(mktemp -d)"
    trap 'rm -rf "$fixtures"' EXIT
    printf 'printf "%%s\\n" "$x" %s grep -q PATTERN\n' '|' >"$fixtures/bad.sh"
    printf 'tasks:\n  test:\n    cmds:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/task.yml"
    printf 'steps:\n  - run: |\n      echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/workflow.yml"
    printf 'tasks:\n  test:\n    cmds: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/inline-task.yml"
    printf 'tasks:\n  test:\n    cmds: [echo "$x" %s grep -q PATTERN]\n' '|' >"$fixtures/flow-task.yml"
    printf 'tasks: { a: echo "$x" %s grep -q PATTERN }\n' '|' >"$fixtures/short-flow-scalar-task.yml"
    printf 'tasks:\n  a: [echo "$x" %s grep -q PATTERN]\n' '|' >"$fixtures/short-flow-sequence-task.yml"
    printf 'tasks:\n  a: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-scalar-task.yml"
    printf 'tasks:\n  a:\n    - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-sequence-task.yml"
    printf 'tasks:\n  a:\n    status:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/status-task.yml"
    printf 'tasks:\n  a:\n    preconditions:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/preconditions-plain-block-task.yml"
    printf 'tasks:\n  a:\n    preconditions: [echo "$x" %s grep -q PATTERN]\n' '|' >"$fixtures/preconditions-plain-flow-task.yml"
    printf 'tasks:\n  a:\n    preconditions:\n      - sh: echo "$x" %s grep -q PATTERN\n        msg: expected condition\n' '|' >"$fixtures/preconditions-task.yml"
    printf 'tasks:\n  a:\n    vars:\n      X:\n        sh: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/dynamic-vars-task.yml"
    printf 'tasks:\n  a:\n    preconditions:\n      - sh: |\n          echo "$x" %s grep -q PATTERN\n        msg: expected condition\n' '|' >"$fixtures/preconditions-sh-block-task.yml"
    printf 'tasks:\n  a:\n    vars:\n      X:\n        sh: |\n          echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/dynamic-vars-sh-block-task.yml"
    printf 'tasks:\n  a: |\n    echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-literal-block-task.yml"
    printf 'tasks:\n  a: >-\n    echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-folded-block-task.yml"
    printf 'tasks:\n    a:\n        - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-indented-sequence-task.yml"
    printf 'tasks:\n    a:\n        preconditions:\n            - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/indented-preconditions-task.yml"
    printf 'tasks:\n  a: {cmds: [echo "$x" %s grep -q PATTERN]}\n' '|' >"$fixtures/flow-mapping-task.yml"
    printf 'steps:\n  - run: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/inline-workflow.yml"
    printf 'echo "$x" %s\n    grep -q PATTERN\n' '|' >"$fixtures/continued.sh"
    printf 'echo "$x" %s grep -Fq PATTERN\n' '|' >"$fixtures/clustered.sh"
    printf 'echo "$x" %s grep -E -q PATTERN\n' '|' >"$fixtures/separate.sh"
    printf 'echo "$x" %s grep -q PATTERN # grep-q-pipe: allow --   \n' '|' >"$fixtures/empty-reason.sh"
    printf 'grep -q PATTERN <<<"$(printf "%%s\\n" "$x")"\n' >"$fixtures/good.sh"
    printf 'tasks:\n  a:\n    vars:\n      X:\n        status:\n          - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/nested-status-not-task-key.yml"
    printf 'tasks:\n  a:\n    desc: a value containing sh: |\n      echo "$x" %s grep -q PATTERN\n    cmds:\n      - echo safe\n' '|' >"$fixtures/sh-text-is-not-key-task.yml"
    printf 'echo "$x" %s grep -q PATTERN # grep-q-pipe: allow -- intentional fixture\n' '|' >"$fixtures/allowed.sh"
    printf 'printf "%%s\\n" "$x" >"$f"; grep -q PATTERN "$f"\n' >"$fixtures/pipe-free.sh"
    for fixture in bad.sh continued.sh clustered.sh separate.sh empty-reason.sh task.yml workflow.yml inline-task.yml inline-workflow.yml flow-task.yml short-flow-scalar-task.yml short-flow-sequence-task.yml short-scalar-task.yml short-sequence-task.yml short-indented-sequence-task.yml short-literal-block-task.yml short-folded-block-task.yml status-task.yml preconditions-plain-block-task.yml preconditions-plain-flow-task.yml preconditions-task.yml preconditions-sh-block-task.yml dynamic-vars-task.yml dynamic-vars-sh-block-task.yml indented-preconditions-task.yml flow-mapping-task.yml; do
        case "$fixture" in
        *.sh) kind=shell ;;
        *task.yml) kind=task ;;
        *workflow.yml) kind=workflow ;;
        *)
            echo "test-grep-q-pipes: unclassified fixture $fixture" >&2
            exit 1
            ;;
        esac
        if scan "$fixtures/$fixture" "$kind" >"$fixtures/output"; then
            echo "test-grep-q-pipes: self-test failed: missed $fixture" >&2
            exit 1
        fi
        if [ ! -s "$fixtures/output" ]; then
            echo "test-grep-q-pipes: self-test failed: no diagnostic for $fixture" >&2
            exit 1
        fi
    done
    for fixture in good.sh allowed.sh pipe-free.sh; do
        if ! scan "$fixtures/$fixture" shell >"$fixtures/output"; then
            echo "test-grep-q-pipes: self-test failed: rejected $fixture" >&2
            cat "$fixtures/output" >&2
            exit 1
        fi
    done
    for fixture in nested-status-not-task-key.yml sh-text-is-not-key-task.yml; do
        if ! scan "$fixtures/$fixture" task >"$fixtures/output"; then
            echo "test-grep-q-pipes: self-test failed: rejected $fixture" >&2
            cat "$fixtures/output" >&2
            exit 1
        fi
    done
)
self_test

roots=()
for dir in scripts template .devcontainer .github taskfiles images sprites; do
    [ ! -d "$dir" ] || roots+=("$dir")
done
failed=0
while IFS= read -r -d '' file; do
    kind=""
    # Copier conditionals can wrap filenames or directory names. Classify the
    # rendered shape, but inspect and report the original source path.
    norm="$(sed 's/\[%[^%]*%\]//g' <<<"$file")"
    case "$norm" in
    *.sh | *.sh.jinja) kind=shell ;;
    */Taskfile.yml | */Taskfile.yaml | */Taskfile.yml.jinja | */Taskfile.yaml.jinja | taskfiles/*.yml | taskfiles/*.yaml | */taskfiles/*.yml | */taskfiles/*.yml.jinja | */taskfiles/*.yaml | */taskfiles/*.yaml.jinja) kind=task ;;
    .github/workflows/*.yml | .github/workflows/*.yaml | */.github/workflows/*.yml | */.github/workflows/*.yml.jinja | */.github/workflows/*.yaml | */.github/workflows/*.yaml.jinja) kind=workflow ;;
    esac
    [ -z "$kind" ] || scan "$file" "$kind" || failed=1
done < <(find "${roots[@]}" -type d \( -name .claude -o -name .agents -o -name node_modules -o -name .venv -o -name .git \) -prune -o -type f -exec printf '%s\000' {} +)
for file in Taskfile.yml Taskfile.yaml; do
    [ ! -f "$file" ] || scan "$file" task || failed=1
done
[ "$failed" -eq 0 ] || exit 1
echo 'test-grep-q-pipes: PASS'
