#!/usr/bin/env bash
# test-remote-codex-policy.sh — guard the remote second-model rule: ephemeral
# cloud environments never hold Codex credentials, and a persistent environment
# holds exactly one Codex login of its own (AGENTS.md § "Remote environments").
#
# The rule is easy to break without noticing: one line in a bootstrap, an env
# example, a workflow, or an adapter guide that tells a throwaway VM to run a
# Codex login, restore a copied auth file, or export an OpenAI API key
# contradicts it, and nothing else in the repository reads those lines together.
# This scans the remote-environment surfaces that exist in the repository under
# test (this script is a verbatim twin, so it runs in generated repos too, where
# several root-only surfaces are absent) for the credential vocabulary below,
# and fails with file:line on any hit the allowlist does not explain.
#
# Case-sensitive on purpose: the lowercase forms are the commands and the file
# names; the prose "a Codex login" that states the rule is not a violation.
# A backslash-continued command is joined before matching, so `codex \` followed
# by `login` is one line, reported at the line it starts on.
#
# What counts as a login is the invariant, not a literal: the word `codex`, then
# any option words (each starting with `-`, with an optional value), then the
# word `login`, on one normalised line — so `codex --no-alt-screen login` is
# caught like `codex login`. The same shape split across two lines (a folded
# YAML step) is caught too and reported as `file:L1-L2: <line 1> / <line 2>`; a
# folded hit cannot be allowlisted, the source has to be rewritten. Only a
# command-shaped first line starts a fold: one inside a folded or literal scalar
# under a command key (`run`, `cmd`, `command`, `script`, `entrypoint`, `args`),
# inside a fenced shell block (sh, bash, zsh, shell, console or shell-session),
# on a command-key line whose plain value ends in `codex` (YAML folds a plain
# multi-line scalar like `>-`), or that itself begins a `codex` invocation — so
# consecutive YAML mapping lines such as `provider: codex` / `login: oauth` pass.
# The next line completes the fold only if it continues the same command: still
# inside that scalar or fence, or indented deeper than the command key (or the
# `- ` of a sequence item) that armed it.
#
# `auth.json` is matched as a complete basename: `auth.json` and
# `~/.codex/auth.json` hit, `oauth.json`, `myauth.json` and `auth.json.example`
# do not (a dot after it is sentence punctuation only before a blank or the end
# of the line).
#
# `.claude/settings.json` is a strict surface with one exemption: a quoted
# permission rule (`"Read(~/.codex/auth.json)"`, any `"Name(...)"` string) is not
# matched against the tokens there, so a project can protect a credential file
# with a deny rule. An `env` block, or any other line, is still matched.
#
# The one rule outside the strict tier: a line is reported only if it mentions
# `codex` (any case) — every token, the login flags included. A generated project
# may use `--with-api-key`, `--device-auth`, an OPENAI_API_KEY or an auth.json for
# its own app and CLI; only their Codex use is this rule's subject, so `our-app
# login --with-api-key` passes and `codex login --with-api-key` fails. The login
# invariant and the `~/.codex` / `.codex/` tokens already carry the word, so
# `~/.codex/auth.json` fails everywhere. The strict tier is the invariant that
# nothing which PROVISIONS a remote environment may carry Codex credentials or the
# API key at all: there every token is reported bare.
#
# The allowlist excuses a line only when its COMPLETE text equals an entry for
# that file — never a substring — compared in the normalised form (runs of
# blanks collapsed) on both sides — so a prescriptive sentence that quotes an
# excused phrase still fails, and editing an excused line re-opens it for review.
#
# Residual: this is a textual, best-effort control. It cannot catch every
# spelling (a variable holding the command name, an encoded path, a login driven
# by a tool it does not scan). It stops the plain and the accidental ones, and
# the self-test below proves it does that for every token and every pattern
# rule. More, stated plainly:
#   - An allowlisted line is excused by its exact text anywhere in its file, so
#     moving an operator-only line verbatim into a remote-lane section is not
#     caught. Review catches that; the guard does not.
#   - Only the `~/.codex` and trailing-slash `.codex/` spellings are matched, so
#     `$HOME/.codex` or `/home/vscode/.codex` without a slash is not. A bare
#     `.codex` token is deliberately not used: the agent devcontainer mounts that
#     directory legitimately, and the persistent login lives in it.
#   - A command folded across THREE lines whose middle line holds only options
#     (`codex` / `--opt` / `login`) is not joined; only two-line folds are.
#   - Outside the strict tier, a token with `codex` only on a neighbouring line
#     is not caught. Inside the strict tier that does not apply.
#   - Fences are matched by character and length (a run of the opener's
#     character at least as long as its opener closes it); the info string and
#     indentation rules of a full Markdown parser are not applied.
#   - A literal scalar (`run: |`) and a shell fence are treated as fold contexts
#     although a newline ends the command there, so `codex` then `login` on
#     separate lines is reported although the shell would run them as two commands.
# A full YAML or shell parser is out of scope.
#
# Self-proving: a planted violation in a temporary copy of the surfaces must
# fail, for every token, so a scan that silently stopped matching cannot pass.
# No login of any kind is performed and nothing is written outside a temp dir.
#
# Offline and metadata-only. Run via `task test:remote-codex-policy`.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
# A self-test case may chmod a copy unreadable; restore access (the search bit
# too) before removing, and never let a failed chmod skip the removal.
trap 'chmod -R u+rwX "${TMP}" 2>/dev/null || :; rm -rf "${TMP}"' EXIT

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Plain credential vocabulary: each names a login flag, the API key, a login's
# credential file, or a directory a login leaves behind. Whether a hit counts is
# decided by the one rule above (a `codex` on the line, or the strict tier); the
# Codex login invariant is a pattern rule inside the awk matcher.
TOKENS=(
    'OPENAI_API_KEY'
    'auth.json'
    '--device-auth'
    '--with-api-key'
    '--with-access-token'
    '~/.codex'
    '.codex/'
)

# Scope rule: remote-environment configuration and documentation are scanned.
# Directories are scanned recursively, files directly; whatever does not exist in
# the repository under test is skipped. All of docs/ is scanned (so a new adapter
# page is covered the day it is added) except docs/research/, which assesses
# rejected options rather than guiding anyone. scripts/ is excluded because its
# Codex scripts are operator-machine tooling that legitimately logs in locally,
# except every scripts/setup-*.sh (SURFACE_GLOBS): a new setup script is covered
# the day it is added, under the Codex-scoped rule; one that is not named
# setup-*.sh must be added to SURFACE_FILES. The Claude Code on the web session
# settings are a surface too: a single-repository session loads them, so an `env`
# block there is an ephemeral-cloud credential.
SURFACE_DIRS=(
    'images/devcontainer'
    '.devcontainer'
    '.github/workflows'
    '.github/actions'
    'docs'
)
EXCLUDE_DIRS=(
    'docs/research'
)
SURFACE_GLOBS=(
    'scripts/setup-*.sh'
)
SURFACE_FILES=(
    'AGENTS.md'
    '.claude/settings.json'
)
# Strict tier — the remote-bootstrap entry points (a directory is matched
# recursively, each entry only where it exists): nothing that provisions a remote
# environment may carry Codex credentials or the API key at all, so every token is
# reported bare here and needs a `codex` on the line elsewhere.
STRICT_PATHS=(
    'images/devcontainer'
    '.github/workflows/remote-bootstrap.yml'
    '.claude/settings.json'
    '.devcontainer/scripts/bootstrap-related-repos.sh'
)
# The opt-in Fly.io Sprites provisioning surface (#1411) is a scanned surface AND
# a strict path, but only in a tree holding SPRITES_MARKER — the generator
# harmon-init ships with that opt-in. The marker is what makes the directory the
# provisioning surface: this script is a verbatim twin and cannot be gated on the
# Copier answer, so it checks for the asset at runtime, and a consumer's unrelated
# sprites/ directory (graphics, say) is neither scanned nor strict. A Sprite's one
# Codex login is the maintainer's, made by hand, so nothing there may handle one.
SPRITES_DIR='sprites'
SPRITES_MARKER='sprites/network-policy.sh'
# The remote-setup entry points are strict too (the glob is expanded where it
# exists): setup-remote.sh and any setup-remote*.sh that follows its name provision
# a remote environment. Every other setup-*.sh stays Codex-scoped, because a
# generated project's own setup script (a database, say) may legitimately name an
# auth.json or an OPENAI_API_KEY of its own.
STRICT_GLOBS=(
    'scripts/setup-remote*.sh'
)
# Also strict: the environment examples a remote environment is provisioned from,
# as "directory::file name" (the name is matched anywhere under the directory).
# init-env.sh never admits OPENAI_API_KEY (it is not an opt-in provider key), so a
# key in these files could never reach the container, and no consumer needs one.
STRICT_NAMES=(
    '.devcontainer::devcontainer.env.example'
)

