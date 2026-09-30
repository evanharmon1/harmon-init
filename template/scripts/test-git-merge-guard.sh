#!/usr/bin/env bash
# test-git-merge-guard.sh — table-driven test for .claude/hooks/git-merge-guard.py.
#
# The guard replaces the `Bash(git merge:*)` permissions.ask rules, so a
# regression here silently removes the merge-into-main backstop. Every case
# feeds a real PreToolUse payload to the hook and checks its decision against
# throwaway repos: a feature-branch worktree, the default branch, a detached
# HEAD, a repo whose default branch is `trunk`, and one with no resolvable
# remote HEAD. A final pass runs a deliberately broken copy of the guard (one
# that never asks about the target branch) and requires the matrix to catch
# it, so the suite cannot pass vacuously.
# Run via `task test:hooks`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${GUARD:-${repo_root}/.claude/hooks/git-merge-guard.py}"

# Fixture commits must not trip a global signing config or core.hooksPath.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture() { # dir default-branch feature-branch set-remote-head(yes|no) [remote-name]
    local rem=${5:-origin}
    git init -q -b "$2" "$1"
    git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'chore: fixture'
    git -C "$1" branch "$3"
    git -C "$1" remote add "$rem" "${tmp}/absent.git"
    git -C "$1" update-ref "refs/remotes/${rem}/$2" HEAD
    if [[ $4 == yes ]]; then
        git -C "$1" symbolic-ref "refs/remotes/${rem}/HEAD" "refs/remotes/${rem}/$2"
    fi
}
r="${tmp}/repo"
fixture "$r" main feat yes
git -C "$r" worktree add -q "${r}/wt" feat
git -C "$r" worktree add -q --detach "${r}/det" main
tr="${tmp}/trunk"
fixture "$tr" trunk feat yes
git -C "$tr" worktree add -q "${tr}/wt" feat
nh="${tmp}/nohead"
fixture "$nh" trunk feat no
git -C "$nh" worktree add -q "${nh}/wt" feat
sl="${tmp}/slashed"
fixture "$sl" trunk feat yes team/origin
git -C "$sl" worktree add -q "${sl}/wt" feat
# Tags named like branches make `symbolic-ref --short` print `heads/<name>`.
am="${tmp}/ambiguous"
fixture "$am" main feat yes
git -C "$am" tag main
git -C "$am" tag feat
git -C "$am" worktree add -q "${am}/wt" feat 2>/dev/null # expected: "refname is ambiguous"
# A branch spelled `Main` in a repo whose remote default is `trunk`: only the
# casefolded main/master check can catch it (refs are case-insensitive on macOS).
cs="${tmp}/casefold"
fixture "$cs" trunk Main yes
git -C "$cs" worktree add -q "${cs}/wt" Main

