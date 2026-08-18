#!/usr/bin/env bash
# Shared terminal presentation for status boards and action scripts.
#
# Source this file after resolving the repository root. It has no required
# dependencies: ANSI color and Unicode are used only on a capable terminal,
# gum is an optional enhancement, and redirected/NO_COLOR/TERM=dumb output is
# stable ASCII. Action scripts may set OUTPUT_FD=2 before sourcing so Task's
# grouped stdout does not hide live progress.

OUTPUT_FD="${OUTPUT_FD:-1}"

output_is_tty() {
    if [ "${OUTPUT_TEST_TTY:-0}" = 1 ]; then
        return 0
    fi
    [ -t "${OUTPUT_FD}" ]
}

output_emit() {
    if [ "${OUTPUT_FD}" = 2 ]; then
        printf "$@" >&2
    else
        printf "$@"
    fi
}

output_write() {
    if [ "${OUTPUT_FD}" = 2 ]; then
        cat >&2
    else
        cat
    fi
}

# NO_COLOR disables gum as well as ANSI. Besides respecting the convention,
# that makes logs and test snapshots plain, greppable text.
HAS_GUM=false
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] && command -v gum >/dev/null 2>&1; then
    HAS_GUM=true
fi

USE_COLOR=false
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    if output_is_tty || { [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE}" != 0 ]; }; then
        USE_COLOR=true
    fi
fi

USE_UNICODE=false
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
*[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
    if $USE_COLOR; then USE_UNICODE=true; fi
    ;;
esac

# Every gum call is piped. This keeps gum from probing the terminal background
# with OSC 11 and waiting several seconds on terminals that do not answer. Its
# stderr still sees the terminal, while CLICOLOR_FORCE restores styling.
gum_style() {
    CLICOLOR_FORCE=1 gum style "$@" | cat
}

section_header() {
    local title="$1"
    if $HAS_GUM && output_is_tty; then
        gum_style --bold --foreground 212 --border-foreground 240 \
            --border rounded --padding "0 1" -- "$title" | output_write
    elif $USE_COLOR; then
        output_emit '\n\033[1;35m◆ %s\033[0m\n' "$title"
        output_emit '\033[2;90m────────────────────────────────────────\033[0m\n'
    else
        output_emit '\n==> %s\n' "$title"
        output_emit '%s\n' '----------------------------------------'
    fi
}

section_box() {
    local content
    content="$(cat)"
    if $HAS_GUM && output_is_tty; then
        printf '%s\n' "$content" | gum_style --border rounded \
            --border-foreground 240 --padding "0 1" --margin "0 0" | output_write
    else
        output_emit '%s\n\n' "$content"
    fi
}

kv() {
    local key="$1" val="$2" styled_key
    if $HAS_GUM && output_is_tty; then
        styled_key="$(gum_style --bold --foreground 39 "$key:")"
        output_emit '  %s  %s\n' "$styled_key" "$val"
    elif $USE_COLOR; then
        output_emit '  \033[1;36m%-20s\033[0m %s\n' "$key:" "$val"
    else
        output_emit '  %-20s %s\n' "$key:" "$val"
    fi
}

# c SGR TEXT — emit TEXT wrapped in ANSI when color is active. This writes to
# stdout deliberately: callers use it inside command substitutions.
c() {
    if $USE_COLOR; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

if $USE_UNICODE; then
    I_OK="$(c '1;32' '✓')"
    I_NO="$(c '1;31' '✗')"
    I_UNKNOWN="$(c '1;33' '?')"
    I_NA="$(c '2' '–')"
    I_INFO="$(c '1;36' '•')"
else
    I_OK='[x]'
    I_NO='[ ]'
    I_UNKNOWN='[?]'
    I_NA='[-]'
    I_INFO=' * '
fi

subhead() {
    if $USE_UNICODE; then
        output_emit '\n  %s\n' "$(c '1;36' "▸ $1")"
    else
        output_emit '\n  > %s\n' "$1"
    fi
}

bar() {
    local pct="$1" width=20 i=0 fill="" track="" filled
    filled=$((pct * width / 100))
    [ "${filled}" -gt "${width}" ] && filled="${width}"
    [ "${filled}" -lt 0 ] && filled=0
    while [ "${i}" -lt "${width}" ]; do
        if [ "${i}" -lt "${filled}" ]; then
            if $USE_UNICODE; then fill="${fill}█"; else fill="${fill}#"; fi
        else
            if $USE_UNICODE; then track="${track}░"; else track="${track}-"; fi
        fi
        i=$((i + 1))
    done
    printf '%s%s' "$(c '32' "${fill}")" "$(c '2' "${track}")"
}

SETUP_OK=0
SETUP_NO=0
SETUP_UNKNOWN=0
SETUP_NA=0

# checkline STATUS LABEL [DETAIL]
# STATUS: ok | no | unknown | na | info
checkline() {
    local status="$1" label="$2" detail="${3:-}" icon=""
    case "$status" in
    ok) icon="$I_OK" && SETUP_OK=$((SETUP_OK + 1)) ;;
    no) icon="$I_NO" && SETUP_NO=$((SETUP_NO + 1)) ;;
    unknown) icon="$I_UNKNOWN" && SETUP_UNKNOWN=$((SETUP_UNKNOWN + 1)) ;;
    na) icon="$I_NA" && SETUP_NA=$((SETUP_NA + 1)) ;;
    info) icon="$I_INFO" ;;
    *)
        output_emit 'output: unknown check status: %s\n' "$status"
        return 2
        ;;
    esac
    if [ -n "$detail" ]; then
        output_emit '  %s %s — %s\n' "$icon" "$label" "$detail"
    else
        output_emit '  %s %s\n' "$icon" "$label"
    fi
}

