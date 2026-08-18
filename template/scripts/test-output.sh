#!/usr/bin/env bash
# Unit-test the shared output library without requiring a terminal or gum.
set -euo pipefail
cd "$(dirname "$0")/.."

lib="$PWD/scripts/lib/output.sh"
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

echo "==> redirected output is stable ASCII"
plain="$(NO_COLOR=1 bash -c '. "$1"; section_header "Action"; checkline ok "Step" "complete"; output_done "finished"' _ "$lib")"
case "$plain" in
*$'\033'*) fail "NO_COLOR output contains ANSI escapes" ;;
esac
case "$plain" in
*'==> Action'*'[x] Step — complete'*'DONE: finished'*) ;;
*) fail "plain output omitted the stable heading, outcome, or summary" ;;
esac

echo "==> a capable terminal gets ANSI color and Unicode"
color="$(env -u NO_COLOR PATH=/usr/bin:/bin LANG=C.UTF-8 TERM=xterm-256color OUTPUT_TEST_TTY=1 \
    bash -c '. "$1"; section_header "Action"; checkline ok "Step" "complete"' _ "$lib")"
case "$color" in *$'\033['*) ;; *) fail "terminal output did not include ANSI color" ;; esac
case "$color" in *'◆ Action'*'✓'*'Step — complete'*) ;;
*) fail "terminal output did not include the Unicode presentation" ;;
esac

echo "==> TERM=dumb wins over forced color"
dumb="$(TERM=dumb CLICOLOR_FORCE=1 LANG=C.UTF-8 \
    bash -c '. "$1"; checkline ok "Step"' _ "$lib")"
case "$dumb" in
*$'\033'*) fail "TERM=dumb output contains ANSI escapes" ;;
esac
case "$dumb" in
*'[x] Step'*) ;;
*) fail "TERM=dumb output did not fall back to ASCII" ;;
esac

echo "==> non-terminal commands preserve status without control sequences"
set +e
non_tty="$(OUTPUT_FD=2 bash -c '. "$1"; output_run "Working" bash -c "exit 37"' _ "$lib" 2>&1)"
non_tty_rc=$?
set -e
[ "$non_tty_rc" -eq 37 ] || fail "output_run changed exit 37 to $non_tty_rc"
case "$non_tty" in
*$'\033'*) fail "non-terminal output_run emitted control sequences" ;;
esac

echo "==> spinner cleanup leaves no job and preserves command status"
set +e
spinner="$(env -u CI -u NO_COLOR OUTPUT_FD=2 OUTPUT_TEST_TTY=1 OUTPUT_TEST_SPINNER=1 OUTPUT_SPINNER_DELAY=0.01 \
    LANG=C.UTF-8 TERM=xterm-256color bash -c '
        . "$1"
        output_run "Working" bash -c "sleep 0.04; exit 23"
        rc=$?
        [ -z "$(jobs -pr)" ] || exit 91
        exit "$rc"
    ' _ "$lib" 2>&1)"
spinner_rc=$?
set -e
[ "$spinner_rc" -eq 23 ] || fail "spinner path returned $spinner_rc instead of 23"
case "$spinner" in
*$'\033[2K'*'Working'*) ;;
*) fail "forced terminal path did not animate" ;;
esac
case "$spinner" in
*$'\r\033[2K') ;;
*) fail "spinner did not erase its final frame" ;;
esac

echo "==> NO_COLOR disables animation even on a terminal"
no_color_spinner="$(env -u CI NO_COLOR=1 OUTPUT_FD=2 OUTPUT_TEST_TTY=1 OUTPUT_TEST_SPINNER=1 \
    bash -c '. "$1"; output_run "Working" true' _ "$lib" 2>&1)"
case "$no_color_spinner" in
*$'\033'*) fail "NO_COLOR spinner path emitted terminal controls" ;;
esac

echo "PASS: shared output fallbacks and spinner lifecycle"
