#!/usr/bin/env bash
# test-hooks.sh — round-trip the Taskfile targets and Codex adapters shared by
# the Claude/Codex hooks. Guards against the go-task CLI_ARGS
# quoting/injection class of bug, where a valid commit message is silently
# rejected (blocking every commit) or a path with a space is silently skipped.
# Run via `task test:hooks`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

# The agy-adapter fixtures below run `git init`/`commit`/`worktree add` in
# throwaway repos. Left unsanitized, a machine with commit.gpgsign=true or a
# global core.hooksPath can make those fixture commits prompt, fail, or fire
# unrelated hooks — and since this suite is part of the required local gate,
# that makes `task test:hooks` unreliable rather than merely the fixture.
# Same isolation scripts/test-worktree.sh uses, for the same reason.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
git_config_count="${GIT_CONFIG_COUNT:-0}"
case "$git_config_count" in
'' | *[!0-9]*) git_config_count=0 ;;
esac
i=0
while [ "$i" -lt "$git_config_count" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ALTERNATE_OBJECT_DIRECTORIES

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

guard="$repo/.claude/hooks/guard-process-kill.sh"

guard_command() {
    jq -n --arg command "$1" '{tool_input: {command: $command}}' | "$guard"
}

assert_guard_allows() {
    local command="$1"
    local output
    output="$(guard_command "$command")" || fail "guard-process-kill failed for allowed command: $command"
    [ -z "$output" ] || fail "guard-process-kill prompted for allowed command '$command': $output"
}

assert_guard_asks() {
    local command="$1"
    local output
    output="$(guard_command "$command")" || fail "guard-process-kill failed for approval-gated command: $command"
    printf '%s' "$output" | jq -e '
        .hookSpecificOutput.hookEventName == "PreToolUse" and
        .hookSpecificOutput.permissionDecision == "ask" and
        (.hookSpecificOutput.permissionDecisionReason | type == "string" and length > 0)
    ' >/dev/null || fail "guard-process-kill did not emit a structured Claude ask for '$command': $output"
}

assert_guard_ask_names() {
    local command="$1"
    local matched="$2"
    local output
    output="$(guard_command "$command")" || fail "guard-process-kill failed for named command: $command"
    printf '%s' "$output" | jq -e --arg matched "$matched" '
        .hookSpecificOutput.permissionDecision == "ask" and
        (.hookSpecificOutput.permissionDecisionReason | contains("Command '\''" + $matched + "'\''")) and
        (.hookSpecificOutput.permissionDecisionReason | contains("process-termination rule"))
    ' >/dev/null || fail "guard-process-kill reason did not name '$matched' and the rule: $output"
}

echo "==> guard-process-kill permits only complete, non-terminating probe segments"
[ -x "$guard" ] || fail "guard-process-kill is not executable"
assert_guard_allows "kill -l"
assert_guard_allows "kill -0 42 99"
assert_guard_allows "kill -l && kill -0 42"
assert_guard_allows "printf 'kill -9 42'"
assert_guard_allows "find . -name 'kill -9 42'"
assert_guard_allows "skill --version"
assert_guard_allows "killswitch=false"
assert_guard_allows "printf safe"
for command in \
    "kill" \
    "kill 42" \
    "kill -9 42" \
    "kill -l TERM" \
    "kill -s 0 42" \
    "env kill -0 42" \
    "timeout 1 kill -9 42" \
    "pkill -f worker" \
    "killall worker" \
    "xkill" \
    "bash -c 'kill -9 42'" \
    "bash -lc 'kill -9 42'" \
    "bash -- -c 'kill -9 42'" \
    "sh -c 'kill -9 42'" \
    "sudo sh -c 'kill -9 42'" \
    "env bash -c 'kill -9 42'" \
    "timeout 1 sh -c 'kill -9 42'" \
    "zsh -lc 'kill -9 42'" \
    "eval 'kill -9 42'" \
    "\`kill -9 42\`" \
    "\$killer -9 42" \
    "echo \$(kill -9 42)" \
    "find . -exec kill -9 42 \\;" \
    "find . -execdir kill -9 42 \\;" \
    "find . -exec sh -c 'kill -9 42' \\;" \
    $'echo ready\nkill -9 42' \
    "FOO=x kill -9 42" \
    "/bin/ki[l]l -9 42" \
    "/bin/kil? -9 42" \
    "/bin/ki* -9 42" \
    "{ kill -9 42; }" \
    "kill 'unterminated"; do
    assert_guard_asks "$command"
done

assert_guard_ask_names "sudo killall worker" "killall"
assert_guard_ask_names "printf safe && pkill worker" "pkill"

owned_output="$(jq -n --arg command 'kill 42' '{tool_input: {command: $command}}' |
    HARMON_HARNESS_OWNED_PIDS=42 "$guard")" || fail "guard-process-kill failed with a forged ownership environment"
