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
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

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
assert_guard_allows "/usr/bin/KILL -0 42 99"
assert_guard_allows "kill -l && kill -0 42"
assert_guard_allows "skill --version"
assert_guard_allows "killswitch=false"
assert_guard_allows "printf safe"
assert_guard_allows "FOO=bar printf safe"
assert_guard_allows "FOO+=bar printf safe"
assert_guard_allows "env FOO=bar printf safe"
assert_guard_allows "coproc printf bash"
assert_guard_allows "coproc printf source"
assert_guard_allows "coproc echo ."
assert_guard_allows "printf + =bar bash"
assert_guard_allows "echo + =x source"
assert_guard_allows "sudo printf safe"
assert_guard_allows "sudo ls ."
assert_guard_allows "env printf ."
assert_guard_allows "env --chdir . printf safe"
assert_guard_allows "timeout --help"
assert_guard_allows "timeout --version"
assert_guard_allows "time printf ."
assert_guard_allows "command printf ."
assert_guard_allows "builtin printf ."
assert_guard_allows "nice printf ."
assert_guard_allows "xargs printf ."
assert_guard_allows "command -v source"
assert_guard_allows "command -V source"
assert_guard_allows "sudo printf -s"
assert_guard_allows "sudo source ./cleanup.sh"
assert_guard_allows "env . ./cleanup.sh"
assert_guard_allows "env printf -- -Sfoo"
assert_guard_allows "env FOO=bar printf -Sfoo"

echo "==> guard-process-kill passes terminator-free commands that carry expansion syntax"
# #1118: expansion syntax is an approval boundary only for commands that
# already name a terminator token. None of these mention kill/pkill/killall/
# xkill, so they must never hit the special-character branch.
assert_guard_allows 'task check > /tmp/log 2>&1; echo "EXIT CODE: $?"'
assert_guard_allows 'echo "$HOME"'
assert_guard_allows "printf '%s\\n' \"\$(date)\""
assert_guard_allows "echo \`date\`"
assert_guard_allows $'echo ready\nprintf done'
assert_guard_allows "[ -f README.md ] && echo present"
assert_guard_allows 'grep -rln "foo" . | head'
assert_guard_allows 'grep -rln "foo" . | head; echo "EXIT $?"'
assert_guard_allows "ls docs/?.md"
assert_guard_allows "ls *.sh"
assert_guard_allows "sed -n '1,5p' *.md"
assert_guard_allows "echo {a,b}"
assert_guard_allows "{ printf safe; }"
assert_guard_allows "ls @(a|b).txt"
assert_guard_allows "ls +(a).txt"
assert_guard_allows "ls !(a).txt"
assert_guard_allows $'cat <<EOF\nhello\nEOF'
assert_guard_allows 'skill --version "$HOME"'
assert_guard_allows 'echo "$killer"'
assert_guard_allows 'killswitch=$1 printf safe'

echo "==> guard-process-kill passes expansion confined to an argument position"
# #1118 P1 fix: expansion syntax is only an approval boundary in command
# position (or a wrapper's candidate command word) or alongside a terminator
# token. These carry expansion but never as the command word, so they pass.
assert_guard_allows 'env FOO=$X printf safe'
assert_guard_allows 'echo $(date)'
assert_guard_allows 'for f in *.sh; do echo "$f"; done'
assert_guard_allows "printf '%s\\n' \"\$killer\""
assert_guard_allows 'diff <(printf a) <(printf b)'

echo "==> guard-process-kill challenge round 2 (#1118): redirects, executors, quoted parens"
# Fix 2: a leading/embedded redirect must not hide the real command word from
# the shell/wrapper/expansion checks once the redirect and its target are
# stripped away.
assert_guard_allows "> /tmp/log printf safe"
assert_guard_allows "2>/dev/null ls *.sh"
# Fix 3: strace/ssh/... are executors too, but a clean, non-expanded payload
# still passes.
assert_guard_allows "strace -o out.txt ls"
assert_guard_allows "ssh host uptime"
# Fix 4: a quoted literal that happens to end in "(" is ordinary text, not
# process-substitution/group syntax, and must never be treated as an opener.
assert_guard_allows 'printf "foo("'
assert_guard_allows "echo 'a(b'"
assert_guard_allows 'grep -F "x(" file.txt'

