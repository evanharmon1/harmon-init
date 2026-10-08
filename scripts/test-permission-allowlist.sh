#!/usr/bin/env bash
# test-permission-allowlist.sh — regression-guard the Claude Code Bash
# permission allowlist in .claude/settings.json and its template twin.
#
# The allowlist widens over successive PRs to cut prompt fatigue on
# read-only commands, and several entries were deliberately NARROWED during
# review (a wildcard grant found to allow an unsafe variant, cut down to an
# exact literal command with no arguments) or DROPPED entirely (a grant that
# allowed arbitrary code execution or a silent write, removed rather than
# narrowed). Nothing mechanically caught a future refactor re-widening one of
# those — this script does:
#
#   1. Each "narrowed to a bare literal" grant is still present as an EXACT
#      entry in permissions.allow (no trailing arguments), and no wider
#      variant of it has reappeared THERE — checked against the allow array
#      alone, so a defensive "ask"/"deny" rule mentioning the same command
#      (e.g. an "ask" entry for `Bash(ps aux)`) is never mistaken for a
#      re-widened allow grant, and moving a grant out of allow into ask/deny
#      is never mistaken for it still being present.
#   2. Each "dropped entirely" command has no allow entry at all, and each
#      grant a *fix* depends on is still present — deleting one would silently
#      restore the denial the fix removed, which nothing else catches.
#   3. The two files' permissions.allow arrays match after rendering the
#      template repository variables from .dogfood-answers.yml — the
#      documented invariant for this dogfood pair (unlike most jinja twins,
#      neither file has a conditional inside the allow array itself;
#      test:dogfood-parity does not cover this file
#      because it IS a jinja twin for the rest of its content).
#
# Run via `task test:permission-allowlist`.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

root_settings=".claude/settings.json"
template_settings="template/.claude/settings.json.jinja"

note_fail() {
    echo "FAIL: $*" >&2
    fail=1
}

# ---------------------------------------------------------------------------
# Extract each file's permissions.allow array in isolation. Both files hold
# it as a non-conditional JSON list — repository expressions are JSON strings,
# and no jinja control blocks appear between
# "allow": [ and its closing "],". Extracting that span verbatim (including
# the bracket lines) lets 1/2 below scope their checks to allow alone
# (never ask/deny), and lets 3 byte-diff the two arrays directly, including
# whitespace/ordering. POSIX bracket expressions and -E (not GNU's \s / \?
# escapes) so this works under BSD sed too — without -E, macOS sed silently
# fails to match the closing line and the extraction runs to EOF instead,
# producing a false parity failure.
extract_allow_block() {
    sed -E -n '/"allow": \[/,/^[[:space:]]*\],?[[:space:]]*$/p' "$1"
}

root_block="$(extract_allow_block "$root_settings")"
template_block="$(extract_allow_block "$template_settings")"
# Only these repository variables occur inside the allow array. Render them
# with the checked-in dogfood answers, rather than masking arbitrary drift.
template_block="$(printf '%s' "$template_block" | python3 -c '
import sys, re
from pathlib import Path
answers = Path(".dogfood-answers.yml").read_text()
text = sys.stdin.read()
for key in ["github_org", "project_slug"]:
    value = re.search(r"^" + key + r": ([A-Za-z0-9_.-]+)$", answers, re.MULTILINE)
    if value is None:
        sys.exit("Expected a plain repository answer for " + key)
    text = text.replace("[[ " + key + " ]]", value[1])
sys.stdout.write(text)
')"

[ -n "$root_block" ] || note_fail "$root_settings: could not locate permissions.allow array"
[ -n "$template_block" ] || note_fail "$template_settings: could not locate permissions.allow array"

# ---------------------------------------------------------------------------
# 1 & 2: exact-literal grants and dropped commands, checked against each
# file's allow array only.
# ---------------------------------------------------------------------------

