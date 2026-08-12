#!/usr/bin/env bash
# test-open-devcontainer.sh — unit-test the client-side dev container launcher.
#
# The launcher's whole job is reading someone else's data format: VS Code's
# recents list, a JSON blob inside a SQLite row, holding URIs whose authority
# is hex-encoded JSON. Everything that can go wrong is in that parse, and none
# of it needs VS Code — so each case here builds a throwaway state.vscdb with
# a known recents payload and asserts what the launcher makes of it.
#
# Launching is asserted without opening anything: OPEN_DEVCONTAINER_DRY_RUN=1
# prints the command, and CODE_BIN points at a stub that records its arguments.
# Run via `task test:open-devcontainer`.
set -euo pipefail
cd "$(dirname "$0")/.."
launcher="scripts/open-devcontainer.sh"

[ -r "$launcher" ] || {
    echo "TEST FAIL: $launcher not found" >&2
    exit 1
}

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp_root="$(mktemp -d -t harmon-open-devcontainer-XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

# hex <string> — hex-encode ASCII in pure bash, so building a fixture URI needs
# no xxd (absent on stock macOS) and no second language.
hex() {
    local s="$1" i out=""
    for ((i = 0; i < ${#s}; i++)); do
        out="${out}$(printf '%02x' "'${s:i:1}")"
    done
    printf '%s' "$out"
}

# dc_uri <hostPath> <remote> <container path> [plus] — a dev-container folder
# URI shaped exactly like the ones VS Code stores. The 4th argument chooses how
# the `+` after `dev-container` is written: VS Code emits both forms, and the
# launcher has to accept either.
dc_uri() {
    local blob plus="${4-+}"
    blob="$(hex "{\"hostPath\":\"$1\",\"localDocker\":false}")"
    printf 'vscode-remote://dev-container%s%s@%s%s' "$plus" "$blob" "$2" "$3"
}

# make_db <name> <json> — a state.vscdb holding <json> under the recents key.
# Written with python3's stdlib sqlite3 for the same reason the launcher reads
# it that way: the sqlite3 CLI is not present on every machine that runs this.
make_db() {
    local path="${tmp_root}/$1.vscdb"
    python3 - "$path" "$2" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
con.execute("INSERT INTO ItemTable VALUES (?, ?)", ("history.recentlyOpenedPathsList", sys.argv[2]))
con.commit()
con.close()
PY
    printf '%s' "$path"
}

# run_launcher <db> [arg…] — capture stdout+stderr and the exit code. Captured
# explicitly: `set -e` would otherwise abort the suite on the very nonzero exit
# a case exists to assert.
out=""
rc=0
run_launcher() {
    local db="$1"
    shift
    set +e
    out="$(VSCODE_STATE_DB="$db" OPEN_DEVCONTAINER_DRY_RUN=1 bash "$launcher" "$@" 2>&1)"
    rc=$?
    set -e
}

uri_init="$(dc_uri /srv/coder/harmon-init ssh-remote+devbox /workspaces/harmon-init)"
uri_site="$(dc_uri /srv/coder/evanharmon-site ssh-remote+devbox /workspaces/evanharmon-site %2B)"
recents="{\"entries\":[{\"folderUri\":\"${uri_init}\"},{\"folderUri\":\"file:///srv/coder/notes\"},{\"folderUri\":\"${uri_site}\"}]}"
db_ok="$(make_db recents "$recents")"

# ---- 1. no argument lists the dev-container entries, and only those ----
# The ordinary folder entry is the control: a launcher that lists it would send
# `code --folder-uri` at a path with no container behind it.

echo "==> no argument lists exactly the dev-container entries"
run_launcher "$db_ok"
[ "$rc" -eq 0 ] || fail "listing exited ${rc}, not 0"
listed="$(VSCODE_STATE_DB="$db_ok" bash "$launcher" 2>/dev/null)"
[ "$(printf '%s\n' "$listed" | grep -c .)" -eq 2 ] ||
    fail "expected 2 listed entries on stdout, got: ${listed}"
printf '%s\n' "$listed" | grep -q '/workspaces/harmon-init' ||
    fail "the harmon-init entry is missing: ${listed}"
printf '%s\n' "$listed" | grep -q '/workspaces/evanharmon-site' ||
    fail "the percent-encoded '+' entry is missing: ${listed}"
if printf '%s\n' "$listed" | grep -q 'notes'; then
    fail "an ordinary (non-dev-container) folder was listed: ${listed}"
fi
# The hex blob is decoded far enough to name the checkout on the host.
printf '%s\n' "$listed" | grep -q 'host /srv/coder/harmon-init' ||
    fail "the hostPath was not decoded out of the hex authority: ${listed}"

# ---- 2. a unique match launches that entry, matched case-insensitively ----

echo "==> a unique match launches the right URI"
run_launcher "$db_ok" HARMON-Init
[ "$rc" -eq 0 ] || fail "a unique match exited ${rc}, not 0"
printf '%s\n' "$out" | grep -qF -- "--folder-uri ${uri_init}" ||
    fail "did not launch the harmon-init URI: ${out}"
if printf '%s\n' "$out" | grep -qF -- "$uri_site"; then
    fail "the launch command names the wrong entry too: ${out}"
fi

echo "==> the launch really execs the code CLI with the URI"
stub="${tmp_root}/code-stub"
cat >"$stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${tmp_root}/stub-args"
EOF
chmod +x "$stub"
VSCODE_STATE_DB="$db_ok" CODE_BIN="$stub" bash "$launcher" evanharmon-site >/dev/null 2>&1 ||
    fail "launching through a CODE_BIN stub exited nonzero"
[ -f "${tmp_root}/stub-args" ] || fail "the code stub was never invoked"
grep -qxF -- "--folder-uri" "${tmp_root}/stub-args" ||
    fail "the stub was not passed --folder-uri: $(cat "${tmp_root}/stub-args")"
grep -qxF -- "$uri_site" "${tmp_root}/stub-args" ||
    fail "the stub was passed the wrong URI: $(cat "${tmp_root}/stub-args")"

# ---- 3. an ambiguous match refuses, and shows what to choose between ----
# Silently opening the first of several is the failure mode worth designing
# against: it is indistinguishable from success until the wrong window opens.

echo "==> an ambiguous match exits 1 and lists the candidates"
run_launcher "$db_ok" workspaces
[ "$rc" -eq 1 ] || fail "an ambiguous match exited ${rc}, not 1"
printf '%s\n' "$out" | grep -q '/workspaces/harmon-init' ||
    fail "the ambiguous listing omits harmon-init: ${out}"
printf '%s\n' "$out" | grep -q '/workspaces/evanharmon-site' ||
    fail "the ambiguous listing omits evanharmon-site: ${out}"
if printf '%s\n' "$out" | grep -qF -- "--folder-uri"; then
    fail "an ambiguous match launched something anyway: ${out}"
fi

# ---- 4. no match points at the flow that would create the entry ----
# The launcher cannot compose a dev-container URI it has never seen, so this
# message is the whole remedy — it has to name the manual flow.

echo "==> no match exits 1 with the manual-flow pointer"
run_launcher "$db_ok" nonesuch
[ "$rc" -eq 1 ] || fail "an unmatched name exited ${rc}, not 1"
printf '%s\n' "$out" | grep -q 'docs/guides/devcontainers.md' ||
    fail "the no-match message does not point at the guide: ${out}"

echo "==> a recents list with no dev-container entries says the same thing"
db_plain="$(make_db plain '{"entries":[{"folderUri":"file:///srv/coder/notes"}]}')"
run_launcher "$db_plain" harmon-init
[ "$rc" -ne 0 ] || fail "a recents list with no dev containers exited 0"
printf '%s\n' "$out" | grep -q 'docs/guides/devcontainers.md' ||
    fail "the empty-list message does not point at the guide: ${out}"

# ---- 5. every missing precondition is one specific line, never a trace ----

echo "==> a missing database exits nonzero naming the path"
run_launcher "${tmp_root}/absent.vscdb"
[ "$rc" -ne 0 ] || fail "a missing database exited 0"
printf '%s\n' "$out" | grep -q 'no VS Code state database' ||
    fail "a missing database did not say so: ${out}"
if printf '%s\n' "$out" | grep -qi 'line [0-9]\|command not found'; then
    fail "a missing database produced a bash trace: ${out}"
fi

echo "==> a database without the recents key exits nonzero"
db_nokey="${tmp_root}/nokey.vscdb"
python3 - "$db_nokey" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
con.commit()
con.close()
PY
run_launcher "$db_nokey"
[ "$rc" -ne 0 ] || fail "a database without the recents key exited 0"
printf '%s\n' "$out" | grep -q 'no recently-opened list' ||
    fail "a database without the recents key did not say so: ${out}"

echo "==> a database that is not a state.vscdb exits nonzero"
db_junk="${tmp_root}/junk.vscdb"
printf 'not a database\n' >"$db_junk"
run_launcher "$db_junk"
[ "$rc" -ne 0 ] || fail "a non-database file exited 0"
printf '%s\n' "$out" | grep -q 'could not read' ||
    fail "a non-database file did not say so: ${out}"

echo "==> a missing python3 exits nonzero saying how to get one"
set +e
out="$(VSCODE_STATE_DB="$db_ok" PYTHON_BIN="${tmp_root}/no-such-python" bash "$launcher" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a missing python3 exited 0"
printf '%s\n' "$out" | grep -q 'no working python3' ||
    fail "a missing python3 did not say so: ${out}"

echo "open-devcontainer: all cases passed"