# Allowlist: "file@@complete line@@reason".
ALLOW=(
    '.devcontainer/config/claude-hooks/protect-files.sh@@    ".codex/config.toml"@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-managed-config.toml@@# silently outranks `-c`, ~/.codex/config.toml and a trusted project@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-managed-config.toml@@# .codex/config.toml. (The explicit `-m` flag still beat a pinned `model`,@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-system-config.toml@@# `-c` flags, ~/.codex/config.toml and a project'"'"'s .codex/config.toml alike --@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-system-config.toml@@# and a trusted project .codex/config.toml. Pinning model_reasoning_effort@@configuration path in a comment or protected-path list, not a credential'
    '.devcontainer/config/codex-system-config.toml@@# first: ~/.codex/config.toml, a trusted project .codex/config.toml, then `-c`@@configuration path in a comment or protected-path list, not a credential'
    'docs/guides/codex-review.md@@2. **Authenticate**: `codex login` (browser OAuth against a ChatGPT account —@@operator-machine setup: browser OAuth on the operator'"'"'s own ChatGPT login'
    'docs/guides/codex-review.md@@   `printenv OPENAI_API_KEY | codex login --with-api-key` (billed API usage).@@operator-machine alternative (billed API usage), not a remote environment'
    'docs/guides/codex-review.md@@   Confirm with `codex login status`.@@read-only status probe; it performs no login'
    'docs/guides/codex-review.md@@   `.codex/config.toml` raises the project-instruction budget to 64 KiB. Review@@configuration path, not a credential'
    'docs/guides/codex-review.md@@`task codex:gate:enable` refuses to arm the gate unless `codex login status`@@read-only status probe in the stop-gate'"'"'s login check'
    'docs/guides/codex-review.md@@`codex login` or `task codex:gate:disable` (disable/status never require@@operator-machine remedy for the stop-gate'"'"'s login check'
    'docs/guides/codex-review.md@@- **Auth expired** — `codex login status`, then `codex login` (or@@operator-machine troubleshooting: re-authenticate after expiry'
    'docs/guides/codex-review.md@@  `codex login --device-auth` without a browser).@@operator-machine troubleshooting on a host without a browser'
    'docs/guides/codex-review.md@@  `~/.codex/config.toml`, and a trusted project `.codex/config.toml` alike,@@configuration path, not a credential'
    'docs/copier-options.md@@| 18 | `use_shared_agents` | bool | **yes** | `use_skills_sync` | Also vendors devkit subagents into `.claude/agents` + `.codex/agents/implementer.toml` |@@the repository'"'"'s own .codex/agents/ configuration path, not a credential'
    'docs/copier-options.md@@| `use_skills_sync and use_shared_agents` | `.codex/agents/implementer.toml` |@@the repository'"'"'s own .codex/agents/ configuration path, not a credential'
    'AGENTS.md@@`codex login` once on that environment, and an agent never does (§ Hard Rules:@@the rule itself: the maintainer, never an agent, makes a persistent environment'"'"'s one login'
    # The next entry and the one for (harmon-init#1406) are the root and template wording of the same sentence.
    'docs/guides/devcontainers.md@@environment persists one (#1406), lives in the `~/.codex` volume, not the@@where the persistent login lives: the volume, not the env-file'
    'docs/guides/devcontainers.md@@The maintainer runs `codex login` once on the environment when provisioning it@@the rule itself: the maintainer, never an agent, makes a persistent environment'"'"'s one login'
    'docs/guides/devcontainers.md@@`~/.codex/auth.json` is never copied to another machine (the refresh token is@@the rule itself: a persistent environment holds exactly one login, and its file never leaves it'
    'docs/guides/devcontainers.md@@  - Substring patterns: `.claude/settings.json`, `.codex/config.toml`, `/etc/claude-code/`, `/etc/codex/`@@configuration path, not a credential'
    'docs/guides/devcontainers.md@@is an unoverridable requirement that beats `-c`, `~/.codex/config.toml` and a@@configuration path, not a credential'
    'docs/guides/devcontainers.md@@trusted project `.codex/config.toml` without saying so. Only the sandbox and@@configuration path, not a credential'
    'docs/guides/devcontainers.md@@persist regardless, in the `~/.claude`, `~/.codex`, `~/.local/share/opencode`,@@the list of persisted home directories'
    'docs/architecture/remote-environments.md@@| **agents** | yes | The Codex CLI at the image'"'"'s pin. Used only where an environment persists and holds its own login (#1406); ephemeral clouds install it and never log in. A persistent environment'"'"'s login is made once, when the maintainer runs `codex login` on it while provisioning (an agent never does; `AGENTS.md` § Hard Rules), and its `~/.codex/auth.json` is never copied to another machine: the refresh token is single-use, so a copy would invalidate both holders |@@the rule itself: a persistent environment holds exactly one login, made by the maintainer, and its file never leaves it'
    'docs/guides/devcontainers.md@@environment persists one (harmon-init#1406), lives in the `~/.codex` volume, not the@@where the persistent login lives: the volume, not the env-file'
)

# norm TEXT — collapse every run of blanks (spaces and tabs) to one space, so
# `codex  login` and a tab-separated form read like `codex login`. Tokens are
# matched, and the allowlist compared, on this normalised form on both sides.
norm() {
    local s="${1//$'\t'/ }"
    while [[ "$s" == *"  "* ]]; do
        s="${s//  / }"
    done
    printf '%s' "$s"
}

# The allowlist in compare form, computed once: normalising inside the scan loop
# forks per entry per hit, and the self-test scans many times.
ALLOW_FILES=()
ALLOW_TEXTS=()
for entry in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    ALLOW_FILES+=("${entry%%@@*}")
    etext="${entry#*@@}"
    ALLOW_TEXTS+=("$(norm "${etext%%@@*}")")
done

