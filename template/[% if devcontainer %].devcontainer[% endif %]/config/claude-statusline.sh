#!/usr/bin/env bash
# claude-statusline.sh — Claude Code `statusLine` renderer for the dev container.
#
# Gives a container session the same four-line status line as a host session:
#
#   📁 ~/git/my-project  🌿 main  🔀 #512 ✓  ▪ session name  · a1b2c3d4
#   🧠 ▕████░░░░░░░░░░░░▏ 24%  760k left  🤖 Opus 5 1M · medium · ⚡ · 💭  📟 v2.1.220
#   💰 $0.43  ✎ +120/-45  ⏱ 11m session
#   🚦 5h ▕█░░░░░░▏ 🔄 2h13m   ·   7d ▕░░░░░░░▏ 🔄 4d20h
#
# Reading down: where you are, how much room and horsepower you have left, what
# the session has cost, and how close the subscription limits are to biting.
# Line 4's bars are the same gauge as line 2's at roughly half the width and a
# muted palette — same reading habit, lower priority.
#
# Claude Code pipes the session JSON on stdin and renders whatever we print.
# Baked into the image at /etc/claude-code/statusline.sh (see the Dockerfile) so
# it survives the ~/.claude volume mount, and wired up via the `statusLine` key
# in config/claude-user-defaults.json — a seed default the user can override.
#
# This runs on every keystroke-ish refresh, so it is built to stay cheap: two
# forks total (one `jq`, one `date`) and no others. In particular there is no
# `git` subprocess — the branch is read straight out of .git/HEAD — no logging,
# and no network. Everything else is bash builtins, and the helpers below
# deliberately return through $REPLY rather than $(...) because a command
# substitution is a subshell fork; at ~20 segments a render that is the
# difference between a couple of forks and two dozen.
#
# `set -e` is deliberately omitted: a single failing probe (no git repo, a
# field a newer payload no longer emits) must degrade to a shorter line rather
# than blank the status line entirely.
set -uo pipefail

input=$(cat)

# ---- toggles (override in the environment) ----
: "${STATUSLINE_COLOR:=1}"     # 0 disables color (NO_COLOR is honored too)
: "${STATUSLINE_HYPERLINK:=1}" # 0 disables the OSC-8 link on the PR number
: "${STATUSLINE_CTX_WIDTH:=16}"
: "${STATUSLINE_RL_WIDTH:=7}" # deliberately under half the context bar
: "${STATUSLINE_RL_PCT:=0}"   # 1 also prints the exact limit percentage

[ -n "${NO_COLOR:-}" ] && STATUSLINE_COLOR=0

# ---- color, precomputed (no forks at render time) ----
if [ "$STATUSLINE_COLOR" = 1 ]; then
    e=$'\033'
    RST="${e}[0m"
    DIR="${e}[38;5;117m"   # sky blue
    ROOT="${e}[38;5;103m"  # muted blue
    GIT="${e}[38;5;150m"   # soft green
    PR="${e}[38;5;213m"    # pink
    MODEL="${e}[38;5;147m" # light purple
    # Both grays sit a step brighter than a "secondary text" palette would
    # suggest. Anything below ~244 disappears into a dark terminal background —
    # legible in a screenshot, invisible in use.
    META="${e}[38;5;250m" # gray
    DIM="${e}[38;5;245m"  # softer gray
    COST="${e}[38;5;180m" # soft yellow
    OK="${e}[38;5;158m"   # mint
    WARN="${e}[38;5;215m" # peach
    HOT="${e}[38;5;203m"  # coral
    # Same three signals a few shades down, for the usage-limit bars. They are
    # the same gauge as the context window and must read that way, so the hues
    # match — but they sit further back, and a duller palette says "same idea,
    # lower priority" without needing a second shape to say it.
    OK_D="${e}[38;5;71m"    # moss
    WARN_D="${e}[38;5;173m" # clay
    HOT_D="${e}[38;5;167m"  # brick