# Commands narrowed to a bare literal (no arguments) after a wider grant was
# found to allow an unsafe variant. Once narrowed, the command may NEVER carry
# arguments again in allow — any allow entry that starts with the bare command
# followed by a space (arguments) or a colon (the "cmd:*" wildcard idiom)
# reintroduces the escape, regardless of what comes after. Checking only the
# two specific spellings seen so far (" *" / ":*") would miss e.g. a new exact
# rule such as `Bash(gh auth status --show-token)` added straight back in.
narrowed_commands=(
    'Bash(gh auth status)'
    'Bash(actionlint)'
    'Bash(ps)'
    'Bash(tree)'
)

# Commands whose allow rule was dropped entirely (not narrowed) because no
# safe prefix shape existed — arbitrary-exec or silent-write escapes.
dropped_prefixes=(
    'Bash(git grep'
    'Bash(shfmt'
)

# Grants a fix DEPENDS on: removing one re-breaks the thing it fixed, and no
# other check notices because parity still holds when both twins drop it
# together. Each entry is the exact allow string plus the reason it is load-
# bearing, so a later reader can tell a required grant from an ordinary one.
#   Bash(herdr agent start:*) — harmon-init#1239: without it the Claude Code
#   auto-mode classifier denies an orchestrator's lane-worker launch as
#   "Create Unsafe Agents". Prefix form is deliberate; the args after `--`
#   vary per harness.
required_grants=(
    'Bash(herdr agent start:*)'
)

check_allow_block() {
    local file="$1" allow_block="$2"

    for exact in "${narrowed_commands[@]}"; do
        case "$allow_block" in
        *"\"${exact}\""*) : ;;
        *) note_fail "$file: missing exact narrowed grant \"${exact}\" in permissions.allow" ;;
        esac
        # Strip the trailing ")" to get the bare "Bash(<command>" prefix: any
        # allow entry starting with that prefix followed by a space (an
        # argument) or a colon (the "cmd:*" wildcard idiom) reintroduces the
        # escape, whatever text follows.
        prefix="${exact%)}"
        case "$allow_block" in
        *"\"${prefix} "* | *"\"${prefix}:"*)
            note_fail "$file: an argument-bearing or wildcard form of the narrowed grant \"${exact}\" has reappeared in permissions.allow"
            ;;
        esac
    done

    for required in "${required_grants[@]}"; do
        case "$allow_block" in
        *"\"${required}\""*) : ;;
        *) note_fail "$file: missing required grant \"${required}\" in permissions.allow — removing it re-breaks the fix that added it" ;;
        esac
    done

    for prefix in "${dropped_prefixes[@]}"; do
        case "$allow_block" in
        *"\"${prefix}"*) note_fail "$file: dropped grant \"${prefix}...\" has reappeared in permissions.allow" ;;
        esac
    done
}

check_allow_block "$root_settings" "$root_block"
check_allow_block "$template_settings" "$template_block"

# ---------------------------------------------------------------------------
# 3: the two permissions.allow arrays must be byte-identical.
# ---------------------------------------------------------------------------

if [ "$root_block" != "$template_block" ]; then
    note_fail "permissions.allow arrays differ between $root_settings and $template_settings"
    diff <(printf '%s\n' "$root_block") <(printf '%s\n' "$template_block") >&2 || true
fi

# ---------------------------------------------------------------------------
# 4: trigger grants preserve fixed bodies. Accepted residuals: --edit-last
# may edit the last comment; broker --finder may choose a trusted registry
# body; the leading broker-path wildcard may match an unrelated executable.
# These are maintainer-approved residuals, not a general write boundary.
# JSON settings cannot carry comments, so their scope note lives here.
# Match command text: '*' includes spaces, ':*' is the trailing legacy form.
# Quotes are literal. Cases have no compound commands or stripped wrappers.
# https://code.claude.com/docs/en/permissions#wildcard-patterns
if ! python3 - "$root_settings" "$template_settings" <<'PYTEST'
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