failures=0
decide() { # guard cwd command -> silent|ask|rc<N>
    local out rc
    out="$(jq -nc --arg c "$3" --arg d "$2" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | python3 "$1")" && rc=0 || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "rc${rc}"
    elif [[ -z $out ]]; then
        echo silent
    elif jq -e '.hookSpecificOutput.permissionDecision == "ask"
        and (.hookSpecificOutput.permissionDecisionReason | length > 0)' <<<"$out" >/dev/null; then
        echo ask
    else
        echo "unexpected:${out}"
    fi
}
case_() { # guard expected cwd command
    local got
    got="$(decide "$1" "$3" "$4")"
    if [[ $got != "$2" ]]; then
        failures=$((failures + 1))
        [[ ${QUIET:-0} == 1 ]] || echo "  FAIL expected=$2 got=${got} :: [${3#"$tmp"/}] $4" >&2
    fi
}
nl=$'\n'
matrix() { # guard
    local g=$1
    # Allowlisted merges into a verified feature branch: no opinion.
    case_ "$g" silent "${r}/wt" "git merge origin/main --no-edit"
    case_ "$g" silent "${r}/wt" "git merge --no-ff main"
    case_ "$g" silent "${r}/wt" "git merge --continue"
    case_ "$g" silent "${r}/wt" "git merge --quit"
    case_ "$g" silent "${r}/wt" "git pull --ff-only"
    case_ "$g" silent "${r}/wt" "git pull --no-rebase origin main --no-edit"
    case_ "$g" silent "${tr}/wt" "git merge trunk --no-edit"
    case_ "$g" silent "${sl}/wt" "git merge trunk --no-edit"
    case_ "$g" silent "${am}/wt" "git merge main --no-edit"
    # Merges that land on main or the remote default, or an unverifiable target.
    case_ "$g" ask "$r" "git merge feat"
    case_ "$g" ask "$r" "git -C ${r} merge feat"
    case_ "$g" ask "${r}/wt" "git -C ${r} merge feat"
    case_ "$g" ask "${r}/wt" "cd ${r} && git merge feat"
    case_ "$g" ask "${r}/det" "git merge feat"
    case_ "$g" ask "$r" "git pull"
    case_ "$g" ask "$tr" "git merge feat"
    case_ "$g" ask "${nh}/wt" "git merge trunk"
    case_ "$g" ask "$sl" "git merge feat"
    case_ "$g" ask "$am" "git merge feat"
    case_ "$g" ask "${cs}/wt" "git merge trunk"
    case_ "$g" ask "$r" "cd wt && git merge main"
    case_ "$g" ask "${tmp}/missing" "git merge main"
    # Shapes the guard does not allowlist: always ask.
    # --abort discards in-progress conflict resolutions: never silent.
    case_ "$g" ask "${r}/wt" "git merge --abort"
    # pull --rebase can rewrite already-pushed feature-branch commits.
    case_ "$g" ask "${r}/wt" "git pull --rebase origin main"
    # cd / -C paths: the silent path takes no path arguments at all, so a
    # symlink-then-.. or quoted-~ path can't make the guard verify a
    # different checkout than the one git uses (review round 1).
    case_ "$g" ask "$r" "cd ${r}/wt && git merge origin/main --no-edit"
    case_ "$g" ask "$r" "cd ./wt && git merge main"
    case_ "$g" ask "$r" "git -C ${r}/wt merge --no-ff main"
    case_ "$g" ask "${r}/wt" "git -C ./hop/.. merge main"
    case_ "$g" ask "${r}/wt" "git -C \"~/repo\" merge main"
    # Quote-synthesized words on a FEATURE checkout must still ask.
    case_ "$g" ask "${r}/wt" "g''it merge main"
    case_ "$g" ask "${r}/wt" "git mer''ge main"
    case_ "$g" ask "${r}/wt" "git merge 'main'"
    case_ "$g" ask "relative/wt" "git merge main"
    case_ "$g" ask "${r}/wt" "git checkout main && git merge feat"
    case_ "$g" ask "${r}/wt" "git merge main; git -C ${r} merge feat"
    case_ "$g" ask "${r}/wt" "git status; git merge main"
    case_ "$g" ask "$r" "git status${nl}git merge feat"
    case_ "$g" ask "$r" "cd wt${nl}git merge main"
    case_ "$g" ask "$r" "if git merge feat; then echo ok; fi"
    case_ "$g" ask "$r" "command git merge feat"
    case_ "$g" ask "$r" "g''it merge feat"
    case_ "$g" ask "$r" "git mer''ge feat"
    case_ "$g" ask "$r" "GIT merge feat"
    case_ "$g" ask "$r" "G=git; \$G merge feat"
    case_ "$g" ask "${r}/wt" "git merge main || true"
    case_ "$g" ask "${r}/wt" "git merge \$(echo main)"
    # A `#` inside a word is not a comment in bash; shlex must not drop the rest.
    case_ "$g" ask "$r" "echo a#b; git merge feat"
    case_ "$g" ask "$r" "git log --grep=#1 && git merge feat"
    case_ "$g" ask "$r" "git -c alias.m=merge m feat"
    case_ "$g" ask "$r" "git -c Alias.m=merge m feat"
    case_ "$g" ask "$r" "git.exe merge feat"
    # A real comment holding a quote or a trailing backslash must not hide a
    # spliced subcommand on the same or the next line (bash-like reading).
    case_ "$g" ask "$r" "git mer''ge feat # don't"
    case_ "$g" ask "$r" "# don't${nl}git mer\"\"ge feat"
    case_ "$g" ask "$r" "true # don't${nl}git mer\"\"ge feat # it's ok"
    case_ "$g" ask "$r" "echo # \\${nl}git mer\"\"ge feat"
    # Line continuation, an apostrophe in a heredoc body, and `)#`.
    case_ "$g" ask "$r" "true && \\${nl}git mer\"\"ge feat"
    case_ "$g" ask "$r" "bash -c \"git mer''ge feat\" <<'EOF'${nl}don't${nl}EOF"
    case_ "$g" ask "$r" "git -c alias.m=mer\"\"ge m feat <<'EOF'${nl}don't${nl}EOF"
    case_ "$g" ask "$r" "(true)# don't${nl}bash -c \"git mer''ge feat\""
    case_ "$g" ask "$r" "(true)# \\${nl}git mer\"\"ge feat"
    case_ "$g" ask "$r" "git merge --quit"
    case_ "$g" ask "${r}/wt" "git merge main > /dev/null"
    case_ "$g" ask "${r}/wt" "FOO=1 git merge main"
    case_ "$g" ask "${r}/wt" "git -c core.hooksPath=/dev/null merge main"
    case_ "$g" ask "${r}/wt" "git merge -s ours main"
    case_ "$g" ask "${r}/wt" "git merge main feat"
    case_ "$g" ask "${r}/wt" "bash -c 'git merge main'"
    # Any interpreter handed a quoted command string, listed or not.
    case_ "$g" ask "${r}/wt" "fish -c 'git merge main'"
    case_ "$g" ask "${r}/wt" "pwsh -Command 'git pull'"
    # With pull.rebase set, a pull that names no mode rebases the branch.
    case_ "$g" ask "${r}/wt" "git pull origin main --no-edit"
    case_ "$g" ask "${r}/wt" "git pull origin main"
    case_ "$g" ask "${r}/wt" "/usr/bin/git merge main && echo ok"
    case_ "$g" ask "${r}/wt" "true; gh pr view 1; git merge main"
    case_ "$g" ask "${r}/wt" "git merge 'unbalanced"
    case_ "$g" ask "$r" "git \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    case_ "$g" ask "$r" "git mer\\${nl}ge feat"
    case_ "$g" ask "$r" "git m*rge feat"
    case_ "$g" ask "$r" "git \"\$SUB\" feat"
    # An untokenizable command (a quote opening a heredoc word) is still split
    # on `;&|()`, so a spliced subcommand right after `&&` or `(` is seen.
    case_ "$g" ask "$r" "true&&git \$'\\x6d\\x65\\x72\\x67\\x65' feat <<X${nl}\"hi"
    case_ "$g" ask "$r" "(git mer\"\"ge feat) <<X${nl}\"\\"
    # Options that take a separate value shift the subcommand slot.
    case_ "$g" ask "$r" "git --attr-source HEAD \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    case_ "$g" ask "$r" "git --shallow-file /dev/null \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    case_ "$g" ask "$r" "git --config-env user.name=FOO \"\$SUB\" feat"
    case_ "$g" ask "$r" "git --super-prefix sub/ \$'\\x6d\\x65\\x72\\x67\\x65' feat"
    # Scripts are not seen through: a bare path is silent (documented limit),
    # but a shell name in front of it is indirection and asks.
    case_ "$g" silent "${r}/wt" "./scripts/merge-main.sh"
    case_ "$g" ask "${r}/wt" "sh ./scripts/merge-main.sh"
    case_ "$g" ask "${r}/wt" "sh ./merge-main.sh"
    # No git merge/pull: no opinion, including everyday near-misses.
    case_ "$g" silent "${r}/wt" "git merge-base main feat"
    # A quoted word with trailing whitespace is not the word `merge`.
    case_ "$g" silent "${r}/wt" "git log --grep \"Merge \""
    # The integrate skill's own read-only form: an expansion plus `merge-base`.
    case_ "$g" silent "${r}/wt" "base=\"\$(git merge-base HEAD \"\$base_ref\")\""
    case_ "$g" silent "${r}/wt" "gh pr list --json number | xargs -n1 echo pull-requests"
    case_ "$g" ask "${r}/wt" "x=\$(git merge main)"
    # The dashed executables, and the index-writing merge plumbing behind indirection.
    case_ "$g" ask "${r}/wt" "\$(git --exec-path)/git-merge main"
    case_ "$g" ask "${r}/wt" "git-pull origin main"
    case_ "$g" ask "$r" "eval \"git merge-ours feat\""
    case_ "$g" ask "$r" "bash -c 'git merge-recursive base -- HEAD feat'"
    case_ "$g" ask "$r" "eval \"git-merge-ours feat\""
    # An expanded subcommand inside an interpreter string, like the unwrapped form.
    case_ "$g" ask "$r" "bash -c \"git \$SUB main\""
    case_ "$g" ask "$r" "eval \"git \${sub} feat\""
    case_ "$g" silent "${r}/wt" "bash -c \"git log --oneline\""
    # A dashed name anywhere asks (documented limit).
    case_ "$g" ask "${r}/wt" "grep -rn git-merge docs/"
    case_ "$g" ask "${r}/wt" "git log -1 # check the merge commit"
    case_ "$g" ask "${r}/wt" "gh pr comment 1 --body \"git \$(git rev-parse HEAD) is the head\""
    case_ "$g" ask "${r}/wt" "git config --get alias.st"
    case_ "$g" silent "${r}/wt" "gh pr comment 1 --body \"run git status with \$FLAGS\""
    # Quoted prose that names both words asks (documented limit); the guard's own
    # file name does not.
    case_ "$g" ask "${r}/wt" "git commit -m 'docs: explain how git pull works'"
    case_ "$g" silent "${r}/wt" "bash scripts/test-git-merge-guard.sh"
    case_ "$g" silent "${r}/wt" "python3 .claude/hooks/git-merge-guard.py --help"
    case_ "$g" silent "${r}/wt" "git log --merges --oneline"
    case_ "$g" silent "${r}/wt" "git commit -m 'fix: catch-up merge of main'"
    case_ "$g" silent "${r}/wt" "git status && git log -1"
    case_ "$g" silent "${r}/wt" "gh pr merge 1"
    case_ "$g" silent "${r}/wt" "gh pr view \"\$N\" --json mergeStateStatus,mergedAt"
    case_ "$g" silent "${r}/wt" "grep -rn merge docs/"
    # `.sh` is a file extension, not a shell name.
    case_ "$g" silent "${r}/wt" "grep -n merge scripts/worktree-rm.sh"
    case_ "$g" silent "${r}/wt" "ls pull-requests/"
    case_ "$g" silent "${r}/wt" "git -C \"\$HOME\" status"
    case_ "$g" silent "${r}/wt" "git log -- '*.md'"
    case_ "$g" silent "${r}/wt" "git log --format='%h %s' -1"
    case_ "$g" silent "${r}/wt" "cat > body.md <<'EOF'${nl}this pull request adds a guard${nl}EOF"
}