else
    RST='' DIR='' ROOT='' GIT='' PR='' MODEL='' META='' DIM='' COST=''
    OK='' WARN='' HOT='' OK_D='' WARN_D='' HOT_D=''
fi

# ---- payload ----
# One jq invocation emits every field in a fixed order. Control bytes are
# stripped inside jq: Claude Code renders our stdout as ANSI, and a directory,
# branch, or session name may legally contain ESC or a newline — so without
# this a checkout under a crafted path could inject escape sequences (OSC 52
# clipboard writes, extra status lines) on every refresh, or desync the field
# split below.
if ! command -v jq >/dev/null 2>&1; then
    printf '📁 %s\n' "${PWD//[[:cntrl:]]/}"
    exit 0
fi

fields=$(printf '%s' "$input" | jq -r '
  def s: (. // "") | tostring | explode
         | map(select(. > 31 and . != 127)) | implode;
  def n: (. // 0) | if type == "number" then floor else 0 end;
  [ ((.workspace.current_dir // .cwd)   | s)
  , (.workspace.project_dir             | s)
  , (.model.display_name                | s)
  , (.effort.level                      | s)
  , ((.fast_mode        == true)        | s)
  , ((.thinking.enabled == true)        | s)
  , (.version                           | s)
  , (.output_style.name                 | s)
  , (.session_id                        | s | .[0:8])
  , (.session_name                      | s)
  , ((.context_window.used_percentage
       // (100 - (.context_window.remaining_percentage // 100))) | n)
  , (.context_window.context_window_size    | n)
  , (.cost.total_cost_usd                   | (. // 0) | tostring)
  , (.cost.total_lines_added                | n)
  , (.cost.total_lines_removed              | n)
  , (.cost.total_duration_ms                | n)
  , (.pr.number                             | s)
  , (.pr.url                                | s)
  , (.pr.review_state                       | s)
  , (.rate_limits.five_hour.used_percentage | n)
  , (.rate_limits.five_hour.resets_at       | n)
  , (.rate_limits.seven_day.used_percentage | n)
  , (.rate_limits.seven_day.resets_at       | n)
  ] | map(tostring) | join("\u001f")' 2>/dev/null)

# Split on U+001F (unit separator), not a tab: TAB is IFS *whitespace*, so
# `read` would collapse runs of it and silently shift every field after the
# first empty one. The filter above strips control bytes from every value, so
# a US can never occur inside one.
IFS=$'\037' read -r cur_dir proj_dir model effort fast thinking cc_ver style \
    sid sname ctx_pct ctx_size cost lines_add lines_del dur_ms \
    pr_num pr_url pr_state rl5_pct rl5_at rl7_pct rl7_at <<<"$fields"

[ -n "${model:-}" ] || model="Claude"
[ -n "${cur_dir:-}" ] || cur_dir="$PWD"

# One clock read serves every relative figure below. The wall-clock time itself
# is deliberately not shown: the terminal, the OS, and the wall already have it,
# and it is the one number here that says nothing about the session.
now=$(date +%s)

# ---- helpers (results land in $REPLY) ----
num() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac }

# bar <used-pct> <width> — the filled portion represents consumption.
bar() {
    local pct=$1 width=$2 i=0
    ((pct < 0)) && pct=0
    ((pct > 100)) && pct=100
    local filled=$((pct * width / 100))
    REPLY='▕'
    while ((i < width)); do
        if ((i < filled)); then REPLY+='█'; else REPLY+='░'; fi
        ((i++))
    done
    REPLY+='▏'
}

# heat <used-pct> [ok] [warn] [hot] — go/caution/stop by consumption, at the
# same 60/80 thresholds everywhere. The palette is an argument so the limit
# bars can run the muted set without forking the thresholds along with it.
heat() {
    if (($1 >= 80)); then
        REPLY=${4:-$HOT}
    elif (($1 >= 60)); then
        REPLY=${3:-$WARN}
    else
        REPLY=${2:-$OK}
    fi
}

# compact <tokens> — 940k / 1.2M, so the figure never jitters in width.
compact() {
    local v=$1
    if ((v >= 1000000)); then
        printf -v REPLY '%d.%dM' $((v / 1000000)) $((v % 1000000 / 100000))
    elif ((v >= 1000)); then
        printf -v REPLY '%dk' $((v / 1000))
    else
        REPLY=$v
    fi
}

# dur <seconds> — 1d6h / 2h13m / 14m / 45s, dropping units that read as noise.
dur() {
    local s=$1
    if ((s >= 86400)); then
        printf -v REPLY '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
    elif ((s >= 3600)); then
        printf -v REPLY '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
    elif ((s >= 60)); then
        printf -v REPLY '%dm' $((s / 60))
    else
        printf -v REPLY '%ds' "$s"
    fi
}

tilde() {
    case "$1" in
    "$HOME") REPLY='~' ;;
    "$HOME"/*) REPLY="~${1#"$HOME"}" ;;
    *) REPLY=$1 ;;
    esac
}

# seg <emoji> <color> <text>
seg() { printf '  %s %s%s%s' "$1" "$2" "$3" "$RST"; }

# ---- git branch, without forking git ----
# Walk up from the session directory to the first .git. In a linked worktree
# .git is a FILE holding `gitdir: <path>`, and that path's HEAD is the one that
# describes the checkout you are actually sitting in.
branch='' gitdir='' d=$cur_dir
while [ -n "$d" ] && [ "$d" != / ]; do
    if [ -d "$d/.git" ]; then
        gitdir="$d/.git"
        break
    elif [ -f "$d/.git" ]; then
        read -r _ gitdir <"$d/.git" 2>/dev/null
        case "$gitdir" in /*) ;; *) gitdir="$d/$gitdir" ;; esac
        break
    fi
    # A relative or otherwise slashless value leaves `${d%/*}` equal to `d`,
    # which would spin here forever. Stop instead of ascending nowhere.
    parent=${d%/*}
    [ "$parent" = "$d" ] && break
    d=$parent
done
if [ -n "$gitdir" ] && [ -r "$gitdir/HEAD" ]; then
    read -r head <"$gitdir/HEAD" 2>/dev/null
    case "$head" in
    "ref: refs/heads/"*) branch="${head#ref: refs/heads/}" ;;
    *) branch="${head:0:7}" ;;
    esac
    branch="${branch//[[:cntrl:]]/}"
fi

# =====================================================================
# line 1 — where you are
# =====================================================================
tilde "$cur_dir"
printf '📁 %s%s%s' "$DIR" "$REPLY" "$RST"

# The launch directory only earns space when it is not the one you are in.
if [ -n "${proj_dir:-}" ] && [ "$proj_dir" != "$cur_dir" ]; then
    tilde "$proj_dir"
    seg '⌂' "$ROOT" "$REPLY"
fi

[ -n "$branch" ] && seg '🌿' "$GIT" "$branch"

if num "${pr_num:-}"; then
    label="#$pr_num"
    # OSC-8 hides pr.url behind the number: clickable, zero extra columns.
    # Terminals that do not implement it ignore the sequence.
    if [ "$STATUSLINE_HYPERLINK" = 1 ] && [ -n "${pr_url:-}" ] && [ "$STATUSLINE_COLOR" = 1 ]; then
        label="${e}]8;;${pr_url}${e}\\${label}${e}]8;;${e}\\"
    fi
    case "${pr_state:-}" in
    approved) label+=' ✓' ;;
    changes_requested) label+=' ✗' ;;
    pending | commented) label+=' ⋯' ;;
    esac
    seg '🔀' "$PR" "$label"
fi

[ -n "${sname:-}" ] && seg '▪' "$META" "$sname"
[ -n "${sid:-}" ] && seg '·' "$DIM" "$sid"

# =====================================================================
# line 2 — context window, and what is answering
# =====================================================================
printf '\n'
if num "${ctx_pct:-}"; then
    heat "$ctx_pct"
    ctx_color=$REPLY
    bar "$ctx_pct" "$STATUSLINE_CTX_WIDTH"
    printf '🧠 %s%s %s%%%s' "$ctx_color" "$REPLY" "$ctx_pct" "$RST"
    # Derive the headroom from the same percentage the bar uses. The raw token
    # sum is more precise but disagrees with used_percentage (which also counts
    # reserved output tokens), and a bar that contradicts the number beside it
    # is worse than a slightly rounded figure.
    if num "${ctx_size:-}" && ((ctx_size > 0)); then
        compact $((ctx_size * (100 - ctx_pct) / 100))
        printf ' %s%s left%s' "$DIM" "$REPLY" "$RST"
    fi
else
    printf '🧠 %scontext n/a%s' "$DIM" "$RST"
fi

# "Opus 5 (1M context)" is accurate and too wide; the parenthetical is the only
# part that varies between the two, so keep it and drop the filler word.
mode="${model/ (1M context)/ 1M}"
[ -n "${effort:-}" ] && mode+=" · $effort"
[ "${fast:-}" = true ] && mode+=' · ⚡'
[ "${thinking:-}" = true ] && mode+=' · 💭'
seg '🤖' "$MODEL" "$mode"

[ -n "${cc_ver:-}" ] && seg '📟' "$DIM" "v$cc_ver"
[ -n "${style:-}" ] && [ "$style" != default ] && seg '🎨' "$META" "$style"

# =====================================================================
# line 3 — what the session has spent
# =====================================================================
printf '\n'
case "${cost:-}" in
'' | *[!0-9.]*) cost=0 ;;
esac
printf '💰 %s$%.2f%s' "$COST" "$cost" "$RST"

if num "${lines_add:-}" && num "${lines_del:-}" && ((lines_add + lines_del > 0)); then
    printf '  ✎ %s+%s%s/%s-%s%s' "$OK" "$lines_add" "$RST" "$HOT" "$lines_del" "$RST"
fi

if num "${dur_ms:-}" && ((dur_ms > 0)); then
    dur $((dur_ms / 1000))
    seg '⏱' "$META" "$REPLY session"
fi

# =====================================================================
# line 4 — subscription usage limits
# =====================================================================
# Two independent rolling windows, each with its own allowance and its own
# reset, on a line of their own. Each reads as: window, how full it is, how long
# until it empties. Same bar and same heat colors as the context window, so one
# reading habit covers both — but at well under half the width, because these
# are a background concern and should not compete with the context gauge for
# attention at a glance.
rl() {
    local label=$1 pct=$2 at=$3 gauge
    num "$pct" || return 0
    heat "$pct" "$OK_D" "$WARN_D" "$HOT_D"
    gauge=$REPLY
    bar "$pct" "$STATUSLINE_RL_WIDTH"
    gauge+="$REPLY$RST"
    ((STATUSLINE_RL_PCT)) && gauge+="$DIM ${pct}%$RST"
    printf '%s%s%s %s' "$META" "$label" "$RST" "$gauge"
    # A reset already in the past means a stale payload, not "due now" — drop
    # it rather than render a countdown that has stopped meaning anything.
    if num "$at" && ((at > now)); then
        dur $((at - now))
        printf ' %s🔄 %s%s' "$DIM" "$REPLY" "$RST"
    fi
}
if num "${rl5_pct:-}" || num "${rl7_pct:-}"; then
    printf '\n🚦 '
    rl 5h "${rl5_pct:-}" "${rl5_at:-}"
    if num "${rl5_pct:-}" && num "${rl7_pct:-}"; then
        printf '%s   ·   %s' "$DIM" "$RST"
    fi
    rl 7d "${rl7_pct:-}" "${rl7_at:-}"
fi

printf '\n'
