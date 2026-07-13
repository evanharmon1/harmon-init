#!/usr/bin/env bash
# test-tasks.sh — guard the Taskfile against regressions that only surface at
# run time: a Taskfile that no longer compiles, and setup tasks that fail when
# they should be safe no-ops. Run via `task test:tasks`.
#
# Coverage note: the bootstrap assertion only exercises the "Homebrew already
# installed" path, so it is skipped on runners without brew (e.g. the default
# ubuntu-latest CI). It still guards the common local/macOS case — the exact
# regression where `task bootstrap` aborted on a sudo precheck despite brew
# already being installed.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

echo "==> Taskfile compiles (every task parses)"
if ! task --list-all >/dev/null 2>&1; then
    fail "task --list-all failed — the Taskfile does not compile"
fi

echo "==> bootstrap is a no-op when Homebrew is already installed"
if command -v brew >/dev/null 2>&1; then
    if ! task bootstrap >/dev/null 2>&1; then
        fail "task bootstrap failed even though brew is already installed"
    fi
else
    echo "    (skipped: brew not on PATH)"
fi

echo "==> shell quality helper preserves a path containing spaces"
shell_tmp="$(mktemp -d)"
trap 'rm -rf "$shell_tmp"' EXIT
shell_fixture="${shell_tmp}/fixture with spaces.sh"
cat >"$shell_fixture" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "ok"
EOF
./scripts/shell-quality.sh check "$shell_fixture"

echo "==> hygiene parser preserves quoted paths"
json_fixture="${shell_tmp}/fixture's data.json"
toml_fixture="${shell_tmp}/fixture's data.toml"
printf '%s\n' '{"ok": true}' >"$json_fixture"
printf '%s\n' 'ok = true' >"$toml_fixture"
./scripts/lint-hygiene.sh "$json_fixture" "$toml_fixture"

echo "==> secret helper tasks reject missing destination metadata"
# Assert the stable missing-destination diagnostic, not just a nonzero exit:
# a bare `if ! task ...` would also be satisfied by an unrelated failure
# (missing op/gh, a Taskfile parse error). Clear any inherited destination
# metadata first so the tests actually exercise the missing-metadata path.
out=$(printf '%s' 'dummy-secret' |
    env -u VAULT -u ITEM -u FIELD -u SECTION task secret:set:1p 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:1p succeeded without destination metadata"
fi
case "$out" in
*"VAULT, ITEM, and FIELD are required"*) ;;
*) fail "task secret:set:1p failed for the wrong reason: $out" ;;
esac
out=$(printf '%s' 'dummy-secret' |
    env -u NAME -u REPO task secret:set:gh 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:gh succeeded without destination metadata"
fi
case "$out" in
*"NAME and REPO are required"*) ;;
*) fail "task secret:set:gh failed for the wrong reason: $out" ;;
esac

echo "==> 1Password helper rejects SSH key items before edit"
fake_bin="${shell_tmp}/fake-bin"
edit_marker="${shell_tmp}/op-edit-called"
mkdir -p "$fake_bin"
cat >"${fake_bin}/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"item get")
    printf '%s\n' '{"category":"SSH_KEY","fields":[{"label":"password","type":"CONCEALED","value":"old"}]}'
    ;;
"item edit")
    : >"${OP_EDIT_MARKER:?}"
    ;;
*)
    exit 2
    ;;
esac
EOF
chmod +x "${fake_bin}/op"
out=$(printf '%s' 'dummy-secret' |
    PATH="${fake_bin}:${PATH}" OP_EDIT_MARKER="$edit_marker" \
        VAULT=test ITEM=test FIELD=password ./scripts/secret-set-1p.sh 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "secret:set:1p accepted an SSH key item"
fi
[ ! -e "$edit_marker" ] || fail "secret:set:1p called op item edit for an SSH key item"
case "$out" in
*"passkey or SSH key"*) ;;
*) fail "secret:set:1p rejected the SSH key item for the wrong reason: $out" ;;
esac

echo "==> task targets OK (compile + bootstrap idempotency)"
