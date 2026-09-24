#!/usr/bin/env bash
# Behavioural fixtures for the template's render-parity guard
# (template/scripts/[% if project_type == 'web-astro' %]render-parity.sh[% endif %]):
# two small fixture pages exercise its `--compare` mode (which diffs two
# already-built dist/ directories directly, skipping the git/build pipeline)
# against the exact incident this guard exists to catch (harmon-init#1350,
# ponderousdev/lawnomator-site#192 commit b74aaaf): a reflowed inline newline
# between `</a>` and `.` renders as a stray visible space under
# `compressHTML: false`.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

tmp="$(mktemp -d -t harmon-init-render-parity-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

# The template source ships render-parity.sh under a jinja-bracketed filename
# (only rendered to a plain `render-parity.sh` in a generated repo), and its
# content refers to its companion by that RENDERED name — so exercising it
# here needs both files copied to their real post-render names first.
mkdir -p "${tmp}/scripts"
cp "${repo_root}/template/scripts/[% if project_type == 'web-astro' %]render-parity.sh[% endif %]" \
    "${tmp}/scripts/render-parity.sh"
cp "${repo_root}/template/scripts/[% if project_type == 'web-astro' %]render-parity-extract.mjs[% endif %]" \
    "${tmp}/scripts/render-parity-extract.mjs"
chmod +x "${tmp}/scripts/render-parity.sh"
guard="${tmp}/scripts/render-parity.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

write_page() {
    # write_page <dir> <body>
    mkdir -p "$1"
    printf '<html><body>%s</body></html>\n' "$2" >"$1/index.html"
}

run_guard() {
    status=0
    output="$("$guard" --compare "$1" "$2" 2>&1)" || status=$?
}

echo "==> identical pages -> passes"
write_page "${tmp}/match/a" '<p>See our <a href="/privacy">Privacy Policy</a>.</p>'
write_page "${tmp}/match/b" '<p>See our <a href="/privacy">Privacy Policy</a>.</p>'
run_guard "${tmp}/match/a" "${tmp}/match/b"
[ "$status" -eq 0 ] || fail "identical pages: guard failed; output: ${output}"

echo "==> a reflowed inline newline between </a> and . -> fails (the exact lawnomator-site#192 incident)"
write_page "${tmp}/reflow/a" '<p>See our <a href="/privacy">Privacy Policy</a>.</p>'
mkdir -p "${tmp}/reflow/b"
printf '<html><body><p>See our <a href="/privacy">Privacy Policy</a>\n.</p></body></html>\n' \
    >"${tmp}/reflow/b/index.html"
run_guard "${tmp}/reflow/a" "${tmp}/reflow/b"
[ "$status" -ne 0 ] || fail "reflowed newline: guard passed; output: ${output}"
case "$output" in
*"Privacy Policy."*"Privacy Policy ."*) : ;;
*)
    case "$output" in
    *"DIFF index.html"*) : ;;
    *) fail "reflowed newline: output lacks a diff for index.html; output: ${output}" ;;
    esac
    ;;
esac

echo "==> a page missing on one side -> fails"
write_page "${tmp}/missing/a" '<p>Only on A</p>'
mkdir -p "${tmp}/missing/b"
run_guard "${tmp}/missing/a" "${tmp}/missing/b"
[ "$status" -ne 0 ] || fail "missing page: guard passed; output: ${output}"

echo "==> a reflowed newline against an inline <svg> icon -> fails (Codex review round 2, P2)"
write_page "${tmp}/svg/a" '<p>Open<svg><path d="x"/></svg>.</p>'
mkdir -p "${tmp}/svg/b"
printf '<html><body><p>Open<svg><path d="x"/></svg>\n.</p></body></html>\n' \
    >"${tmp}/svg/b/index.html"
run_guard "${tmp}/svg/a" "${tmp}/svg/b"
[ "$status" -ne 0 ] || fail "svg adjacency: guard passed; output: ${output}"

echo "==> leading whitespace at a <pre> boundary -> fails (Codex review round 2, P2)"
write_page "${tmp}/pre/a" '<pre> a</pre>'
write_page "${tmp}/pre/b" '<pre>a</pre>'
run_guard "${tmp}/pre/a" "${tmp}/pre/b"
[ "$status" -ne 0 ] || fail "pre boundary: guard passed; output: ${output}"

echo "==> identical <pre> content, internal whitespace preserved -> passes"
write_page "${tmp}/pre-match/a" '<pre>a  b</pre>'
write_page "${tmp}/pre-match/b" '<pre>a  b</pre>'
run_guard "${tmp}/pre-match/a" "${tmp}/pre-match/b"
[ "$status" -eq 0 ] || fail "pre identical: guard failed; output: ${output}"

echo "==> a collapsed nbsp reads as different from two nbsp -> fails (Codex review round 2, P2)"
write_page "${tmp}/nbsp/a" '<p>a&nbsp;&nbsp;b</p>'
write_page "${tmp}/nbsp/b" '<p>a b</p>'
run_guard "${tmp}/nbsp/a" "${tmp}/nbsp/b"
[ "$status" -ne 0 ] || fail "nbsp: guard passed; output: ${output}"

echo "render-parity guard cases: PASS"