# scan ROOT — print "file:line:text" for every unexplained hit under ROOT (text
# normalised, backslash-continued lines joined and numbered by the physical line
# they start on), then "SCANNED n". A file that cannot be read prints
# "GUARD-ERROR ..." instead and no SCANNED line. Always returns 0; the caller
# reads the output.
#
# One grep classifies every file (text vs empty/binary) and one awk matches the
# tokens across all the text files, so a scan costs two processes, not three per
# file — the self-test runs it many times.
scan() {
    local root="$1" file line text tokstr strictstr namestr rc hits allowed listing d f k scanned=0
    local files=() textfiles=() prune_args=() stricts=() dirs=() x g
    for x in ${EXCLUDE_DIRS[@]+"${EXCLUDE_DIRS[@]}"}; do
        prune_args+=(-path "${root}/${x}" -prune -o)
    done
    dirs=("${SURFACE_DIRS[@]}")
    [ ! -f "${root}/${SPRITES_MARKER}" ] || dirs+=("$SPRITES_DIR")
    for d in "${dirs[@]}"; do
        if [ -d "${root}/${d}" ]; then
            # find's own exit status must be seen: a directory it cannot list
            # would otherwise drop out of the scan and still pass. The listing
            # lives under TMP, removed by the EXIT trap.
            listing="$(mktemp "${TMP}/listing.XXXXXX")"
            if ! find "${root}/${d}" ${prune_args[@]+"${prune_args[@]}"} -type f -print >"$listing" 2>/dev/null ||
                ! LC_ALL=C sort -o "$listing" "$listing" 2>/dev/null; then
                echo "GUARD-ERROR guard could not list ${d}"
                return 0
            fi
            while IFS= read -r file; do
                files+=("${file#"${root}"/}")
            done <"$listing"
        fi
    done
    for f in "${SURFACE_FILES[@]}"; do
        [ -f "${root}/${f}" ] && files+=("$f")
    done
    for g in "${SURFACE_GLOBS[@]}"; do
        # Unmatched, the glob stays literal and fails the -f test.
        for f in "${root}"/${g}; do
            [ -f "$f" ] && files+=("${f#"${root}"/}")
        done
    done
    for file in "${files[@]+"${files[@]}"}"; do
        if [ ! -r "${root}/${file}" ]; then
            echo "GUARD-ERROR guard could not read ${file}"
            return 0
        fi
        scanned=$((scanned + 1))
    done
    [ "$scanned" -gt 0 ] || {
        echo "SCANNED 0"
        return 0
    }
    # grep -Il: 0/1 = ran (1 = no text file at all), 2+ = error.
    rc=0
    hits="$(cd "$root" && grep -Il . -- "${files[@]}" 2>/dev/null)" || rc=$?
    if [ "$rc" -ge 2 ]; then
        echo "GUARD-ERROR guard could not read the surface files"
        return 0
    fi
    if [ -n "$hits" ]; then
        while IFS= read -r file; do
            textfiles+=("./${file}")
        done <<<"$hits"
        tokstr="$(printf '%s\037' "${TOKENS[@]}")"
        stricts=("${STRICT_PATHS[@]}")
        [ ! -f "${root}/${SPRITES_MARKER}" ] || stricts+=("$SPRITES_DIR")
        for g in "${STRICT_GLOBS[@]}"; do
            for f in "${root}"/${g}; do
                [ -f "$f" ] && stricts+=("${f#"${root}"/}")
            done
        done
        strictstr="$(printf '%s\037' "${stricts[@]}")"
        namestr="$(printf '%s\037' "${STRICT_NAMES[@]}")"
        rc=0
        hits="$(cd "$root" && awk -v tokens="$tokstr" -v strictlist="$strictstr" -v namelist="$namestr" '
            # has_tok(T, TOK) — a plain substring, except auth.json, which must be a
            # complete basename: not `oauth.json` or `myauth.json`.
            function has_tok(t, tok) {
                if (tok == "auth.json") return (t ~ AUTHJSON)
                return index(t, tok)
            }
            # keycol(RAW) — the 0-based column of the command key on RAW (the first
            # physical line), a quote around the key included; -1 if there is none.
            # Tabs are read as blanks, as the collapsed text is, so a tab-indented key
            # is found at the column curind measures.
            function keycol(raw,   kc) {
                gsub(/\t/, " ", raw)
                if (!match(raw, KEYRE)) return -1
                kc = RSTART
                if (substr(raw, kc, 1) ~ /[ {-]/) kc++
                return kc - 1
            }
            # track(RAW, TT) — set curind (the indentation of RAW, the first physical
            # line) and incmd for the line about to be examined: is it command-shaped
            # context (inside a sh/bash fence, or inside a folded or literal scalar
            # under a command key)? The key column decides when a scalar ends. A
            # fence at or left of that column opening or closing ends the scalar: a
            # snippet shows one, it does not continue past its fence. A fence indented
            # inside the scalar is its content (a heredoc writing Markdown, say).
            # A fence is three or more backticks or tildes, closed by a run of the
            # same character at least as long as the opening run (CommonMark), so a
            # shorter run inside a longer fence is content.
            function runlen(s, c,   i) {
                i = 1
                while (substr(s, i, 1) == c) i++
                return i - 1
            }
            function track(raw, tt,   isbt, istl, rl) {
                incmd = 0
                match(raw, /^[ \t]*/)
                curind = RLENGTH
                isbt = (tt ~ FENCEBT)
                istl = (tt ~ FENCETL)
                if (bs && curind > bscol && (isbt || istl)) {
                    incmd = 1
                    return
                }
                rl = isbt ? runlen(tt, BT) : (istl ? runlen(tt, "~") : 0)
                if (fence ? (rl >= flen && (fchar == BT ? isbt : istl)) : (isbt || istl)) {
                    bs = 0
                    if (fence) fence = 0
                    else {
                        fence = 1
                        fchar = (isbt ? BT : "~")
                        flen = rl
                        fshell = (tt ~ FENCESH)
                    }
                    return
                }
                if (fence && fshell) {
                    incmd = 1
                    return
                }
                if (bs) {
                    if (tt == "") return
                    if (curind > bscol) {
                        incmd = 1
                        return
                    }
                    bs = 0
                }
                if (tt ~ BSHEAD) {
                    bscol = keycol(raw)
                    bs = (bscol >= 0)
                }
            }
            # continues() — may the line just tracked complete the fold armed by a
            # pending head? Only when it continues the same command: inside the same
            # scalar or fence the head sat in (pmode 1), or indented deeper than the
            # command key whose plain scalar the head opened (pmode 2) — a line at or
            # left of that key is a sibling, never a continuation. A head that merely
            # begins a codex invocation (pmode 3) has no key to measure against, except
            # a sequence item (`- codex`): its continuation is indented deeper than the
            # dash, a sibling key at or left of the dash is not one. A `$ codex` or bare
            # `codex` head keeps no such bound (pcol is -1).
            function continues() {
                if (pmode == 1) return incmd
                if (pmode == 2) return (curind > pcol)
                if (pcol >= 0) return (curind > pcol)
                return 1
            }
            function emit(f, s, t, raw,   i, tt, hit, m) {
                gsub(/[ \t]+/, " ", t)
                tt = t
                sub(/^ /, "", tt)
                track(raw, tt)
                # A Codex command folded across two lines (a YAML `>-` step):
                # `codex` and options end one line, options and `login` open the
                # next non-blank line. Reported with both real lines.
                if (pend != "" && tt != "") {
                    if (tt ~ FOLDTAIL && continues()) print pfile ":" pline "-" s ": " pend " / " tt
                    pend = ""
                }
                # One rule: outside the strict tier a line counts only if it
                # mentions codex (any case); inside it every token is bare.
                hit = 0
                # The Claude Code settings may carry permission rules that PROTECT a
                # credential file (`"Read(~/.codex/auth.json)"`): in that one file a
                # quoted `Name(...)` string is not matched against the tokens. An
                # `env` block, or any other line, is.
                m = t
                if (permfile) gsub(PERMRULE, "\"\"", m)
                if (strict || tolower(t) ~ /codex/) {
                    for (i = 1; i <= n; i++) {
                        if (T[i] != "" && has_tok(m, T[i])) {
                            hit = 1
                            break
                        }
                    }
                    if (!hit && t ~ LOGIN) hit = 1
                    if (hit) print substr(f, 3) ":" s ":" t
                }
                if (!hit && t ~ FOLDHEAD) {
                    pmode = 0
                    pcol = -1
                    if (incmd) pmode = 1
                    else if (tt ~ CMDKEYLINE) {
                        pcol = keycol(raw)
                        if (pcol >= 0) pmode = 2
                    } else if (tt ~ CMDHEAD) {
                        pmode = 3
                        if (tt ~ /^- /) pcol = curind
                    }
                    if (pmode) {
                        pend = t
                        pfile = substr(f, 3)
                        pline = s
                    }
                }
            }
            function is_strict(path,   i, dir, name) {
                for (i = 1; i <= ns; i++) {
                    if (S[i] != "" && (path == S[i] || index(path, S[i] "/") == 1)) return 1
                }
                for (i = 1; i <= nn; i++) {
                    if (N[i] == "") continue
                    dir = substr(N[i], 1, index(N[i], "::") - 1)
                    name = substr(N[i], index(N[i], "::") + 2)
                    if (index(path, dir "/") == 1 && (path == dir "/" name || index(path, "/" name) == length(path) - length(name))) return 1
                }
                return 0
            }
            BEGIN {
                n = split(tokens, T, "\037")
                ns = split(strictlist, S, "\037")
                nn = split(namelist, N, "\037")
                W = "(^|[^A-Za-z0-9_-])codex( -[^ ]+( [^ -][^ ]*)?)*"
                LOGIN = W " login([^A-Za-z0-9_-]|$)"
                FOLDHEAD = W " ?$"
                FOLDTAIL = "^(-[^ ]+ ([^ -][^ ]* )?)*login([^A-Za-z0-9_-]|$)"
                # auth.json as a complete basename: no name character before it
                # (a `.` or `-` would make it part of a longer name), no word
                # character after it; a trailing `.` is sentence punctuation only
                # when a blank or the end of the line follows it (sentence-final
                # `auth.json.` hits; `auth.json.example` and `auth.json..schema` do
                # not).
                AUTHJSON = "(^|[^A-Za-z0-9_.-])auth[.]json([^A-Za-z0-9_.-]|[.]( |$)|$)"
                # A quoted permission rule: a JSON string whose whole value is
                # `Name(...)` for a tool name.
                PERMRULE = "\"[A-Za-z]+[(][^\"]*[)]\""
                # Command-shaped context: a fenced sh/bash block, or a folded or
                # literal scalar under a command key; or a command-key line whose
                # value ends in codex (a plain scalar, folded by YAML like `>-`); or
                # a first line that itself begins a codex invocation (optionally a
                # list item, a `$ ` prompt or a command key, then env assignments or
                # a wrapper). A command key may be quoted, single or double (\047
                # and \042 keep the quote characters out of the shell quoting), may
                # follow a flow-mapping `{`, and may have a blank before its colon;
                # a block scalar indicator may follow `&anchor` / `!tag` properties.
                # A fence is three or more backticks or tildes.
                BT = sprintf("%c", 96)
                FENCEBT = "^" BT BT BT
                FENCETL = "^~~~"
                FENCESH = "^(" BT BT BT "|~~~)[" BT "~]* ?(sh|bash|zsh|shell|console|shell-session)( |$)"
                QT = "[\042\047]?"
                CMDKEY = QT "(run|cmd|command|script|entrypoint|args)" QT " ?:"
                BSHEAD = "(^|[ {-])" CMDKEY " *([&!][^ ]+ +)*[>|][-+0-9]*( #.*| )?$"
                KEYRE = "(^|[ {-])" CMDKEY
                CMDKEYLINE = "^(- )?([{] ?)?" CMDKEY " "
                CMDHEAD = "^(- |[$] )?([{] ?)?(" CMDKEY " )?([A-Za-z_][A-Za-z0-9_]*=[^ ]* |sudo |exec |nohup |time )*codex( -[^ ]+( [^ -][^ ]*)?)* ?$"
            }
            FNR == 1 {
                if (cont) { emit(pf, start, buf, rawfirst); buf = ""; cont = 0 }
                pf = FILENAME
                pend = ""
                fence = 0
                fshell = 0
                bs = 0
                strict = is_strict(substr(FILENAME, 3))
                permfile = (substr(FILENAME, 3) == ".claude/settings.json")
            }
            {
                line = $0
                if (line ~ /\\$/) {
                    if (!cont) { start = FNR; rawfirst = $0 }
                    sub(/\\$/, "", line)
                    buf = buf line
                    cont = 1
                    next
                }
                if (cont) { emit(FILENAME, start, buf line, rawfirst); buf = ""; cont = 0 }
                else emit(FILENAME, FNR, line, $0)
            }
            END { if (cont) emit(pf, start, buf, rawfirst) }' "${textfiles[@]}" 2>/dev/null)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "GUARD-ERROR guard could not scan the surface files"
            return 0
        fi
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            file="${line%%:*}"
            text="${line#*:}"
            text="${text#*:}"
            allowed=0
            for ((k = 0; k < ${#ALLOW_FILES[@]}; k++)); do
                [ "${ALLOW_FILES[k]}" = "$file" ] || continue
                [ "$text" = "${ALLOW_TEXTS[k]}" ] && allowed=1
            done
            [ "$allowed" -eq 1 ] || echo "$line"
        done <<<"$hits"
    fi
    echo "SCANNED ${scanned}"
}

# split_scan OUTPUT — set SCAN_ERR (a GUARD-ERROR line or empty), SCAN_HITS and
# SCAN_COUNT from scan's output.
split_scan() {
    SCAN_ERR="" SCAN_HITS="" SCAN_COUNT=""
    # scan emits a guard error as a line that BEGINS with the marker; a hit line
    # begins with its file path, so a surface line quoting the marker is a hit.
    if SCAN_ERR="$(printf '%s\n' "$1" | grep '^GUARD-ERROR ')" && [ -n "$SCAN_ERR" ]; then
        return 0
    fi
    SCAN_ERR=""
    SCAN_COUNT="${1##*SCANNED }"
    SCAN_HITS="${1%SCANNED *}"
    SCAN_HITS="${SCAN_HITS%$'\n'}"
}

# --- 1. The repository under test is clean ---
split_scan "$(scan "$PWD")"
[ -z "$SCAN_ERR" ] || fail "${SCAN_ERR#GUARD-ERROR }"
scanned="$SCAN_COUNT"
[ "$scanned" -gt 0 ] || fail "no remote-environment surface was scanned; the guard would pass vacuously"
[ -z "$SCAN_HITS" ] ||
    fail "a remote-environment surface carries Codex credential vocabulary not explained by the allowlist:
${SCAN_HITS}
The rule (AGENTS.md § \"Remote environments\"): ephemeral clouds never hold Codex credentials; a persistent environment holds one login of its own. Remove the line, or — only if it is the rule itself, a configuration path, or an operator-machine instruction — add a reasoned ALLOW entry holding the complete line."
echo "==> clean: ${scanned} surface files scanned, no unexplained Codex credential vocabulary"

# --- 2. Load-bearing: planted violations in a temporary copy must fail ---
FIX="${TMP}/fixture"
mkdir -p "$FIX"
fixture_dirs=("${SURFACE_DIRS[@]}")
[ ! -f "$SPRITES_MARKER" ] || fixture_dirs+=("$SPRITES_DIR")
for d in "${fixture_dirs[@]}"; do
    if [ -d "$d" ]; then
        mkdir -p "${FIX}/$(dirname "$d")"
        cp -R "$d" "${FIX}/$d"
    fi
done
for f in "${SURFACE_FILES[@]}"; do
    if [ -f "$f" ]; then
        mkdir -p "${FIX}/$(dirname "$f")"
        cp "$f" "${FIX}/$f"
    fi
done
for g in "${SURFACE_GLOBS[@]}"; do
    for f in $g; do
        if [ -f "$f" ]; then
            mkdir -p "${FIX}/$(dirname "$f")"
            cp "$f" "${FIX}/$f"
        fi
    done
done

fixture_hits() {
    split_scan "$(scan "$FIX")"
    [ -z "$SCAN_ERR" ] || fail "${SCAN_ERR#GUARD-ERROR }"
}

fixture_hits
[ "$SCAN_COUNT" = "$scanned" ] || fail "the fixture copy did not reproduce the scanned surface set"
[ -z "$SCAN_HITS" ] || fail "the unmodified fixture copy must scan clean"

expect_hit() {
    # expect_hit DESCRIPTION EXPECTED_FILE [EXPECTED_LINE] — the fixture must now
    # report a hit in EXPECTED_FILE (at EXPECTED_LINE, when given).
    fixture_hits
    case "$SCAN_HITS" in
    "${2}:${3:-}"*) ;;
    *) fail "$1: expected a violation in ${2}${3:+ at line ${3}}, got: ${SCAN_HITS:-<none>}" ;;
    esac
}

# plant PATH CONTENT — write CONTENT (printf %b escapes) at PATH in the fixture,
# keeping any real file there aside for unplant. A case planted this way holds in
# every profile, whether or not the repository under test ships that file.
plant() {
    # Planting the same path again overwrites the plant; the original is kept once.
    if [ "$PLANT_PATH" != "${FIX}/$1" ]; then
        PLANT_PATH="${FIX}/$1"
        PLANT_KEPT=0
        if [ -f "$PLANT_PATH" ]; then
            cp "$PLANT_PATH" "${TMP}/plant-kept"
            PLANT_KEPT=1
        fi
        mkdir -p "$(dirname "$PLANT_PATH")"
    fi
    printf '%b' "$2" >"$PLANT_PATH"
}
unplant() {
    if [ "$PLANT_KEPT" -eq 1 ]; then
        cp "${TMP}/plant-kept" "$PLANT_PATH"
    else
        rm -f "$PLANT_PATH"
    fi
    PLANT_PATH=""
}
PLANT_PATH=""
PLANT_KEPT=0

# Every token, planted in a file under a scanned directory, reported at its line.
mkdir -p "${FIX}/.devcontainer/agent"
planted=".devcontainer/agent/planted.sh"
for tok in "${TOKENS[@]}"; do
    printf 'echo start\nrun codex %s now\n' "$tok" >"${FIX}/${planted}"
    expect_hit "token '${tok}' in a scanned directory" "$planted" "2:"
done

# A command split across physical lines by a backslash is still one command.
printf 'echo start\ncodex \\\n    login --device-flow\n' >"${FIX}/${planted}"
expect_hit "a backslash-continued codex login" "$planted" "2:"
rm -f "${FIX}/${planted}"

# Runs of blanks do not hide the command: two spaces, and a tab, still match.
printf 'echo start\ncodex  login\n' >"${FIX}/${planted}"
expect_hit "codex login with two spaces" "$planted" "2:"
printf 'echo start\ncodex\tlogin\n' >"${FIX}/${planted}"
expect_hit "codex login separated by a tab" "$planted" "2:"
printf 'echo start\nrun codex  --device-auth  now\n' >"${FIX}/${planted}"
expect_hit "a token flanked by doubled blanks" "$planted" "2:"
rm -f "${FIX}/${planted}"

# The login is an invariant, not a literal: options between the words do not hide it.
printf 'echo start\ncodex --no-alt-screen login\n' >"${FIX}/${planted}"
expect_hit "codex with an option before login" "$planted" "2:"
printf 'echo start\ncodex -c x=y login\n' >"${FIX}/${planted}"
expect_hit "codex with a valued option before login" "$planted" "2:"
printf 'echo start\ncodex -c x=y login --device-auth\n' >"${FIX}/${planted}"
expect_hit "codex with options around login" "$planted" "2:"
printf 'echo start\ncodex review --base main\n' >"${FIX}/${planted}"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a codex subcommand other than login must not match, got: ${SCAN_HITS}"
rm -f "${FIX}/${planted}"

# OPENAI_API_KEY alone is application configuration; paired with codex it is not.
mkdir -p "${FIX}/.github/workflows" "${FIX}/docs/guides"
printf 'jobs:\n  a:\n    env:\n      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}\n' >"${FIX}/.github/workflows/app.yml"
printf '# App\n\nSet OPENAI_API_KEY for the app.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "an application's own OPENAI_API_KEY must not be reported, got: ${SCAN_HITS}"
rm -f "${FIX}/.github/workflows/app.yml" "${FIX}/docs/guides/planted-app.md"
printf 'echo start\nOPENAI_API_KEY=$K codex exec review\n' >"${FIX}/${planted}"
expect_hit "OPENAI_API_KEY paired with codex" "$planted" "2:"
printf 'echo start\nCODEX_HOME=x OPENAI_API_KEY=$K node app.js\n' >"${FIX}/${planted}"
expect_hit "OPENAI_API_KEY paired with CODEX_HOME (any case)" "$planted" "2:"
rm -f "${FIX}/${planted}"

# The one rule outside the strict tier: a line counts only if it mentions codex. An
# application's own CLI and configuration use the same flags and names.
mkdir -p "${FIX}/.github/workflows" "${FIX}/docs/guides"
printf '# App\n\nRun our-app login --with-api-key to sign in.\n' >"${FIX}/docs/guides/planted-app.md"
printf 'jobs:\n  a:\n    steps:\n      - run: tool --device-auth\n      - run: tool --with-access-token "$T"\n' >"${FIX}/.github/workflows/app.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "an application's own login flags must not be reported, got: ${SCAN_HITS}"
rm -f "${FIX}/.github/workflows/app.yml"
printf '# App\n\nRun codex login --with-api-key to sign in.\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "codex login with a flag in a guide" "docs/guides/planted-app.md" "3:"
printf '# App\n\nRun codex --with-api-key to sign in.\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a login flag on a codex line in a guide" "docs/guides/planted-app.md" "3:"
rm -f "${FIX}/docs/guides/planted-app.md"

# Strict tier: nothing that provisions a remote environment may carry the key or
# an auth.json at all (no `codex` needed); outside it only their Codex use counts.
strict_cases=0
for sf in scripts/setup-remote.sh .github/workflows/remote-bootstrap.yml; do
    [ -f "${FIX}/${sf}" ] || continue
    strict_cases=$((strict_cases + 1))
    cp "${FIX}/${sf}" "${TMP}/saved"
    printf '\nexport OPENAI_API_KEY=x\n' >>"${FIX}/${sf}"
    expect_hit "a bare OPENAI_API_KEY in ${sf}" "$sf"
    cp "${TMP}/saved" "${FIX}/${sf}"
    printf '\ncat auth.json\n' >>"${FIX}/${sf}"
    expect_hit "a bare auth.json in ${sf}" "$sf"
    cp "${TMP}/saved" "${FIX}/${sf}"
    printf '\ntool --with-api-key\n' >>"${FIX}/${sf}"
    expect_hit "a bare login flag in ${sf}" "$sf"
    cp "${TMP}/saved" "${FIX}/${sf}"
done
if [ -d "${FIX}/images/devcontainer" ]; then
    strict_cases=$((strict_cases + 1))
    printf 'echo start\nexport OPENAI_API_KEY=x\n' >"${FIX}/images/devcontainer/planted.sh"
    expect_hit "a bare OPENAI_API_KEY under images/devcontainer" "images/devcontainer/planted.sh" "2:"
    printf 'echo start\ncat auth.json\n' >"${FIX}/images/devcontainer/planted.sh"
    expect_hit "a bare auth.json under images/devcontainer" "images/devcontainer/planted.sh" "2:"
    rm -f "${FIX}/images/devcontainer/planted.sh"
fi
if [ -f "${FIX}/${SPRITES_MARKER}" ]; then
    strict_cases=$((strict_cases + 1))
    printf 'echo start\nexport OPENAI_API_KEY=x\n' >"${FIX}/sprites/planted.sh"
    expect_hit "a bare OPENAI_API_KEY under sprites" "sprites/planted.sh" "2:"
    printf 'echo start\ncat auth.json\n' >"${FIX}/sprites/planted.sh"
    expect_hit "a bare auth.json under sprites" "sprites/planted.sh" "2:"
    rm -f "${FIX}/sprites/planted.sh"
fi
# Without the marker, a sprites/ directory is not the provisioning surface: a
# consumer's unrelated sprites/ holding a bare key line is not reported.
mkdir -p "${FIX}/sprites"
[ ! -f "${FIX}/${SPRITES_MARKER}" ] || mv "${FIX}/${SPRITES_MARKER}" "${TMP}/sprites-marker"
printf 'echo start\nexport OPENAI_API_KEY=x\n' >"${FIX}/sprites/planted.sh"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sprites/ directory without ${SPRITES_MARKER} was scanned as the Sprites surface, got: ${SCAN_HITS}"
rm -f "${FIX}/sprites/planted.sh"
[ ! -f "${TMP}/sprites-marker" ] || mv "${TMP}/sprites-marker" "${FIX}/${SPRITES_MARKER}"
[ "$strict_cases" -gt 0 ] || fail "no strict-tier surface exists in the fixture; the strict-tier cases would pass vacuously"
# The environment examples are strict too, wherever they sit under .devcontainer.
env_cases=0
for ef in .devcontainer/devcontainer.env.example .devcontainer/agent/devcontainer.env.example; do
    [ -f "${FIX}/${ef}" ] || continue
    env_cases=$((env_cases + 1))
    cp "${FIX}/${ef}" "${TMP}/saved"
    printf '\nOPENAI_API_KEY=\n' >>"${FIX}/${ef}"
    expect_hit "a bare OPENAI_API_KEY in ${ef}" "$ef"
    cp "${TMP}/saved" "${FIX}/${ef}"
done
# The examples ship only with the devcontainer, so the floor applies only where the
# repository under test has one (not the fixture, which this test builds a
# .devcontainer in): a devcontainer without its example is a vacuous pass and fails.
if [ -d .devcontainer ] && [ "$env_cases" -eq 0 ]; then
    fail "a .devcontainer exists but no environment example does; the env-example cases would pass vacuously"
fi
# A setup script is scanned whatever its name after setup-, with the Codex-scoped rule.
mkdir -p "${FIX}/scripts"
printf '#!/usr/bin/env bash\ncodex login\n' >"${FIX}/scripts/setup-db.sh"
expect_hit "a login in a new setup script" "scripts/setup-db.sh" "2:"
# ... but only a remote-setup entry point is strict: a project's own setup script may
# hold its own bare key or auth.json (no codex on the line) and still pass,
printf '#!/usr/bin/env bash\nexport OPENAI_API_KEY=x\ncat auth.json\n' >"${FIX}/scripts/setup-db.sh"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a project's own setup script with a bare key or auth.json must pass, got: ${SCAN_HITS}"
rm -f "${FIX}/scripts/setup-db.sh"
# ... while the remote-setup entry point and any setup-remote*.sh fail on the same lines.
for rs in scripts/setup-remote.sh scripts/setup-remote-sprite.sh; do
    plant "$rs" '#!/usr/bin/env bash\nexport OPENAI_API_KEY=x\n'
    expect_hit "a bare OPENAI_API_KEY in ${rs}" "$rs" "2:"
    plant "$rs" '#!/usr/bin/env bash\ncat auth.json\n'
    expect_hit "a bare auth.json in ${rs}" "$rs" "2:"
    unplant
done
fixture_hits
[ -z "$SCAN_HITS" ] || fail "restoring the remote-setup scripts must scan clean again, got: ${SCAN_HITS}"

# auth.json is matched as a complete basename: on a strict surface `auth.json` and
# `~/.codex/auth.json` fail, `oauth.json` and `myauth.json` pass.
authf="scripts/setup-remote-auth.sh"
plant "$authf" '#!/usr/bin/env bash\ncat oauth.json\ncat myauth.json\ncat ~/tokens/oauth.json\n'
fixture_hits
[ -z "$SCAN_HITS" ] || fail "oauth.json and myauth.json must not match auth.json, got: ${SCAN_HITS}"
# A longer name that merely starts with auth.json is not the credential file, but a
# sentence-final dot after it still is.
plant "$authf" '#!/usr/bin/env bash\ncat auth.json.example\ncat auth.json.bak\n'
fixture_hits
[ -z "$SCAN_HITS" ] || fail "auth.json.example and auth.json.bak must not match auth.json, got: ${SCAN_HITS}"
plant "$authf" '#!/usr/bin/env bash\ncat auth.json..schema\ncat auth.json.~1~\n'
fixture_hits
[ -z "$SCAN_HITS" ] || fail "auth.json..schema and auth.json.~1~ must not match auth.json, got: ${SCAN_HITS}"
plant "$authf" '#!/usr/bin/env bash\n# Restore auth.json.\n'
expect_hit "a sentence-final auth.json." "$authf" "2:"
plant "$authf" '#!/usr/bin/env bash\n# Restore auth.json. Then retry.\n'
expect_hit "an auth.json. before a blank" "$authf" "2:"
plant "$authf" '#!/usr/bin/env bash\ncat auth.json\n'
expect_hit "a bare auth.json" "$authf" "2:"
plant "$authf" '#!/usr/bin/env bash\nrm "$HOME/auth.json"\n'
expect_hit "a quoted auth.json path" "$authf" "2:"
plant "$authf" '#!/usr/bin/env bash\ncp ~/.codex/auth.json /tmp/x\n'
expect_hit "~/.codex/auth.json" "$authf" "2:"
unplant
# ... and under the Codex-scoped rule: codex on the line plus a lookalike is not a hit.
mkdir -p "${FIX}/docs/guides"
printf '# App\n\nRun codex review, then read oauth.json and myauth.json.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a codex line naming only oauth.json or myauth.json must pass, got: ${SCAN_HITS}"
rm -f "${FIX}/docs/guides/planted-app.md"

# The Claude Code on the web settings and the bootstrap helper setup-remote.sh runs
# are strict surfaces: a bare key fails, in either layer; a sibling script does not.
plant .claude/settings.json '{\n  "env": {\n    "OPENAI_API_KEY": "x"\n  }\n}\n'
expect_hit "a bare OPENAI_API_KEY in .claude/settings.json" ".claude/settings.json" "3:"
# A permission rule that PROTECTS a credential file is not a credential: in that one
# file a quoted Name(...) string is exempt, one per line or several on one line. An
# env block in the same file, and the same rule line anywhere else, still fail.
plant .claude/settings.json '{\n  "permissions": {\n    "deny": [\n      "Read(~/.codex/auth.json)",\n      "Read(**/auth.json)"\n    ]\n  }\n}\n'
fixture_hits
[ -z "$SCAN_HITS" ] || fail "permission deny rules naming auth.json must pass in .claude/settings.json, got: ${SCAN_HITS}"
plant .claude/settings.json '{\n  "permissions": {\n    "deny": ["Read(~/.codex/auth.json)", "Read(**/auth.json)", "Bash(cat ~/.codex/*)"]\n  }\n}\n'
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a one-line list of permission deny rules must pass in .claude/settings.json, got: ${SCAN_HITS}"
plant .claude/settings.json '{\n  "permissions": {\n    "deny": ["Read(~/.codex/auth.json)"]\n  },\n  "env": {\n    "OPENAI_API_KEY": "x"\n  }\n}\n'
expect_hit "an env OPENAI_API_KEY beside permission rules in .claude/settings.json" ".claude/settings.json" "6:"
plant .claude/settings.json '{\n  "permissions": {\n    "deny": ["Read(~/.codex/auth.json)"],\n    "note": "~/.codex/auth.json"\n  }\n}\n'
expect_hit "a non-rule string naming ~/.codex/auth.json in .claude/settings.json" ".claude/settings.json" "4:"
unplant
plant .devcontainer/scripts/bootstrap-related-repos.sh '#!/usr/bin/env bash\n"Read(~/.codex/auth.json)"\n'
expect_hit "a permission-rule-shaped line outside .claude/settings.json" ".devcontainer/scripts/bootstrap-related-repos.sh" "2:"
unplant
plant .devcontainer/scripts/bootstrap-related-repos.sh '#!/usr/bin/env bash\nexport OPENAI_API_KEY=x\n'
expect_hit "a bare OPENAI_API_KEY in the bootstrap helper" ".devcontainer/scripts/bootstrap-related-repos.sh" "2:"
unplant
plant .devcontainer/scripts/planted-sibling.sh '#!/usr/bin/env bash\nexport OPENAI_API_KEY=x\n'
fixture_hits
[ -z "$SCAN_HITS" ] || fail "only the bootstrap helper is strict under .devcontainer/scripts, got: ${SCAN_HITS}"
unplant
fixture_hits
[ -z "$SCAN_HITS" ] || fail "restoring the settings and bootstrap fixtures must scan clean again, got: ${SCAN_HITS}"
# Outside the strict tier an app's own key or auth.json passes; the Codex one fails.
mkdir -p "${FIX}/docs/guides"
printf '# App\n\nOur app stores sessions in auth.json.\n' >"${FIX}/docs/guides/planted-app.md"
printf 'echo start\nexport OPENAI_API_KEY=x\n' >"${FIX}/${planted}"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "an app's own auth.json or key outside the strict tier must pass, got: ${SCAN_HITS}"
printf '# App\n\nCopy ~/.codex/auth.json to the VM.\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "~/.codex/auth.json in a guide" "docs/guides/planted-app.md" "3:"
printf '# App\n\nRestore the codex credentials into auth.json.\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "auth.json with codex but no directory in a guide" "docs/guides/planted-app.md" "3:"
rm -f "${FIX}/docs/guides/planted-app.md" "${FIX}/${planted}"

# A YAML-folded command: `codex` ends one line, `login` opens the next; options
# may sit on either side of the fold. Reported with both real lines.
mkdir -p "${FIX}/.github/workflows"
printf 'name: x\njobs:\n  a:\n    steps:\n      - run: >-\n          codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a YAML-folded codex / login" ".github/workflows/folded.yml" "6-7: "
printf 'name: x\njobs:\n  a:\n    steps:\n      - run: >-\n          codex --no-alt-screen\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a folded codex with an option, then login" ".github/workflows/folded.yml" "6-7: "
printf 'name: x\njobs:\n  a:\n    steps:\n      - run: >-\n          codex\n          --no-alt-screen login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a folded codex, then an option and login" ".github/workflows/folded.yml" "6-7: "
printf 'jobs:\n  a:\n    steps:\n      - run: echo codex\n        login-check: x\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "codex followed by a login-prefixed word must not match, got: ${SCAN_HITS}"
# Only a command-shaped line starts a fold: consecutive YAML mapping lines naming
# codex and login are configuration, in a workflow or in a guide (fenced or not).
printf 'jobs:\n  a:\n    steps:\n      - uses: x\n        with:\n          provider: codex\n          login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "consecutive provider: codex / login: oauth mapping lines must pass, got: ${SCAN_HITS}"
# A tail completes a fold only when it continues the same command. A sibling key
# on the very next line has left the scalar (or the plain scalar's key column), so
# `codex` then `login: oauth` is configuration, not a folded login.
printf 'jobs:\n  a:\n    steps:\n      - run: >-\n          codex\n        login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: key right after a folded run scalar must pass, got: ${SCAN_HITS}"
printf 'jobs:\n  a:\n    steps:\n      - script: >-\n          echo hi && codex\n        login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: key right after a folded script scalar must pass, got: ${SCAN_HITS}"
printf 'jobs:\n  a:\n    steps:\n      - run: echo hi && codex\n        login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: key right after a plain run value must pass, got: ${SCAN_HITS}"
printf 'jobs:\n  a:\n    steps:\n      - run: codex\n        login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: key right after a run: codex value must pass, got: ${SCAN_HITS}"
# A plain (unindicated) multi-line scalar under a command key is folded by YAML like
# `>-`: a value ending in codex, whatever precedes it, and a deeper continuation.
printf 'jobs:\n  a:\n    steps:\n      - run: echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a plain multi-line run scalar ending in codex, then login" ".github/workflows/folded.yml" "4-5: "
printf 'jobs:\n  a:\n    steps:\n      - run: codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a plain multi-line run scalar of codex, then login" ".github/workflows/folded.yml" "4-5: "
printf 'jobs:\n  a:\n    steps:\n      - run: codex login --device-auth\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "the one-line codex login control" ".github/workflows/folded.yml" "4:"
# A sequence item `- codex` is bounded by its dash: a sibling key at the dash's
# column is not a continuation, a deeper line is. A `$ codex` prompt line has no bound.
printf 'cmds:\n  - codex\n  login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: key after a - codex item must pass, got: ${SCAN_HITS}"
printf 'cmds:\n  - codex\nlogin: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a shallower login: key after a - codex item must pass, got: ${SCAN_HITS}"
printf 'cmds:\n  - codex\n    login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a deeper login after a - codex item" ".github/workflows/folded.yml" "2-3: "
# A block scalar indicator may follow node properties (an anchor or a tag).
printf 'jobs:\n  a:\n    steps:\n      - run: &x >-\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "an anchored block scalar" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - run: !!str |\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a tagged block scalar" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - run: &x !!str >-\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "an anchored and tagged block scalar" ".github/workflows/folded.yml" "5-6: "
# A command key may sit in a flow mapping or have a blank before its colon, plain
# or as a block scalar.
printf 'jobs:\n  a:\n    steps:\n      - {run: echo hi && codex\n          login}\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a flow-mapping run value ending in codex, then login" ".github/workflows/folded.yml" "4-5: "
printf 'jobs:\n  a:\n    steps:\n      - run : echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a run key with a blank before its colon, plain value" ".github/workflows/folded.yml" "4-5: "
printf 'jobs:\n  a:\n    steps:\n      - "run" : >-\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a quoted run key with a blank before its colon, block scalar" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - run : |\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a run key with a blank before its colon, literal scalar" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - {run: echo hi && codex}\n      - login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: item after a flow mapping must pass, got: ${SCAN_HITS}"
# A fence inside a literal scalar is its content: a heredoc writing Markdown does not
# end the command context for the lines after it.
printf 'jobs:\n  a:\n    steps:\n      - run: |\n          cat > x.md <<EOF\n          ```\n          text\n          ```\n          EOF\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a command after a fenced heredoc inside a run scalar" ".github/workflows/folded.yml" "10-11: "
# Tab-indented keys are read as blanks: a scalar opens at the key's column and ends
# when the indentation returns to it, never running on through the rest of a page.
printf '\trun: >-\n\t\t  echo hi && codex\n\t\t  login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a tab-indented run scalar" ".github/workflows/folded.yml" "2-3: "
# A command key may be quoted, single or double, in a block scalar or a plain value.
printf 'jobs:\n  a:\n    steps:\n      - "run": >-\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a double-quoted run key with a folded scalar" ".github/workflows/folded.yml" "5-6: "
printf "jobs:\n  a:\n    steps:\n      - 'run': |\n          echo hi && codex\n          login\n" >"${FIX}/.github/workflows/folded.yml"
expect_hit "a single-quoted run key with a literal scalar" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - "run": codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a double-quoted run key with a plain multi-line value" ".github/workflows/folded.yml" "4-5: "
printf 'jobs:\n  a:\n    steps:\n      - "run": >-\n          codex\n        login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a sibling login: key after a quoted-key scalar must pass, got: ${SCAN_HITS}"
# The block-scalar indicator may be followed by a comment or by blanks.
printf 'jobs:\n  a:\n    steps:\n      - run: >- # install\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a block scalar indicator followed by a comment" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - run: >-  \n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a block scalar indicator followed by blanks" ".github/workflows/folded.yml" "5-6: "
# Command context decides a head that does not itself begin with codex: inside a
# run scalar, `echo hi && codex` / `login` is a folded login; as a mapping value
# outside any command context it is not.
printf 'jobs:\n  a:\n    steps:\n      - run: >-\n          echo hi && codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a folded codex after another command in a run scalar" ".github/workflows/folded.yml" "5-6: "
printf 'jobs:\n  a:\n    steps:\n      - name: use codex\n        env:\n          note: echo hi && codex\n          login: oauth\n' >"${FIX}/.github/workflows/folded.yml"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a mapping value ending in codex outside a command scalar must pass, got: ${SCAN_HITS}"
# A literal scalar under a command key is command context too.
printf 'jobs:\n  a:\n    steps:\n      - run: |\n          codex\n          login\n' >"${FIX}/.github/workflows/folded.yml"
expect_hit "a literal run scalar with codex / login" ".github/workflows/folded.yml" "5-6: "
rm -f "${FIX}/.github/workflows/folded.yml"
mkdir -p "${FIX}/docs/guides"
printf '# Guide\n\nprovider: codex\nlogin: oauth\n\n```yaml\nprovider: codex\nlogin: oauth\n```\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "provider: codex / login: oauth in a guide must pass, got: ${SCAN_HITS}"
printf '# Guide\n\n```sh\ncodex\nlogin\n```\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a codex / login pair in a fenced sh block" "docs/guides/planted-app.md" "4-5: "
printf '# Guide\n\n```sh\necho hi && codex\nlogin\n```\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a codex after another command in a fenced sh block" "docs/guides/planted-app.md" "4-5: "
printf '# Guide\n\nUse the tool, then codex\nlogin is not required.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "prose wrapped across lines outside a command block must pass, got: ${SCAN_HITS}"
# A fence ends any block scalar a snippet opened: a shallow `run: |` inside a fenced
# yaml snippet does not stay open past the closing fence, so indented prose after it
# is prose.
printf '# Guide\n\n```yaml\nrun: |\n  echo hi\n```\n\n    Then codex\n    login is required.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "indented prose after a fenced snippet that opened a scalar must pass, got: ${SCAN_HITS}"
printf '# Guide\n\n\trun: |\n\t  echo hi\n\nThen codex\nlogin is required.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "prose after a tab-indented scalar must pass, got: ${SCAN_HITS}"
# A fence is three or more backticks or tildes, closed by the same character.
printf '# Guide\n\n~~~sh\necho hi && codex\nlogin\n~~~\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a codex / login pair in a tilde-fenced sh block" "docs/guides/planted-app.md" "4-5: "
printf '# Guide\n\n````sh\necho hi && codex\nlogin\n````\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a codex / login pair in a four-backtick sh fence" "docs/guides/planted-app.md" "4-5: "
printf '# Guide\n\n````sh\n```\necho hi && codex\nlogin\n````\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a shorter backtick run inside a four-backtick fence does not close it" "docs/guides/planted-app.md" "5-6: "
printf '# Guide\n\n~~~~sh\n~~~\necho hi && codex\nlogin\n~~~~\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a shorter tilde run inside a four-tilde fence does not close it" "docs/guides/planted-app.md" "5-6: "
printf '# Guide\n\n```sh\necho hi\n````\nThen codex\nlogin is required.\n' >"${FIX}/docs/guides/planted-app.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "a longer run closes a shorter fence, so prose after it must pass, got: ${SCAN_HITS}"
printf '# Guide\n\n~~~sh\nx\n```\necho hi && codex\nlogin\n~~~\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a backtick line inside a tilde fence does not close it" "docs/guides/planted-app.md" "6-7: "
printf '# Guide\n\n```yaml\nsteps:\n  - run: >-\n      codex\n      login\n```\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a folded run scalar in a fenced yaml block" "docs/guides/planted-app.md" "6-7: "
printf '# Guide\n\n$ codex\nlogin\n' >"${FIX}/docs/guides/planted-app.md"
expect_hit "a codex invocation line followed by login" "docs/guides/planted-app.md" "3-4: "
rm -f "${FIX}/docs/guides/planted-app.md"

# A surface line that merely contains the guard-error marker is a violation (it
# carries a token), never mistaken for a guard error.
printf 'echo start\nGUARD-ERROR ~/.codex leaked\n' >"${FIX}/${planted}"
expect_hit "a surface line quoting the guard-error marker" "$planted" "2:"
rm -f "${FIX}/${planted}"

# The workflow directory is scanned as a whole, not one named file.
mkdir -p "${FIX}/.github/workflows"
printf 'name: x\nenv:\n  A: x\n  run: OPENAI_API_KEY=$K codex exec\n' >"${FIX}/.github/workflows/planted.yml"
expect_hit "a token in an arbitrary workflow" ".github/workflows/planted.yml" "4:"
rm -f "${FIX}/.github/workflows/planted.yml"

# All of docs/ is scanned except docs/research/ (rejected-option assessments).
mkdir -p "${FIX}/docs/decisions" "${FIX}/docs/research"
printf 'x\nrun codex --device-auth\n' >"${FIX}/docs/research/planted.md"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "docs/research/ must not be scanned, got: ${SCAN_HITS}"
printf 'x\nrun codex --device-auth\n' >"${FIX}/docs/decisions/planted.md"
expect_hit "a token in docs/decisions" "docs/decisions/planted.md" "2:"
rm -f "${FIX}/docs/research/planted.md" "${FIX}/docs/decisions/planted.md"

# A scanned file: a violating line that is not an allowlisted line.
for f in docs/guides/codex-review.md docs/architecture/remote-environments.md AGENTS.md; do
    [ -f "${FIX}/${f}" ] || continue
    cp "${FIX}/${f}" "${TMP}/saved"
    printf '\ncp ~/.codex/auth.json /tmp/seed.json\n' >>"${FIX}/${f}"
    expect_hit "an unexplained auth file in ${f}" "$f"
    cp "${TMP}/saved" "${FIX}/${f}"
done

# An allowlisted line quoted inside a new prescriptive sentence must still fail:
# the allowlist excuses complete lines, never the phrases inside them. One
# scratch copy carries every entry's phrase relocated into its own sentence
# (distinct lines); one scan must report every one of them.
FIX_FULL="${TMP}/fixture-relocated"
cp -R "$FIX" "$FIX_FULL"
relocated=0
for entry in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    efile="${entry%%@@*}"
    etext="${entry#*@@}"
    etext="${etext%%@@*}"
    [ -f "${FIX_FULL}/${efile}" ] || continue
    relocated=$((relocated + 1))
    printf '\nOn every ephemeral VM, do this first [relocated-%s]: %s\n' "$relocated" "$etext" >>"${FIX_FULL}/${efile}"
done
[ "$relocated" -gt 0 ] || fail "no allowlist entry could be relocated; the quoting case would pass vacuously"
split_scan "$(scan "$FIX_FULL")"
[ -z "$SCAN_ERR" ] || fail "${SCAN_ERR#GUARD-ERROR }"
for ((i = 1; i <= relocated; i++)); do
    case "$SCAN_HITS" in
    *"[relocated-${i}]:"*) ;;
    *) fail "an excused line relocated into a prescriptive sentence was not reported (entry ${i} of ${relocated})" ;;
    esac
done
[ "$(printf '%s\n' "$SCAN_HITS" | grep -c 'relocated-')" -eq "$relocated" ] ||
    fail "expected exactly ${relocated} relocated-phrase hits, got: ${SCAN_HITS}"
fixture_hits
[ -z "$SCAN_HITS" ] || fail "restoring the fixture must scan clean again"

# A file the guard cannot read is an error, never a silent pass. Root reads
# everything, so the case cannot be staged there.
if [ "$(id -u)" -eq 0 ]; then
    echo "==> skipped: the unreadable-file case cannot run as root"
else
    printf 'harmless\n' >"${FIX}/.devcontainer/agent/unreadable.sh"
    chmod 000 "${FIX}/.devcontainer/agent/unreadable.sh"
    split_scan "$(scan "$FIX")"
    case "$SCAN_ERR" in
    *"could not read .devcontainer/agent/unreadable.sh"*) ;;
    *) fail "an unreadable surface file must be a guard error, got: ${SCAN_ERR:-<none>} ${SCAN_HITS}" ;;
    esac
    chmod 600 "${FIX}/.devcontainer/agent/unreadable.sh"
    rm -f "${FIX}/.devcontainer/agent/unreadable.sh"