echo "==> git-merge-guard decision matrix"
matrix "$guard"
if [[ $failures -ne 0 ]]; then
    echo "TEST FAIL: git-merge-guard: ${failures} case(s) wrong" >&2
    exit 1
fi

echo "==> git-merge-guard matrix catches a guard that never checks the target branch"
mutant="${tmp}/mutant.py"
sed 's/^    if feature_branch(target) is None:$/    if False:/' "$guard" >"$mutant"
if cmp -s "$guard" "$mutant"; then
    echo "TEST FAIL: mutation did not apply (feature_branch check line changed?)" >&2
    exit 1
fi
QUIET=1 matrix "$mutant"
if [[ $failures -eq 0 ]]; then
    echo "TEST FAIL: matrix passed a guard that allows merges into main" >&2
    exit 1
fi

# The guard only protects anything if settings.json runs it. Exercise the
# REGISTERED command, not the file: a removed or misspelled entry, or a broken
# fail-closed fallback, must fail here.
settings="${repo_root}/.claude/settings.json"
if [[ -z ${GUARD:-} && -f $settings ]]; then
    echo "==> git-merge-guard is registered in .claude/settings.json and fails closed"
    registered="$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?
        | select(.type == "command" and (.command | contains("git-merge-guard.py")))
        | .command] | first // empty' "$settings")"
    if [[ -z $registered ]]; then
        echo "TEST FAIL: no PreToolUse Bash hook in .claude/settings.json runs git-merge-guard.py" >&2
        exit 1
    fi
    registered_decision() { # project-dir cwd command -> silent|ask|other
        local out
        out="$(jq -nc --arg c "$3" --arg d "$2" \
            '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' |
            CLAUDE_PROJECT_DIR="$1" bash -c "$registered" 2>/dev/null)" || true
        if [[ -z $out ]]; then
            echo silent
        elif jq -e '.hookSpecificOutput.permissionDecision == "ask"' <<<"$out" >/dev/null 2>&1; then
            echo ask
        else
            echo other
        fi
    }
    expect_registered() { # expected project-dir cwd command
        local got
        got="$(registered_decision "$2" "$3" "$4")"
        if [[ $got != "$1" ]]; then
            echo "TEST FAIL: registered hook: expected=$1 got=${got} :: $4 (project dir $2)" >&2
            exit 1
        fi
    }
    expect_registered ask "$repo_root" "$r" "git merge feat"
    expect_registered silent "$repo_root" "${r}/wt" "git merge origin/main --no-edit"
    # A guard that cannot be run must ask, never stay silent.
    expect_registered ask "${tmp}/no-such-project" "${r}/wt" "git merge origin/main --no-edit"
fi

echo "==> git-merge-guard OK"
