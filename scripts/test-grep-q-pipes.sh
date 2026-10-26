#!/usr/bin/env bash
# Reject printf/echo producers piped into grep -q: under pipefail an early
# match can SIGPIPE the producer and turn a match into failure. Use a here-string.
# Scans shell scripts (including conditional Copier names and .sh.jinja),
# Taskfile cmds/status blocks, short task scalar/sequence values,
# preconditions `sh:` entries, dynamic-var `sh:` values, one-line flow-mapping
# tasks, and workflow run bodies. It is a line-oriented heuristic, not a YAML
# or shell parser: multiline flow collections and Taskfile `task:`/`defer:`
# actions are out of scope. Quoted pipe text may false-positive; a pipeline
# continued after a trailing comment can be missed. Generated repos need no
# template/ tree.
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
                short_candidate = 0
                next
            }
            if (kind == "task" && task_map && indent <= task_indent) {
                task_map = 0
                short_candidate = 0
            }
            if (kind == "task" && task_map && short_candidate && indent > short_boundary) {
                short_candidate = 0
                if (indent == short_boundary + 2 && $0 ~ /^[[:space:]]*-[[:space:]]+/) {
                    active = 1
                    boundary = short_boundary
                    command($0)
                    next
                }
            }
            if (kind == "task" && task_map && indent == task_indent + 2) {
                if (match($0, /:[[:space:]]/)) {
                    text = substr($0, RSTART + RLENGTH)
                    if (text ~ /^([#].*)?$/) {
                        short_candidate = 1
                        short_boundary = indent
                    } else {
                        inspect(text, FNR)
                    }
                } else if ($0 ~ /:$/) {
                    short_candidate = 1
                    short_boundary = indent
                }
            }
            if (kind == "task" && $0 ~ /(^|[{,[:space:]])sh:[[:space:]]*/) {
                inspect($0, FNR)
                if ($0 ~ /(^|[{,[:space:]])sh:[[:space:]]*[|>][-+]?[[:space:]]*(#.*)?$/) {
                    active = 1
                    boundary = indent
                }
            }
            if ((kind == "task" && $0 ~ /^[[:space:]]*(cmds|status):/) ||
                (kind == "workflow" && $0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/)) {
                active = 1
                boundary = indent
                text = $0
                sub(/^[[:space:]]*(-[[:space:]]+)?(cmds|status|run):[[:space:]]*/, "", text)
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
    printf 'tasks:\n  a: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-scalar-task.yml"
    printf 'tasks:\n  a:\n    - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/short-sequence-task.yml"
    printf 'tasks:\n  a:\n    status:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/status-task.yml"
    printf 'tasks:\n  a:\n    preconditions:\n      - sh: echo "$x" %s grep -q PATTERN\n        msg: expected condition\n' '|' >"$fixtures/preconditions-task.yml"
    printf 'tasks:\n  a:\n    vars:\n      X:\n        sh: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/dynamic-vars-task.yml"
    printf 'tasks:\n  a: {cmds: [echo "$x" %s grep -q PATTERN]}\n' '|' >"$fixtures/flow-mapping-task.yml"
    printf 'steps:\n  - run: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/inline-workflow.yml"
    printf 'echo "$x" %s\n    grep -q PATTERN\n' '|' >"$fixtures/continued.sh"
    printf 'echo "$x" %s grep -Fq PATTERN\n' '|' >"$fixtures/clustered.sh"
    printf 'echo "$x" %s grep -E -q PATTERN\n' '|' >"$fixtures/separate.sh"
    printf 'echo "$x" %s grep -q PATTERN # grep-q-pipe: allow --   \n' '|' >"$fixtures/empty-reason.sh"
    printf 'grep -q PATTERN <<<"$(printf "%%s\\n" "$x")"\n' >"$fixtures/good.sh"
    printf 'echo "$x" %s grep -q PATTERN # grep-q-pipe: allow -- intentional fixture\n' '|' >"$fixtures/allowed.sh"
    printf 'printf "%%s\\n" "$x" >"$f"; grep -q PATTERN "$f"\n' >"$fixtures/pipe-free.sh"
    for fixture in bad.sh continued.sh clustered.sh separate.sh empty-reason.sh task.yml workflow.yml inline-task.yml inline-workflow.yml flow-task.yml short-flow-scalar-task.yml short-scalar-task.yml short-sequence-task.yml status-task.yml preconditions-task.yml dynamic-vars-task.yml flow-mapping-task.yml; do
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