guard_subdir="$tmpdir/guard-subdir"
mkdir -p "$guard_subdir"
anchored_guard_output="$(cd "$guard_subdir" &&
    jq -n --arg command 'kill -9 42' '{tool_input: {command: $command}}' |
    CLAUDE_PROJECT_DIR="$repo" bash -c '"$CLAUDE_PROJECT_DIR"/.claude/hooks/guard-process-kill.sh')" ||
    fail "the project-anchored guard hook failed from a subdirectory"
printf '%s' "$anchored_guard_output" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null ||
    fail "the project-anchored guard hook did not ask for a terminating command from a subdirectory: $anchored_guard_output"

for command in \
    "kill" \
    "kill 42" \
    "kill -9 42" \
    "kill -l TERM" \
    "kill -s 0 42" \
    "/usr/bin/KILL -9 42" \
    "sudo /usr/bin/KILL -9 42" \
    "env kill -0 42" \
    "env -S'kill -9 42'" \
    "env -S 'kill -9 42'" \
    "env -iS'kill -9 42'" \
    "env --split-string='kill -9 42'" \
    "env --split-string 'kill -9 42'" \
    "timeout 1 printf ." \
    "timeout 1 sleep 10" \
    "timeout 1 kill -9 42" \
    "pkill -f worker" \
    "killall worker" \
    "xkill" \
    "bash -c 'kill -9 42'" \
    "bash -lc 'kill -9 42'" \
    "bash -- -c 'kill -9 42'" \
    "bash < cleanup.sh" \
    "bash <<< 'kill -9 42'" \
    "sh -c 'kill -9 42'" \
    "sudo sh -c 'kill -9 42'" \
    "sudo sh < cleanup.sh" \
    "env bash -c 'kill -9 42'" \
    "timeout 1 sh -c 'kill -9 42'" \
    "env - bash" \
    "env sudo sh -c 'kill -9 42'" \
    "timeout -sKILL 1 bash" \
    "sudo -h buildhost bash" \
    "sudo -h buildhost -s" \
    "FOO=bar source ./cleanup.sh" \
    "FOO=bar eval true" \
    "FOO=bar bash -c 'true'" \
    "FOO=x sudo -s" \
    "FOO=x sudo" \
    "FOO=x env bash" \
    "FOO=x timeout 1 bash" \
    "FOO=x command bash" \
    "FOO+=bar bash -c 'true'" \
    "FOO+=bar source ./cleanup.sh" \
    "FOO+=bar sudo -s" \
    "time FOO=bar source ./cleanup.sh" \
    "time FOO=x sudo -s" \
    "! FOO=bar bash -c 'true'" \
    "! FOO=x timeout 1 bash" \
    "if FOO=bar eval true; then printf safe; fi" \
    "if FOO=x env bash; then printf safe; fi" \
    "coproc source ./cleanup.sh" \
    "coproc eval true" \
    "coproc bash -c 'true'" \
    "zsh -lc 'kill -9 42'" \
    "eval 'kill -9 42'" \
    "source ./cleanup.sh" \
    ". ./cleanup.sh" \
    "source < cleanup.sh" \
    ". < cleanup.sh" \
    "printf '\\153ill -9 42\\n' | source /dev/stdin" \
    "printf '\\153ill -9 42\\n' | . /dev/stdin" \
    "command source ./cleanup.sh" \
    "command -p source ./cleanup.sh" \
    "command -- source ./cleanup.sh" \
    "builtin . ./cleanup.sh" \
    "time source ./cleanup.sh" \
    "time . ./cleanup.sh" \
    "time eval true" \
    "! source ./cleanup.sh" \
    "if source ./cleanup.sh; then printf safe; fi" \
    "while source ./cleanup.sh; do printf safe; done" \
    "sudo" \
    "sudo --" \
    "sudo -s" \
    "sudo -s <<< 'kill -9 42'" \
    "sudo --shell" \
    "sudo --shell <<< 'kill -9 42'" \
    "sudo -i" \
    "sudo -i <<< 'kill -9 42'" \
    "sudo --login" \
    "sudo --login <<< 'kill -9 42'" \
    "sudo -ks" \
    "sudo -ks < cleanup.sh" \
    "sudo --command-timeout 5 -s" \
    "sudo --host buildhost -s" \
    "sudo --unknown-option printf safe" \
    "trap 'kill -9 42' EXIT" \
    "trap 'KILL -9 42' EXIT" \
    "trap 'ki\\ll -9 42' EXIT" \
    "printf 'kill -9 42'" \
    "find . -name 'kill -9 42'" \
    "echo foo#bar; kill -9 42" \
    "\`kill -9 42\`" \
    "echo \$(kill -9 42)" \
    "kill -9 \$pid" \
    "kill -0 \$pid" \
    "pkill -f \"\$name\"" \
    "killall worker*" \
    "kill -9 42 # \$comment" \
    "find . -exec kill -9 42 \\;" \
    "find . -execdir kill -9 42 \\;" \
    "find . -exec sh -c 'kill -9 42' \\;" \
    $'echo ready\nkill -9 42' \
    "FOO=x kill -9 42" \
    "{ kill -9 42; }" \
    "\$killer -9 42" \
    "/bin/ki[l]l -9 42" \
    "/bin/kil? -9 42" \
    "/bin/ki* -9 42" \
    "k{i..i}ll -9 42" \
    "@(ki|noop)ll -9 42" \
    "+(ki)ll -9 42" \
    "!(safe) -9 42" \
    "/usr/bin/@(k)ill -9 42" \
    "\$(printf '\\153ill') -9 42" \
    "\`printf '\\153ill'\` -9 42" \
    "sudo -u root \$killer -9 42" \
    "env FOO=x \$killer -9 42" \
    "exec \$killer -9 42" \
    "\"\$killer\" -9 42" \
    "x=\$killer; \$x -9 42" \
    "if true; then \$killer -9 42; fi" \
    "for p in 1 2; do \$killer -9 \$p; done" \
    $'printf safe\n$killer -9 42' \
    "> /tmp/log \$killer -9 42" \
    "2>/dev/null \$killer -9 42" \
    "</dev/null \$killer -9 42" \
    ">\$log \$killer -9 42" \
    "kill -0 42 > log" \
    "strace \$killer -9 42" \
    "watch -n1 \$killer 42" \
    "runuser -u root \$killer -9 42" \
    "su -c \"\$cmd\"" \
    "ssh host \$killer 42" \
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