printf '%s' "$owned_output" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null ||
    fail "guard-process-kill trusted a non-authoritative ownership environment"

echo "==> guard-process-kill asks for all terminating commands"

echo "==> guard-process-kill registrations cover Claude, Codex, and agy"
jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
    | index("./.claude/hooks/guard-process-kill.sh") != null
' .claude/settings.json >/dev/null ||
    fail "repository Claude settings do not register guard-process-kill"
grep -Fq '"command": "./.claude/hooks/guard-process-kill.sh"' \
    template/.claude/settings.json.jinja ||
    fail "always-generated Claude settings template does not register guard-process-kill"
jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
    | index("/usr/local/share/devcontainer-config/claude-hooks/guard-process-kill.sh") != null
' .devcontainer/config/claude-settings.json >/dev/null ||
    fail "Claude managed settings do not register guard-process-kill"
grep -Fq 'claude-compat.sh /usr/local/share/devcontainer-config/claude-hooks/guard-process-kill.sh' \
    .devcontainer/config/codex-managed-config.toml ||
    fail "Codex managed settings do not register guard-process-kill"
jq -e '
    [."claude-hooks".PreToolUse[] | select(.matcher == "run_command") | .hooks[].command]
    | index("./.agents/agy-adapter.sh ./.claude/hooks/guard-process-kill.sh PreToolUse") != null
' .agents/hooks.json >/dev/null ||
    fail "agy hooks do not register guard-process-kill"

echo "==> guard-process-kill registrations OK"

echo "==> lint:commit-msg:text accepts a valid conventional message"
if ! printf '%s' 'feat: a valid message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text rejected a VALID conventional message"
fi

echo "==> lint:commit-msg:text rejects a non-conventional message"
if printf '%s' 'not a conventional message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text accepted an INVALID message"
fi

echo "==> format:file formats a file, including a path containing a space"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
spaced="$tmpdir/with space.sh"
printf 'f(){\necho hi\n}\n' >"$spaced"
before="$(cat "$spaced")"
if ! task format:file -- "$spaced" >/dev/null 2>&1; then
    fail "format:file errored on a path containing a space"
fi
if [ "$before" = "$(cat "$spaced")" ]; then
    fail "format:file did not reformat a mis-formatted file"
fi

echo "==> hook-delegation targets OK (commit-msg accept/reject, format:file)"

echo "==> Codex apply_patch adapter emits one Claude-style payload per file"
capture="$tmpdir/capture"
mock="$tmpdir/mock-hook.sh"
cat >"$mock" <<'EOF'
#!/usr/bin/env bash
jq -r '.tool_input.file_path' >>"$HOOK_CAPTURE"
EOF
chmod +x "$mock"
export HOOK_CAPTURE="$capture"
printf '%s' '{"cwd":"/tmp/project","tool_input":{"command":"*** Begin Patch\n*** Update File: one.txt\n*** Add File: dir/two.txt\n*** End Patch"}}' |
    bash "$repo/.devcontainer/config/codex-hooks/file-payload.sh" "$mock"