def matches(rule, command):
    if not rule.startswith("Bash(") or not rule.endswith(")"):
        return False
    pattern = rule[5:-1]
    if pattern.endswith(":*"):
        pattern = pattern[:-2] + " *"
    if pattern.endswith(" *") and pattern.count("*") == 1:
        if command == pattern[:-2]:
            return True
    regex = ".*".join(re.escape(part) for part in pattern.split("*"))
    return re.fullmatch(regex, command, re.DOTALL) is not None


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# CLI conflict checks must never reach GitHub, even if validation regresses.
# GitHub uses HTTPS; force every proxy route to a closed loopback port.
env = dict(os.environ, GH_TOKEN="permission-test-placeholder",
           GH_HOST="github.com", GH_PROMPT_DISABLED="1",
           HTTPS_PROXY="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1",
           ALL_PROXY="http://127.0.0.1:1", NO_PROXY="",
           https_proxy="http://127.0.0.1:1", http_proxy="http://127.0.0.1:1",
           all_proxy="http://127.0.0.1:1", no_proxy="")
for filename in sys.argv[1:]:
    text = Path(filename).read_text()
    if filename.endswith(".jinja"):
        text = text.replace("[[ github_org ]]", "example")
        text = text.replace("[[ project_slug ]]", "consumer")
        repo = "example/consumer"
    else:
        repo = "evanharmon1/harmon-init"
    # Extract the non-conditional JSON block, including template expressions.
    block = re.search(r'"allow":\s*(\[.*?^\s*\])', text, re.DOTALL | re.MULTILINE)
    rules = json.loads(block[1])
    allowed = lambda command: any(matches(rule, command) for rule in rules)
    broker = str(Path.cwd() / ".claude/skills/integrate/assets/gh-write-broker.sh")
    trigger = broker + " trigger --repo " + repo + " --pr 1555"
    require(allowed(trigger), filename + ": missing broker grant")
    for extra in [" --body arbitrary", " --body-file x", " --comment-id 1"]:
        command = trigger + extra
        if allowed(command):
            result = subprocess.run(shlex.split(command), capture_output=True, text=True,
                                    env=env, timeout=10)
            require(result.returncode != 0 and
                    ("Usage:" in result.stderr or "refused:" in result.stderr),
                    filename + ": broker did not reject " + extra)
            print(filename + ": broker rejects " + extra)
    require(not allowed(broker + " reply --repo " + repo
                        + " --pr 1555 --comment-id 1 --body-file x"),
            filename + ": reply matched")
    for residual in [trigger + " --finder other", "bash /tmp/unrelated.sh " + trigger]:
        require(allowed(residual), filename + ": residual shape changed")
    print(filename + ": accepted residuals: broker finder and leading path wildcard")
    for body in ["/gemini review", "@" + "claude" + " review"]:
        prefix = "gh pr comment 1555 --repo " + repo
        comment = prefix + " --body '" + body + "'"
        require(allowed(comment), filename + ": missing fixed-body grant")
        for variant in [prefix + " --body arbitrary",
                        prefix + " --body '" + body + " extra'",
                        prefix + " --body-file x",
                        comment + " --delete-last",
                        comment.replace("gh pr comment", "gh pr review"),
                        "gh api repos/" + repo + "/issues/1555/comments -f body=x",
                        comment.replace(repo, "other/repository")]:
            require(not allowed(variant), filename + ": unexpected match: " + variant)
        print(filename + ": rules reject changed bodies, subcommands and trailing deletion")
        # Interior '*' can absorb these flags. Check actual gh conflict errors,
        # rather than pretending '*' matches only a PR-number argv token.
        for flag in ["--body-file x", "-F x", "--editor", "--web", "--delete-last"]:
            variant = "gh pr comment 1555 " + flag + " --repo " + repo
            variant += " --body '" + body + "'"
            require(allowed(variant), filename + ": conflict case did not match")
            result = subprocess.run(shlex.split(variant), capture_output=True, text=True,
                                    env=env, timeout=10)
            expected = ("should not provide comment body" if flag == "--delete-last"
                        else "specify only one of")
            require(result.returncode != 0 and expected in result.stderr.lower(),
                    filename + ": gh did not reject " + flag + ": " + result.stderr)
            print(filename + ": gh flag conflict rejects " + flag)
        residual = "gh pr comment 1555 --edit-last --repo " + repo
        require(allowed(residual + " --body '" + body + "'"),
                filename + ": edit-last residual shape changed")
        print(filename + ": accepted residual: --edit-last (not executed)")
PYTEST
then
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "test-permission-allowlist: narrowed/dropped/required grants intact, allow arrays match"
fi

exit "$fail"