no_jq_path="$tmpdir/no-jq-path"
mkdir -p "$no_jq_path"
ln -s "$(command -v cat)" "$no_jq_path/cat"
bash_bin="$(command -v bash)"
no_jq_output="$(printf '%s' '{"tool_input":{"command":"kill -9 42"}}' |
    PATH="$no_jq_path" "$bash_bin" "$guard")" || fail "guard-process-kill failed when jq was unavailable"
printf '%s' "$no_jq_output" | jq -e '
    .hookSpecificOutput.permissionDecision == "ask" and
    (.hookSpecificOutput.permissionDecisionReason | contains("process-termination rule"))
' >/dev/null || fail "guard-process-kill did not fail closed when jq was unavailable: $no_jq_output"

no_python_path="$tmpdir/no-python-path"
mkdir -p "$no_python_path"
ln -s "$(command -v cat)" "$no_python_path/cat"
ln -s "$(command -v jq)" "$no_python_path/jq"
for command in 'printf safe' 'perl -ekill+9,42' 'kill -l' 'kill -0 42 99' 'bash' '/usr/bin/@(k)ill -9 42'; do
    no_python_output="$(jq -n --arg command "$command" '{tool_input: {command: $command}}' |
        PATH="$no_python_path" "$bash_bin" "$guard")" ||
        fail "guard-process-kill failed without python3 for command: $command"
    printf '%s' "$no_python_output" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null ||
        fail "guard-process-kill did not fail closed without python3 for '$command': $no_python_output"