printf 'one.txt\ndir/two.txt\n' >"$tmpdir/expected"
cmp -s "$tmpdir/expected" "$capture" ||
    fail "Codex file-payload adapter did not preserve both patch paths"

echo "==> Codex Bash adapter exports the session cwd"
cwd_mock="$tmpdir/cwd-hook.sh"
cat >"$cwd_mock" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$CLAUDE_PROJECT_DIR"
cat >/dev/null
EOF
chmod +x "$cwd_mock"
got="$(printf '%s' '{"cwd":"/tmp/codex-project"}' |
    bash "$repo/.devcontainer/config/codex-hooks/claude-compat.sh" "$cwd_mock")"
[ "$got" = "/tmp/codex-project" ] || fail "Codex Bash adapter lost the session cwd"

codex_guard_output="$(jq -n --arg command 'kill -9 42' '{cwd: "/tmp/codex-project", tool_input: {command: $command}}' |
    bash "$repo/.devcontainer/config/codex-hooks/claude-compat.sh" "$guard")" ||
    fail "Codex Claude-hook adapter failed to run guard-process-kill"
printf '%s' "$codex_guard_output" | jq -e '
    .hookSpecificOutput.hookEventName == "PreToolUse" and
    .hookSpecificOutput.permissionDecision == "ask"
' >/dev/null || fail "Codex Claude-hook adapter did not preserve the structured ask output"

echo "==> shared Claude/Codex hook adapters OK"

echo "==> agy adapter follows Cwd to the worktree root and exports CLAUDE_PROJECT_DIR"
agy_fixture="$tmpdir/agy-fixture"
mkdir -p "$agy_fixture/.agents" "$agy_fixture/.claude/hooks"
cp "$repo/.agents/agy-adapter.sh" "$agy_fixture/.agents/agy-adapter.sh"
cat >"$agy_fixture/.claude/hooks/probe.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'PWD=%s CPD=%s\n' "$PWD" "${CLAUDE_PROJECT_DIR:-unset}" >>"$AGY_PROBE_LOG"
EOF
chmod +x "$agy_fixture/.claude/hooks/probe.sh"
git -C "$agy_fixture" init -q >/dev/null
git -C "$agy_fixture" config user.email "test@example.com" >/dev/null
git -C "$agy_fixture" config user.name "Test" >/dev/null
git -C "$agy_fixture" config commit.gpgsign false >/dev/null
git -C "$agy_fixture" add -A >/dev/null
git -C "$agy_fixture" commit -q -m init >/dev/null
agy_wt="$tmpdir/agy-fixture-wt"
git -C "$agy_fixture" worktree add -q "$agy_wt" -b agy-wt-branch >/dev/null
mkdir -p "$agy_wt/some/subdir"
agy_expected_root="$(git -C "$agy_wt" rev-parse --show-toplevel)"

agy_probe_log="$tmpdir/agy-probe.log"
: >"$agy_probe_log"
payload_a="$(jq -n --arg cwd "$agy_wt/some/subdir" '{toolCall: {name: "run_command", args: {CommandLine: "ls", Cwd: $cwd}}}')"
result_a="$(cd "$tmpdir" && AGY_PROBE_LOG="$agy_probe_log" bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/probe.sh PreToolUse' _ "$payload_a" "$agy_fixture/.agents/agy-adapter.sh")"
[ "$result_a" = '{"decision": "allow"}' ] || fail "agy-adapter (worktree Cwd) did not allow: $result_a"
[ -f "$agy_probe_log" ] || fail "agy-adapter (worktree Cwd) never ran the probe hook"
probe_line="$(cat "$agy_probe_log")"
[ "$probe_line" = "PWD=$agy_expected_root CPD=$agy_expected_root" ] ||
    fail "agy-adapter (worktree Cwd) expected PWD/CPD=$agy_expected_root, got: $probe_line"