fi

# A surface directory the guard cannot list is an error too: find's failure must
# not let the directory drop out of the scan. Root lists everything.
if [ "$(id -u)" -eq 0 ]; then
    echo "==> skipped: the unlistable-directory case cannot run as root"
else
    mkdir -p "${FIX}/.devcontainer/unlistable"
    printf 'harmless\n' >"${FIX}/.devcontainer/unlistable/file.sh"
    chmod 000 "${FIX}/.devcontainer/unlistable"
    split_scan "$(scan "$FIX")"
    case "$SCAN_ERR" in
    *"could not list .devcontainer"*) ;;
    *) fail "an unlistable surface directory must be a guard error, got: ${SCAN_ERR:-<none>} ${SCAN_HITS}" ;;
    esac
    chmod 755 "${FIX}/.devcontainer/unlistable"
    rm -rf "${FIX}/.devcontainer/unlistable"
fi

# A root with none of the surfaces scans nothing — which the caller rejects.
mkdir -p "${TMP}/empty"
[ "$(scan "${TMP}/empty" | tail -n 1)" = "SCANNED 0" ] || fail "an empty root must report SCANNED 0"

echo "remote codex policy OK: ${scanned} surface files clean; planted violations fail for all ${#TOKENS[@]} plain tokens and every pattern rule"