done

managed_guard="$repo/.devcontainer/config/claude-hooks/guard-process-kill.sh"
if [ -f "$managed_guard" ]; then
    [ -x "$managed_guard" ] || fail "managed guard-process-kill is not executable"
    for command in 'printf safe' 'perl -ekill+9,42' 'kill -l' 'kill -0 42 99' '/usr/bin/@(k)ill -9 42' 'bash'; do
        managed_output="$(jq -n --arg command "$command" '{tool_input: {command: $command}}' |
            PATH="$no_python_path" "$bash_bin" "$managed_guard")" ||
            fail "managed guard-process-kill failed without python3 for approval-gated command: $command"
        printf '%s' "$managed_output" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null ||
            fail "managed guard-process-kill did not fail closed without python3 for '$command': $managed_output"
    done
fi

echo "==> guard-process-kill registrations cover Claude, Codex, and agy"
jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
    | index("\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-process-kill.sh") != null
' .claude/settings.json >/dev/null ||
    fail "repository Claude settings do not register guard-process-kill"
if [ -f template/.claude/settings.json.jinja ]; then
    # shellcheck disable=SC2016 # The generated hook command intentionally contains a literal variable.
    grep -Fq '"command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-process-kill.sh"' \
        template/.claude/settings.json.jinja ||
        fail "always-generated Claude settings template does not register guard-process-kill"
fi
if [ -f .devcontainer/config/claude-settings.json ]; then
    jq -e '
        [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
        | index("/usr/local/share/devcontainer-config/claude-hooks/guard-process-kill.sh") != null
    ' .devcontainer/config/claude-settings.json >/dev/null ||
        fail "Claude managed settings do not register guard-process-kill"
fi
jq -e '
    [."claude-hooks".PreToolUse[] | select(.matcher == "run_command") | .hooks[].command]
    | index("./agy-adapter.sh .claude/hooks/guard-process-kill.sh PreToolUse") != null
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

if command -v shfmt >/dev/null 2>&1; then
    echo "==> format:file formats a file, including a path containing a space"
    spaced="$tmpdir/with space.sh"
    printf 'f(){\necho hi\n}\n' >"$spaced"
    before="$(cat "$spaced")"
    if ! task format:file -- "$spaced" >/dev/null 2>&1; then
        fail "format:file errored on a path containing a space"
    fi
    if [ "$before" = "$(cat "$spaced")" ]; then
        fail "format:file did not reformat a mis-formatted file"
    fi
else
    echo "==> format:file delegation skipped (shfmt unavailable)"
fi

echo "==> hook-delegation targets OK (commit-msg accept/reject, format:file)"

codex_hooks_dir="$repo/.devcontainer/config/codex-hooks"
if [ -x "$codex_hooks_dir/file-payload.sh" ] && [ -x "$codex_hooks_dir/claude-compat.sh" ]; then
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
        bash "$codex_hooks_dir/file-payload.sh" "$mock"
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
        bash "$codex_hooks_dir/claude-compat.sh" "$cwd_mock")"
    [ "$got" = "/tmp/codex-project" ] || fail "Codex Bash adapter lost the session cwd"

    echo "==> shared Claude/Codex hook adapters OK"
else
    echo "==> Codex adapter fixtures skipped (devcontainer assets absent)"
fi

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