cp "$guard" "$agy_fixture/.claude/hooks/guard-process-kill.sh"
chmod +x "$agy_fixture/.claude/hooks/guard-process-kill.sh"
payload_guard="$(jq -n --arg cwd "$agy_wt/some/subdir" '{toolCall: {name: "run_command", args: {CommandLine: "kill -9 42", Cwd: $cwd}}}')"
result_guard="$(cd "$tmpdir" && bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/guard-process-kill.sh PreToolUse' _ "$payload_guard" "$agy_fixture/.agents/agy-adapter.sh")"
printf '%s' "$result_guard" | jq -e '
    .decision == "ask" and (.reason | type == "string" and length > 0)
' >/dev/null || fail "agy-adapter did not preserve guard-process-kill's ask decision: $result_guard"

echo "==> agy adapter always executes ITS OWN hook, even when the target worktree's copy is tampered"
cat >"$agy_wt/.claude/hooks/probe.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'TAMPERED ran PWD=%s CPD=%s\n' "$PWD" "${CLAUDE_PROJECT_DIR:-unset}" >>"$AGY_PROBE_LOG"
EOF
git -C "$agy_wt" add -A >/dev/null
git -C "$agy_wt" commit -q -m "tamper: neuter the safety hook on this branch" >/dev/null
: >"$agy_probe_log"
result_tamper="$(cd "$tmpdir" && AGY_PROBE_LOG="$agy_probe_log" bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/probe.sh PreToolUse' _ "$payload_a" "$agy_fixture/.agents/agy-adapter.sh")"
[ "$result_tamper" = '{"decision": "allow"}' ] || fail "agy-adapter (tampered worktree hook) did not allow: $result_tamper"
probe_line_tamper="$(cat "$agy_probe_log")"
[ "$probe_line_tamper" = "PWD=$agy_expected_root CPD=$agy_expected_root" ] ||
    fail "agy-adapter ran the target worktree's own (tampered) hook instead of its trusted copy: $probe_line_tamper"

echo "==> agy adapter refuses a Cwd from a foreign checkout (no cd, foreign hook not run)"
agy_foreign="$tmpdir/agy-foreign"
mkdir -p "$agy_foreign/.claude/hooks"
cat >"$agy_foreign/.claude/hooks/probe.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'FOREIGN ran\n' >>"$AGY_FOREIGN_LOG"
EOF
chmod +x "$agy_foreign/.claude/hooks/probe.sh"
git -C "$agy_foreign" init -q >/dev/null
git -C "$agy_foreign" config user.email "test@example.com" >/dev/null
git -C "$agy_foreign" config user.name "Test" >/dev/null
git -C "$agy_foreign" config commit.gpgsign false >/dev/null
git -C "$agy_foreign" add -A >/dev/null
git -C "$agy_foreign" commit -q -m init >/dev/null

agy_neutral="$tmpdir/agy-neutral"
mkdir -p "$agy_neutral"
agy_foreign_log="$tmpdir/agy-foreign-ran.log"
payload_b="$(jq -n --arg cwd "$agy_foreign" '{toolCall: {name: "run_command", args: {CommandLine: "ls", Cwd: $cwd}}}')"
result_b="$(cd "$agy_neutral" && AGY_FOREIGN_LOG="$agy_foreign_log" bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/probe.sh PreToolUse' _ "$payload_b" "$agy_fixture/.agents/agy-adapter.sh")"
decision_b="$(printf '%s' "$result_b" | jq -r '.decision')"
[ "$decision_b" = "deny" ] || fail "agy-adapter followed a foreign Cwd instead of denying: $result_b"
[ -f "$agy_foreign_log" ] && fail "agy-adapter ran the foreign checkout's hook"

echo "==> agy adapter worktree-root Cwd resolution OK"