output_done() {
    if $USE_UNICODE; then
        output_emit '\n%s %s\n' "$(c '1;32' '✨')" "$(c '1' "$1")"
    else
        output_emit '\nDONE: %s\n' "$1"
    fi
}

output_spinner_loop() {
    local label="$1" i=0 frame
    local unicode_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local ascii_frames=('|' '/' '-' '\\')
    trap 'exit 0' HUP INT TERM
    while :; do
        if $USE_UNICODE; then
            frame="${unicode_frames[$i]}"
            i=$(((i + 1) % ${#unicode_frames[@]}))
        else
            frame="${ascii_frames[$i]}"
            i=$(((i + 1) % ${#ascii_frames[@]}))
        fi
        printf '\r\033[2K%s %s' "$(c '1;35' "$frame")" "$label" >&2
        sleep "${OUTPUT_SPINNER_DELAY:-0.08}"
    done
}

# output_run LABEL COMMAND... — keep COMMAND in the foreground and animate a
# background-only indicator. The subshell owns every trap, always erases the
# frame, and returns COMMAND's exact status. Redirected/CI output runs COMMAND
# directly and emits no control sequences.
output_run() (
    local label="$1" spinner_pid="" rc
    shift

    if [ "${OUTPUT_FD}" != 2 ] || { ! output_is_tty && [ "${OUTPUT_TEST_SPINNER:-0}" != 1 ]; } ||
        [ "${CI:-}" = true ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; then
        "$@"
        return
    fi

    output_spinner_loop "$label" &
    spinner_pid=$!
    output_spinner_cleanup() {
        if [ -n "$spinner_pid" ]; then
            kill "$spinner_pid" 2>/dev/null || true
            wait "$spinner_pid" 2>/dev/null || true
            spinner_pid=""
        fi
        printf '\r\033[2K' >&2
    }
    trap 'output_spinner_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if "$@"; then rc=0; else rc=$?; fi
    output_spinner_cleanup
    trap - EXIT HUP INT TERM
    return "$rc"
)
