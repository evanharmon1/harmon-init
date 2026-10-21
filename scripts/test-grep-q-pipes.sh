#!/usr/bin/env bash
# Reject printf/echo producers piped into grep -q: under pipefail an early
# match can SIGPIPE the producer and turn a match into failure. Use a here-string.
# Scans shell scripts (including conditional Copier names and .sh.jinja),
# Taskfile cmds, and workflow run bodies. Generated repos need no template/ tree.
# A same-line `# grep-q-pipe: allow -- REASON` exempts an intentional fixture;
# the reason must contain a non-whitespace character. Full-line comments do not
# execute and are ignored. Matching uses POSIX ERE, including flag clusters.
set -euo pipefail
cd "$(dirname "$0")/.."

scan() {
    awk -v kind="$2" '
        function inspect(text, line) {
            if (text ~ /^[[:space:]]*#/) return
            if (text ~ /# grep-q-pipe: allow --[[:space:]]*[^[:space:]]/) return
            if (text ~ /(^|[;&|()[:space:]\047"])(printf|echo)[[:space:]].*[|][[:space:]]*grep([[:space:]]+-[[:alpha:]]+)*[[:space:]]+-[[:alpha:]]*q[[:alpha:]]*([[:space:]]|$)/) {
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
            if ((kind == "task" && $0 ~ /^[[:space:]]*cmds:/) ||
                (kind == "workflow" && $0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/)) {
                active = 1
                boundary = indent
                text = $0
                sub(/^[[:space:]]*(-[[:space:]]+)?(cmds|run):[[:space:]]*/, "", text)
                if (text !~ /^([|>][-+]?|\[)?[[:space:]]*$/) command(text)
                next
            }
            if (active) command($0)
        }
        END { inspect(pending, start); exit bad }
    ' "$1"
}

roots=()
for dir in scripts template .devcontainer .github taskfiles; do
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
