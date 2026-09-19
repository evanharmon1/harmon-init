#!/usr/bin/env bash
set -euo pipefail

# Assert the devcontainer permission/isolation invariants.
#
# Two modes:
#   unit                       — no container, no real secrets. Exercises the
#                                real init-env.sh / tailscale-connect.sh scripts
#                                and the static devcontainer.json invariants.
#   container <cfg> <id> <prf> — runs inside an already-started container (via
#                                `docker exec`) to assert the live git identity,
#                                tailscale presence, and stripped env.
#
# Kept verbatim-portable: generated projects ship this script unchanged, so the
# git-identity assertions check RELATIONSHIPS (e.g. a "-bot" suffix), never the
# template author's literal name/email.

fail() {
    echo "ASSERT FAIL: $*" >&2
    exit 1
}

# Read a scalar from the document root without depending on yq's TOML parser.
# The yq build available on GitHub's Ubuntu runner interprets TOML arrays of
# tables differently from the Homebrew build, even for an unrelated root key.
toml_root_scalar() {
    local key="$1" file="$2"
    awk -v key="$key" '
        BEGIN { in_root = 1 }
        /^[[:space:]]*\[/ { in_root = 0 }
        in_root {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
                sub(/[[:space:]]*$/, "", line)
                if (line ~ /^".*"$/) {
                    sub(/^"/, "", line)
                    sub(/"$/, "", line)
                }
                print line
                exit
            }
        }
    ' "$file"
}

# renovate: datasource=npm depName=@devcontainers/cli
DEVCONTAINER_CLI_VERSION=0.89.0

devcontainer_cli() {
    if command -v devcontainer >/dev/null 2>&1; then
        devcontainer "$@"
    else
        npx --yes "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}" "$@"
    fi
}

# The shared toolchain image every consumer Dockerfile must extend. The
# package is public and identical for all generated repos, so the literal
# name stays verbatim-portable.
HARMON_IMAGE="ghcr.io/evanharmon1/harmon-devcontainer"
HARMON_IMAGE_MANIFEST="/usr/local/share/harmon-devcontainer/manifest.json"

# The ONE image for which "Copilot autonomy is enabled but there is no
# copilot binary" is a legitimate state rather than a defect: the
# pre-harness-matrix pin, which ships no copilot at all. Bounding the
# exception to this exact digest makes it EXPIRE by itself the moment the
# sync-pin PR (#1152) bumps .devcontainer/Dockerfile — after that, an
# enabled marker with no wrapper-resolving copilot is a real failure on
# every image, which is what keeps the assertion from being a permanent
# success-note. See
# https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/tasks.md
# task 5.5.
HARMON_PRE_HARNESS_MATRIX_DIGEST="sha256:b8a305693e996ac5289bf6f18ae47dd75d9d04ed1763499ef03f52949ea5b519"

# assert_image_pin <dockerfile>
# The Dockerfile must extend exactly one approved immutable reference —
# the public package pinned by BOTH the sha-<40-hex-source-commit> tag and
# the sha256 manifest-list digest. Floating tags (latest, main, release
# aliases) or digestless tags could silently change bytes under every
# consumer, so any other FROM shape fails (harmon-init#489).
assert_image_pin() {
    # Dockerfile instructions are case-insensitive and tolerate leading
    # whitespace, so match by uppercased first token — a lowercase `from` or
    # trailing `user root` must not slip past the pin/permission checks.
    local dockerfile="$1" from_count ref source digest last_user
    from_count="$(awk 'toupper($1) == "FROM" { n++ } END { print n + 0 }' "$dockerfile")"
    [ "$from_count" = "1" ] ||
        fail "${dockerfile} must have exactly one FROM line extending the shared image (found ${from_count})"
    ref="$(awk 'toupper($1) == "FROM" { print $2; exit }' "$dockerfile")"
    case "$ref" in
    "${HARMON_IMAGE}:sha-"*"@sha256:"*) ;;
    *) fail "${dockerfile} FROM '${ref}' is not the approved immutable '${HARMON_IMAGE}:sha-<source-commit>@sha256:<manifest-digest>' reference" ;;
    esac
    source="${ref#"${HARMON_IMAGE}:sha-"}"
    source="${source%%@*}"
    digest="${ref##*@sha256:}"
    case "$source" in
    ????????????????????????????????????????)
        case "$source" in *[!0-9a-f]*) fail "${dockerfile} image tag 'sha-${source}' is not a 40-hex source commit" ;; esac
        ;;
    *) fail "${dockerfile} image tag 'sha-${source}' is not a 40-hex source commit" ;;
    esac
    case "$digest" in
    ????????????????????????????????????????????????????????????????)
        case "$digest" in *[!0-9a-f]*) fail "${dockerfile} image digest 'sha256:${digest}' is not a 64-hex manifest digest" ;; esac
        ;;
    *) fail "${dockerfile} image digest 'sha256:${digest}' is not a 64-hex manifest digest" ;;
    esac
    awk 'toupper($1) == "RUN" && $2 == "/usr/local/sbin/install-harmon-repo-config" && NF == 2 { found = 1 }
        END { exit !found }' "$dockerfile" ||
        fail "${dockerfile} does not invoke the image's install-harmon-repo-config overlay installer"
    last_user="$(awk 'toupper($1) == "USER" { user = $2 } END { print user }' "$dockerfile")"
    [ "$last_user" = "vscode" ] ||
        fail "${dockerfile} does not finish as USER vscode (last USER is '${last_user}')"
    printf '%s\n' "$source"
}

# pinned_image_digest <dockerfile>  — the sha256 manifest digest off the
# Dockerfile's FROM line. assert_image_pin has already proved the reference's
# shape and that the RUNNING container's manifest revision matches its source
# commit, so this is a read of an already-validated pin, not a second parser.
pinned_image_digest() {
    local ref
    ref="$(awk 'toupper($1) == "FROM" { print $2; exit }' "$1")"
    printf 'sha256:%s' "${ref##*@sha256:}"
}

# ── unit mode ─────────────────────────────────────────────────────────
assert_unit() {
    # Resolve the repo root from the script's own location BEFORE we cd away,
    # so init-env.sh's "only pull on a clean main" guard short-circuits when we
    # run it from a throwaway, non-repo working directory.
    local script_dir repo_root init_env ts_connect bash_bin codex_config
    local bot_autonomy bot_autonomy_module_dir codex_module claude_module codex_bot_config
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
    init_env="${repo_root}/.devcontainer/scripts/init-env.sh"
    ts_connect="${repo_root}/.devcontainer/scripts/tailscale-connect.sh"
    codex_config="${repo_root}/.devcontainer/config/codex-managed-config.toml"
    bot_autonomy="${repo_root}/.devcontainer/scripts/bot-autonomy.sh"
    bot_autonomy_module_dir="${repo_root}/.devcontainer/config/bot-autonomy"
    codex_module="${bot_autonomy_module_dir}/codex-cli.sh"
    claude_module="${bot_autonomy_module_dir}/claude-code.sh"
    codex_bot_config="${repo_root}/.devcontainer/config/codex-managed-config.bot.toml"
    bash_bin="$(command -v bash)"

    [ -f "$init_env" ] || fail "init-env.sh not found at ${init_env}"
    [ -f "$ts_connect" ] || fail "tailscale-connect.sh not found at ${ts_connect}"
    [ -f "$codex_config" ] || fail "Codex managed config not found at ${codex_config}"
    [ -x "$bot_autonomy" ] || fail "bot-autonomy.sh not found or not executable at ${bot_autonomy}"
    [ -x "$codex_module" ] || fail "bot-autonomy Codex module not found at ${codex_module}"
    [ -x "$claude_module" ] || fail "bot-autonomy Claude Code module not found at ${claude_module}"
    [ -f "$codex_bot_config" ] || fail "Codex bot managed config not found at ${codex_bot_config}"
    # Registry coverage, structural parity, and per-module fixture behavior
    # are scripts/test-bot-autonomy.sh's job (wired into `task verify`
    # unconditionally); this file only asserts the surrounding wiring.

    local bot_config dev_config shell_aliases gh_browser
    bot_config="${repo_root}/.devcontainer/devcontainer.json"
    dev_config="${repo_root}/.devcontainer/dev/devcontainer.json"
    shell_aliases="${repo_root}/.devcontainer/config/shell-aliases.sh"
    gh_browser="${repo_root}/.devcontainer/config/gh-browser.sh"
    [ -f "$bot_config" ] || fail "bot devcontainer.json not found at ${bot_config}"
    [ -f "$dev_config" ] || fail "dev devcontainer.json not found at ${dev_config}"
    [ -f "$shell_aliases" ] || fail "shell-aliases.sh not found at ${shell_aliases}"
    [ -x "$gh_browser" ] || fail "GitHub browser bridge is missing or not executable at ${gh_browser}"
    grep '^unset BROWSER$' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh no longer removes generic BROWSER from interactive shells"
    grep -E '^[[:space:]]*alias([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+pnpm-relock(=|[[:space:]]|$)' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh does not define pnpm-relock alias"
    ! grep -E '^[[:space:]]*alias([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+fresh(=|[[:space:]]|$)' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh still defines fresh alias, shadowing Fresh editor"
    ! grep -E '^[[:space:]]*alias([[:space:]]+-[a-zA-Z0-9]+)*[[:space:]]+(mc|nano|ttt)(=|[[:space:]]|$)' "$shell_aliases" >/dev/null ||
        fail "shell-aliases.sh defines alias shadowing mc, nano, or ttt"

    if command -v zsh >/dev/null 2>&1; then
        for shadowed in fresh mc nano ttt; do
            if zsh -c ". '$shell_aliases' 2>/dev/null && alias '$shadowed'" >/dev/null 2>&1; then
                fail "shell-aliases.sh defines alias shadowing ${shadowed} in zsh"
            fi
        done
    fi

    # `task` and the rest of the shared toolchain come from the pinned public
    # image, never a devcontainer Feature: the go-task Feature resolved
    # "latest" through the anonymous GitHub API from inside the build and
    # 403'd at random on shared runner IPs (harmon-init#427). Asserted here,
    # in unit mode, because this is the gated path — `task ci` runs it with no
    # container. The container-mode check below proves the binary actually
    # landed, but it needs a built image and so runs only from the manual
    # smoke tasks.
    local dockerfile cfg
    dockerfile="${repo_root}/.devcontainer/Dockerfile"
    [ -f "$dockerfile" ] || fail "devcontainer Dockerfile not found at ${dockerfile}"
    for cfg in "$bot_config" "$dev_config"; do
        if grep 'features/go-task' "$cfg" >/dev/null; then
            fail "${cfg} installs task via a devcontainer Feature — the pinned shared image ships it (harmon-init#427)"
        fi
    done
    assert_image_pin "$dockerfile" >/dev/null

    # Run from a non-repo temp dir so `git rev-parse --is-inside-work-tree`
    # inside init-env.sh is false and the rebuild `git pull` never fires.
    local work_dir env_file codex_fixture
    work_dir="$(mktemp -d)"
    cd "$work_dir"

    # The shared managed layer is the balanced human default. Bot post-create
    # must switch only that profile to the Docker-boundary autonomy preset.
    [ "$(toml_root_scalar model "$codex_config")" = "gpt-5.6-sol" ] ||
        fail "Codex devcontainer model is not gpt-5.6-sol"
    [ "$(toml_root_scalar model_reasoning_effort "$codex_config")" = "medium" ] ||
        fail "Codex devcontainer reasoning is not medium"
    [ "$(toml_root_scalar sandbox_mode "$codex_config")" = "workspace-write" ] ||
        fail "human Codex baseline does not enable workspace-write"
    [ "$(toml_root_scalar approval_policy "$codex_config")" = "on-request" ] ||
        fail "human Codex baseline does not use on-request approvals"
    if grep -E 'session-start-context|post-edit-format|enforce-conventional-commits' "$codex_config" >/dev/null; then
        fail "system-managed Codex hooks delegate into checkout-controlled tasks"
    fi
    # Codex and Claude Code bot policy now come from bot-autonomy modules,
    # installed and verified via bot-autonomy.sh apply/verify — never called
    # directly from post-create.sh. Fixture-level apply/verify coverage for
    # both modules (checksum install, drift detection) lives in
    # scripts/test-bot-autonomy.sh; this asserts the surrounding wiring only.
    codex_fixture="${work_dir}/codex-managed.toml"
    cp "$codex_config" "$codex_fixture"
    BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" apply >/dev/null
    [ "$(toml_root_scalar sandbox_mode "$codex_fixture")" = "danger-full-access" ] ||
        fail "bot-autonomy Codex module did not remove the nested sandbox"
    [ "$(toml_root_scalar approval_policy "$codex_fixture")" = "never" ] ||
        fail "bot-autonomy Codex module did not disable approval prompts"

    # The Agent-Deck conductor-setup block was extracted out of
    # post-create-common.sh into its own script, so bot post-create can run
    # it AFTER apply (a conductor-spawned `claude` must not run before the
    # bot's policy is written) without delaying dev's identical step.
    local conductor_script
    conductor_script="${repo_root}/.devcontainer/scripts/post-create-conductor.sh"
    [ -x "$conductor_script" ] || fail "post-create-conductor.sh not found at ${conductor_script}"
    # Match the actual invocation, not the phrase alone — a nearby comment in
    # post-create-common.sh legitimately still SAYS "agent-deck conductor
    # setup" (explaining why link-claude-json.sh must run early) without the
    # block itself having come back.
    if grep 'agent-deck conductor setup "\$REPO_NAME"' "${repo_root}/.devcontainer/scripts/post-create-common.sh" >/dev/null; then
        fail "the Agent-Deck conductor-setup block was not extracted out of post-create-common.sh"
    fi
    grep 'agent-deck conductor setup "\$REPO_NAME"' "$conductor_script" >/dev/null ||
        fail "post-create-conductor.sh does not contain the extracted conductor-setup block"

    # Each profile's step order matches the corrected ordering: shared setup
    # (with the conductor block already extracted out, checked above), then
    # ensure-antigravity-cli.sh, then the profile's own autonomy step
    # (bot-autonomy.sh apply for bot; apply-antigravity-settings.sh for dev),
    # then the conductor step LAST — never before the autonomy step.
    assert_step_order() {
        local file="$1" step_after_shared="$2"
        local order
        order="$(grep -Ev '^[[:space:]]*#' "$file" |
            grep -E 'post-create-common\.sh|ensure-antigravity-cli\.sh|post-create-conductor\.sh|bot-autonomy\.sh apply|apply-antigravity-settings\.sh')"
        case "$(printf '%s\n' "$order" | sed -n '1p')" in
        *"post-create-common.sh"*) ;;
        *) fail "${file} does not run post-create-common.sh first" ;;
        esac
        case "$(printf '%s\n' "$order" | sed -n '2p')" in
        *"ensure-antigravity-cli.sh"*) ;;
        *) fail "${file} does not run ensure-antigravity-cli.sh second" ;;
        esac
        case "$(printf '%s\n' "$order" | sed -n '3p')" in
        *"$step_after_shared"*) ;;
        *) fail "${file} does not run ${step_after_shared} third" ;;
        esac
        case "$(printf '%s\n' "$order" | tail -1)" in
        *"post-create-conductor.sh"*) ;;
        *) fail "${file} does not run post-create-conductor.sh last" ;;
        esac
    }
    assert_step_order "${repo_root}/.devcontainer/post-create.sh" "bot-autonomy.sh apply"
    assert_step_order "${repo_root}/.devcontainer/dev/post-create.sh" "apply-antigravity-settings.sh"
    # verify SHALL also run at the end of post-create (not only post-start),
    # so a divergence between what apply wrote and a harness's actual
    # effective state (e.g. an already-present workspace-level OpenCode
    # override) fails container creation rather than surfacing only later.
    case "$(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/post-create.sh" | grep -E 'bot-autonomy\.sh (apply|verify)' | tail -1)" in
    *"bot-autonomy.sh verify"*) ;;
    *) fail "bot post-create does not call bot-autonomy.sh verify after apply" ;;
    esac
    # Strip comments first: dev/post-create.sh's own explanatory comment names
    # bot-autonomy.sh to say it does NOT call it, which a bare grep would
    # misread as a real invocation.
    if grep 'bot-autonomy.sh' \
        < <(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/dev/post-create.sh") >/dev/null; then
        fail "human post-create calls bot-autonomy.sh (bot-only)"
    fi
    grep 'bot-autonomy.sh verify' "${repo_root}/.devcontainer/post-start.sh" >/dev/null ||
        fail "bot post-start does not call bot-autonomy.sh verify"
    # verify must run BEFORE post-start-common.sh (whose conductor-start block
    # must never launch against a drifted policy) and NODE_OPTIONS must be
    # unset before verify (so a Node-based harness CLI verify step is not
    # itself broken by an inherited VS Code debug value).
    #
    # The grep filter below deliberately sees only those three Node-relevant
    # steps, so this asserts their ORDER RELATIVE TO EACH OTHER, not that
    # nothing whatsoever precedes them. The gh-identity tripwire (10b) does
    # run first, by design — it is a bash script driving a Go binary, so the
    # unset does not apply to it, and running it ahead of the set -e verify
    # step is what makes it fire on every start.
    local post_start_order
    post_start_order="$(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/post-start.sh" |
        grep -E 'unset NODE_OPTIONS|bot-autonomy\.sh verify|post-start-common\.sh')"
    [ "$(printf '%s\n' "$post_start_order" | sed -n '1p')" = "unset NODE_OPTIONS" ] ||
        fail "bot post-start does not unset NODE_OPTIONS before the Node-dependent startup steps"
    case "$(printf '%s\n' "$post_start_order" | sed -n '2p')" in
    *"bot-autonomy.sh verify") ;;
    *) fail "bot post-start does not call bot-autonomy.sh verify immediately after unsetting NODE_OPTIONS" ;;
    esac
    case "$(printf '%s\n' "$post_start_order" | sed -n '3p')" in
    *"post-start-common.sh") ;;
    *) fail "bot post-start does not call post-start-common.sh after bot-autonomy.sh verify" ;;
    esac

    # Behavioral proof of that ordering, not just textual: run the REAL,
    # unmodified post-start.sh in an isolated scratch tree (its own
    # .devcontainer/scripts/post-start-common.sh shadowed by a sentinel-only
    # stand-in, so no real side effect — sudo chown, git config writes, the
    # Agent-Deck conductor-start block — ever fires). `set -euo pipefail`
    # is what actually enforces the ordering at runtime; grepping line order
    # alone cannot prove a verify failure really aborts the script before
    # post-start-common.sh's conductor-start block would ever run.
    local ps_work ps_sentinel ps_registry ps_module_dir
    ps_work="${work_dir}/post-start-behavioral"
    mkdir -p "${ps_work}/.devcontainer/scripts" "${ps_work}/.devcontainer/config/bot-autonomy"
    cp "${repo_root}/.devcontainer/post-start.sh" "${ps_work}/.devcontainer/post-start.sh"
    cp "${repo_root}/.devcontainer/scripts/bot-autonomy.sh" "${ps_work}/.devcontainer/scripts/bot-autonomy.sh"
    cp "${repo_root}/.devcontainer/config/bot-autonomy/unsupported.json" "${ps_work}/.devcontainer/config/bot-autonomy/"
    echo '{}' >"${ps_work}/.devcontainer/config/bot-autonomy/aliases.json"
    cat >"${ps_work}/.devcontainer/scripts/post-start-common.sh" <<'SENTINEL_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "SENTINEL: post-start-common.sh reached" >>"${SENTINEL_LOG:?SENTINEL_LOG not set}"
SENTINEL_SCRIPT
    chmod +x "${ps_work}/.devcontainer/post-start.sh" "${ps_work}/.devcontainer/scripts/bot-autonomy.sh" \
        "${ps_work}/.devcontainer/scripts/post-start-common.sh"
    # A registry resolving cleanly via the unsupported bucket alone (no real
    # harness executable required) so verify's SUCCESS path is exercised
    # without depending on claude/codex/agy/opencode being installed here.
    ps_registry="${ps_work}/registry.json"
    printf '{"harnesses": [{"slug": "qwen-code"}]}' >"$ps_registry"
    ps_module_dir="${ps_work}/.devcontainer/config/bot-autonomy"

    ps_sentinel="${ps_work}/sentinel-drifted.log"
    rm -f "$ps_sentinel"
    if (cd "$ps_work" && BOT_AUTONOMY_REGISTRY=/nonexistent-registry.json \
        SENTINEL_LOG="$ps_sentinel" bash .devcontainer/post-start.sh) >/dev/null 2>&1; then
        fail "post-start.sh exited 0 despite bot-autonomy.sh verify failing (drifted-policy fixture)"
    fi
    [ ! -f "$ps_sentinel" ] ||
        fail "post-start-common.sh's conductor-start block ran despite a drifted policy — bot-autonomy.sh verify did not abort post-start.sh first"

    ps_sentinel="${ps_work}/sentinel-clean.log"
    rm -f "$ps_sentinel"
    (cd "$ps_work" && BOT_AUTONOMY_REGISTRY="$ps_registry" BOT_AUTONOMY_CONFIG_DIR="$ps_module_dir" \
        SENTINEL_LOG="$ps_sentinel" bash .devcontainer/post-start.sh) >/dev/null 2>&1 ||
        fail "post-start.sh failed against a correctly-configured (verify-clean) fixture"
    [ -f "$ps_sentinel" ] ||
        fail "post-start-common.sh never ran even though bot-autonomy.sh verify passed"

    ps_sentinel="${ps_work}/sentinel-node-options.log"
    rm -f "$ps_sentinel"
    (cd "$ps_work" && NODE_OPTIONS="--require /nonexistent/bootloader.js" \
        BOT_AUTONOMY_REGISTRY="$ps_registry" BOT_AUTONOMY_CONFIG_DIR="$ps_module_dir" \
        SENTINEL_LOG="$ps_sentinel" bash .devcontainer/post-start.sh) >/dev/null 2>&1 ||
        fail "post-start.sh failed with an inherited NODE_OPTIONS value that would break a Node-based harness CLI, against an otherwise correctly-configured fixture"
    [ -f "$ps_sentinel" ] ||
        fail "post-start-common.sh never ran when only NODE_OPTIONS (correctly unset before verify) was hostile"

    # `docker exec` has no workspace-folder-aware default cwd — the
    # Dockerfile sets no WORKDIR, so a bare exec lands wherever the base
    # image defaults to, not the mounted workspace folder — so this
    # script's own container-mode exec of bot-autonomy.sh verify (a
    # relative path) must pin its working directory explicitly. Guard
    # against that regressing silently: the exec line and the one after it
    # must together carry either `-w` on `docker exec` or an absolute path
    # to the script.
    local exec_pair
    exec_pair="$(grep -A1 -F 'bot_autonomy_out="$(docker exec' "${repo_root}/scripts/devcontainer-assert.sh")"
    [ -n "$exec_pair" ] ||
        fail "devcontainer-assert.sh no longer execs bot-autonomy.sh verify the expected way in container mode"
    case "$exec_pair" in
    *' -w '*) ;;
    *'bash /'*) ;;
    *) fail "devcontainer-assert.sh's container-mode bot-autonomy.sh verify exec pins no working directory (-w on docker exec) and uses no absolute script path — a relative path resolves against the container's default cwd, not the workspace folder" ;;
    esac

    # has_var <var> <env-file>  → true if the file sets VAR= on its own line.
    has_var() {
        grep -q "^${1}=" "$2"
    }

    # These allow-list cases run init-env.sh with most vars unset, so its
    # missing-var warning (asserted in 6 below) fires on every one. They assert
    # on the ENV-FILE, not stderr, so the warning is discarded: a green run must
    # not print "warning:" blocks a reader has to triage. `set -e` still catches
    # a nonzero exit, and 6 is where stderr is captured and checked.
    local bot_allow=(GH_TOKEN FOREMAN_AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)
    local dev_allow=(TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)

    # 1. Bot strips TS_AUTHKEY from the host env; keeps allowed vars —
    #    including the read-only agent token foreman requires for dispatch.
    env_file="${work_dir}/env-bot-strip"
    : >"$env_file"
    TS_AUTHKEY=fake GH_TOKEN=fake FOREMAN_AGENT_GH_TOKEN=fake bash "$init_env" "$env_file" "${bot_allow[@]}" 2>/dev/null
    has_var GH_TOKEN "$env_file" || fail "bot profile dropped allowed GH_TOKEN"
    has_var FOREMAN_AGENT_GH_TOKEN "$env_file" || fail "bot profile dropped allowed FOREMAN_AGENT_GH_TOKEN (foreman dispatch needs it)"
    if has_var TS_AUTHKEY "$env_file"; then
        fail "bot profile leaked TS_AUTHKEY into the env-file"
    fi

    # 2. Bot evicts a STALE TS_AUTHKEY already in the file when TS_AUTHKEY is
    #    unset in the host env.
    env_file="${work_dir}/env-bot-evict"
    printf 'TS_AUTHKEY=stale\nGH_TOKEN=old\n' >"$env_file"
    (unset TS_AUTHKEY && GH_TOKEN=new bash "$init_env" "$env_file" "${bot_allow[@]}") 2>/dev/null
    if has_var TS_AUTHKEY "$env_file"; then
        fail "bot profile failed to evict a stale TS_AUTHKEY"
    fi

    # 3. Dev keeps TS_AUTHKEY when the dev allow-list includes it — and refuses
    #    GH_TOKEN even though the host env sets it. The human profile commits as
    #    the operator, so it must authenticate as the operator (via `gh auth
    #    login`) rather than carry the bot's PAT.
    env_file="${work_dir}/env-dev-keep"
    : >"$env_file"
    TS_AUTHKEY=keep GH_TOKEN=fake FOREMAN_AGENT_GH_TOKEN=fake bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    has_var TS_AUTHKEY "$env_file" || fail "dev profile dropped allowed TS_AUTHKEY"
    if has_var GH_TOKEN "$env_file"; then
        fail "dev profile injected GH_TOKEN — a human profile must carry no bot credential"
    fi
    if has_var FOREMAN_AGENT_GH_TOKEN "$env_file"; then
        fail "dev profile injected FOREMAN_AGENT_GH_TOKEN — agent tokens stay in the bot profile"
    fi

    # 3b. Dev evicts a STALE GH_TOKEN already in the file when GH_TOKEN is unset
    #     in the host env. This is what retires the value an earlier rebuild wrote
    #     back when the dev allow-list still included it — dropping it from the
    #     allow-list alone would leave the old token sitting in the env-file.
    env_file="${work_dir}/env-dev-evict"
    printf 'GH_TOKEN=stale\nTS_AUTHKEY=old\n' >"$env_file"
    (unset GH_TOKEN && TS_AUTHKEY=new bash "$init_env" "$env_file" "${dev_allow[@]}") 2>/dev/null
    if has_var GH_TOKEN "$env_file"; then
        fail "dev profile failed to evict a stale GH_TOKEN"
    fi

    # 4. ANTHROPIC_API_KEY is ALWAYS stripped, even if passed in the allow-list
    #    (it silently overrides CLAUDE_CODE_OAUTH_TOKEN).
    env_file="${work_dir}/env-anthropic"
    : >"$env_file"
    ANTHROPIC_API_KEY=secret GH_TOKEN=fake bash "$init_env" "$env_file" GH_TOKEN ANTHROPIC_API_KEY 2>/dev/null
    if has_var ANTHROPIC_API_KEY "$env_file"; then
        fail "ANTHROPIC_API_KEY was allowed into the env-file"
    fi

    # 5. An unknown var passed in the allow-list cannot be smuggled in.
    env_file="${work_dir}/env-smuggle"
    : >"$env_file"
    HARMON_SMUGGLE=evil bash "$init_env" "$env_file" GH_TOKEN HARMON_SMUGGLE 2>/dev/null
    if has_var HARMON_SMUGGLE "$env_file"; then
        fail "an unknown var was smuggled into the env-file via the allow-list"
    fi

    # 6. A var allow-listed for this profile but absent from BOTH the host env
    #    and the env-file must WARN on stderr. The silence this replaces is how
    #    a missing TS_AUTHKEY went unnoticed for hours in a Coder workspace
    #    (harmon-init#639): the container came up fine and only the Tailscale-
    #    dependent step failed, far from the cause.
    local warn_out warn_rc
    env_file="${work_dir}/env-warn-dev"
    : >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] ||
        fail "init-env.sh exited ${warn_rc} on a missing allow-listed var — it runs as initializeCommand on the HOST, so a nonzero exit aborts the container build"
    case "$warn_out" in
    *TS_AUTHKEY*) ;;
    *) fail "dev profile did not warn about a TS_AUTHKEY missing from both the host env and the env-file" ;;
    esac

    #    The bot profile must stay SILENT about TS_AUTHKEY even when it is
    #    missing everywhere: it is off that allow-list by design (no tailnet
    #    path from a bypassPermissions container), so naming it would advertise
    #    a credential the profile must never hold — and train the reader to
    #    expect one. Warning from BASE_MANAGED_VARS/EVICT_VARS instead of the
    #    post-filter allow-list is the accident this pins down.
    env_file="${work_dir}/env-warn-bot"
    : >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY GH_TOKEN FOREMAN_AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${bot_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} warning under the bot profile"
    case "$warn_out" in
    *TS_AUTHKEY*) fail "bot profile warned about a missing TS_AUTHKEY — it is off that allow-list by design and must never be advertised there" ;;
    esac
    case "$warn_out" in
    *GH_TOKEN*) ;;
    *) fail "bot profile did not warn about a GH_TOKEN missing from both the host env and the env-file" ;;
    esac

    #    A value already in the env-file is the out-of-band case init-env.sh
    #    exists to preserve (1Password-managed, never exported to the host
    #    shell): warn about nothing, and leave the value intact.
    env_file="${work_dir}/env-warn-quiet"
    printf 'TS_AUTHKEY=fromop\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} with every allow-listed var already in the env-file"
    [ -z "$warn_out" ] || fail "init-env.sh warned about vars already present in the env-file: ${warn_out}"
    grep '^TS_AUTHKEY=fromop$' "$env_file" >/dev/null ||
        fail "init-env.sh did not preserve the out-of-band TS_AUTHKEY value in the env-file"

    #    A bare "VAR=" env-file line leaves the container with no usable value,
    #    so the presence test requires at least one character after the `=`.
    env_file="${work_dir}/env-warn-blank"
    printf 'TS_AUTHKEY=\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    warn_rc=0
    warn_out="$(unset TS_AUTHKEY CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY &&
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} on a blank env-file entry"
    case "$warn_out" in
    *TS_AUTHKEY*) ;;
    *) fail "init-env.sh treated a blank 'TS_AUTHKEY=' env-file line as a usable value" ;;
    esac

    #    The warning names vars, never VALUES — it lands in build logs. Asserted
    #    with a var exported EMPTY (which "${!var:-}" treats as unset, so it
    #    warns) alongside two carrying sentinel secrets that must not appear.
    env_file="${work_dir}/env-warn-novalue"
    : >"$env_file"
    warn_rc=0
    warn_out="$(TS_AUTHKEY= CLAUDE_CODE_OAUTH_TOKEN=harmon-sentinel-one \
        AGENT_DECK_TELEGRAM_KEY=harmon-sentinel-two \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>&1 >/dev/null)" || warn_rc=$?
    [ "$warn_rc" -eq 0 ] || fail "init-env.sh exited ${warn_rc} on an allow-listed var exported empty"
    case "$warn_out" in
    *TS_AUTHKEY*) ;;
    *) fail "init-env.sh did not warn about an allow-listed var exported empty — no usable value reaches the container" ;;
    esac
    case "$warn_out" in
    *harmon-sentinel*) fail "init-env.sh printed a secret VALUE in its warning output" ;;
    esac

    # 6b. A run that changes nothing must not TOUCH the env-file. init-env.sh is
    #     an initializeCommand, so it fires on every VS Code connect, not just
    #     rebuilds — and an unconditional rewrite churns the file's mtime, which
    #     is enough for Coder's devcontainer integration to read the config as
    #     dirty and recreate the container. mtime, not just content, is the
    #     assertion: a byte-identical rewrite would pass a content-only check
    #     and still cause the recreation loop.
    local mtime_before mtime_after content_before
    env_file="${work_dir}/env-idempotent"
    printf 'TS_AUTHKEY=stable\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    # First run settles the file (it may legitimately rewrite here).
    TS_AUTHKEY=stable CLAUDE_CODE_OAUTH_TOKEN=tok AGENT_DECK_TELEGRAM_KEY=key \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    content_before="$(cat "$env_file")"
    mtime_before="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    sleep 1
    # Second run with an identical host env: nothing to inject, nothing to evict.
    TS_AUTHKEY=stable CLAUDE_CODE_OAUTH_TOKEN=tok AGENT_DECK_TELEGRAM_KEY=key \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    mtime_after="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    [ "$mtime_before" = "$mtime_after" ] ||
        fail "init-env.sh rewrote an unchanged env-file (mtime ${mtime_before} -> ${mtime_after}) — the mtime churn makes Coder recreate the container on every connect"
    [ "$(cat "$env_file")" = "$content_before" ] ||
        fail "init-env.sh changed the contents of an already-settled env-file"

    #     A run that DOES have work to do must still write. Guards the obvious
    #     wrong fix for the above: skipping the write unconditionally.
    env_file="${work_dir}/env-idempotent-change"
    printf 'TS_AUTHKEY=old\n' >"$env_file"
    TS_AUTHKEY=new bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    grep '^TS_AUTHKEY=new$' "$env_file" >/dev/null ||
        fail "init-env.sh skipped a write it needed to make — the changed TS_AUTHKEY never reached the env-file"

    # 6c. Permissions are enforced even when the CONTENT needs no write. A
    #     pre-existing env-file (copied from devcontainer.env.example under a
    #     permissive umask) holds secrets at 0644, and a skip-on-identical run
    #     must still tighten it — while leaving mtime alone (chmod never
    #     touches mtime, so both assertions can hold at once).
    env_file="${work_dir}/env-loose-perms"
    printf 'TS_AUTHKEY=stable\nCLAUDE_CODE_OAUTH_TOKEN=tok\nAGENT_DECK_TELEGRAM_KEY=key\n' >"$env_file"
    chmod 644 "$env_file"
    mtime_before="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    sleep 1
    TS_AUTHKEY=stable CLAUDE_CODE_OAUTH_TOKEN=tok AGENT_DECK_TELEGRAM_KEY=key \
        bash "$init_env" "$env_file" "${dev_allow[@]}" 2>/dev/null
    mode_after="$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file")"
    [ "$mode_after" = "600" ] ||
        fail "init-env.sh left a secret env-file at mode ${mode_after} — 0600 must be enforced on every run, not only on rewrites"
    mtime_after="$(stat -c %Y "$env_file" 2>/dev/null || stat -f %m "$env_file")"
    [ "$mtime_before" = "$mtime_after" ] ||
        fail "init-env.sh churned mtime while fixing permissions on an unchanged env-file"

    # 7. tailscale-connect.sh no-ops (exit 0, prints its "unavailable" message)
    #    when `tailscale` is not on PATH. Invoke with an absolute bash path so
    #    the unreachable PATH doesn't also hide the interpreter.
    local ts_out
    if ! ts_out="$(PATH="/nonexistent" "$bash_bin" "$ts_connect" 2>&1)"; then
        fail "tailscale-connect.sh exited nonzero when tailscale is absent"
    fi
    case "$ts_out" in
    *"unavailable"*) ;;
    *) fail "tailscale-connect.sh did not report tailscale unavailable: ${ts_out}" ;;
    esac

    # 8. Antigravity runs without permission prompts inside the container,
    #    which is the isolation boundary. The apply helper must enforce those
    #    keys while preserving unrelated settings in the persistent volume.
    local agy_defaults agy_apply agy_ensure agy_home agy_settings agy_backup agy_workspace agy_workspace_moved
    agy_defaults="${repo_root}/.devcontainer/config/antigravity-settings.json"
    agy_dev_defaults="${repo_root}/.devcontainer/config/antigravity-settings-dev.json"
    agy_apply="${repo_root}/.devcontainer/config/apply-antigravity-settings.sh"
    agy_ensure="${repo_root}/.devcontainer/config/ensure-antigravity-cli.sh"
    [ -f "$agy_defaults" ] || fail "Antigravity defaults not found at ${agy_defaults}"
    [ -f "$agy_apply" ] || fail "Antigravity settings helper not found at ${agy_apply}"
    [ -f "$agy_ensure" ] || fail "Antigravity compatibility installer not found at ${agy_ensure}"

    # ensure-antigravity-cli.sh now owns ~/.local/bin/agy-real (never agy
    # directly) and is gated entirely on the rendered
    # HARMON_BOT_AUTONOMY_ANTIGRAVITY marker — no unconditional download.
    local agy_roll_home agy_system_binary
    agy_roll_home="${work_dir}/agy-roll-home"
    agy_system_binary="${work_dir}/agy-system-binary"
    mkdir -p "${agy_roll_home}/.local/bin"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "1.1.11"' >"$agy_system_binary"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "1.0.0"' >"${agy_roll_home}/.local/bin/agy-real"
    chmod 0755 "$agy_system_binary" "${agy_roll_home}/.local/bin/agy-real"

    # Disabled marker (including entirely absent): no download. This models a
    # rolling update from a pre-ownership-metadata release: neither the natural
    # agy -> agy-real shape nor the markerless executable proves ownership, so
    # both paths must be preserved byte-for-byte.
    local agy_disabled_home agy_disabled_real_before
    agy_disabled_home="${work_dir}/agy-disabled-home"
    agy_disabled_real_before="${work_dir}/agy-disabled-real-before"
    mkdir -p "${agy_disabled_home}/.local/bin"
    printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "1.0.0"' >"${agy_disabled_home}/.local/bin/agy-real"
    chmod 0755 "${agy_disabled_home}/.local/bin/agy-real"
    cp "${agy_disabled_home}/.local/bin/agy-real" "$agy_disabled_real_before"
    ln -s "${agy_disabled_home}/.local/bin/agy-real" "${agy_disabled_home}/.local/bin/agy"
    HOME="$agy_disabled_home" bash "$agy_ensure" >/dev/null
    cmp -s "$agy_disabled_real_before" "${agy_disabled_home}/.local/bin/agy-real" ||
        fail "disabled cleanup changed a markerless pre-metadata agy-real"
    [ -L "${agy_disabled_home}/.local/bin/agy" ] &&
        [ "$(readlink "${agy_disabled_home}/.local/bin/agy")" = "${agy_disabled_home}/.local/bin/agy-real" ] ||
        fail "disabled cleanup changed a markerless pre-metadata agy symlink"
    [ ! -e "${agy_disabled_home}/.local/bin/.agy-real.harmon-init-owned" ] ||
        fail "disabled cleanup claimed a markerless pre-metadata agy-real"
    [ ! -e "${agy_disabled_home}/.local/bin/.agy.harmon-init-owned" ] ||
        fail "disabled cleanup claimed a markerless pre-metadata agy launcher"

    # Enabled marker, current shared-image binary already sufficient, no
    # pre-existing local shadow: no shadow copy is created, and agy stays
    # absent rather than becoming a dangling symlink.
    local agy_image_home
    agy_image_home="${work_dir}/agy-image-home"
    mkdir -p "$agy_image_home"
    HOME="$agy_image_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
        HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy_system_binary" bash "$agy_ensure" >/dev/null
    [ ! -e "${agy_image_home}/.local/bin/agy-real" ] ||
        fail "current shared-image Antigravity binary created a persistent shadow copy"
    [ ! -e "${agy_image_home}/.local/bin/agy" ] && [ ! -L "${agy_image_home}/.local/bin/agy" ] ||
        fail "agy is present (or a dangling symlink) with no agy-real to back it"

    # Enabled marker, a stale local shadow already exists: refreshed to the
    # pinned version, and agy (re)pointed at it as a plain symlink.
    HOME="$agy_roll_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
        HARMON_ANTIGRAVITY_SYSTEM_BINARY="$agy_system_binary" bash "$agy_ensure" >/dev/null
    [ "$("${agy_roll_home}/.local/bin/agy-real" --version)" = "1.1.11" ] ||
        fail "stale user-local Antigravity binary still shadows the shared-image pin"
    [ "$(readlink -f "${agy_roll_home}/.local/bin/agy")" = "$(readlink -f "${agy_roll_home}/.local/bin/agy-real")" ] ||
        fail "ensure-antigravity-cli.sh did not point agy at agy-real as a plain symlink"
    [ -f "${agy_roll_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
        [ -f "${agy_roll_home}/.local/bin/.agy.harmon-init-owned" ] ||
        fail "ensure-antigravity-cli.sh did not publish independent path ownership proofs"

    # Toggling back to disabled fully removes both — not merely skips the
    # download — reaching absence rather than a dangling link.
    HOME="$agy_roll_home" bash "$agy_ensure" >/dev/null
    [ ! -e "${agy_roll_home}/.local/bin/agy-real" ] &&
        [ ! -e "${agy_roll_home}/.local/bin/agy" ] &&
        [ ! -e "${agy_roll_home}/.local/bin/.agy-real.harmon-init-owned" ] &&
        [ ! -e "${agy_roll_home}/.local/bin/.agy.harmon-init-owned" ] ||
        fail "toggling the marker off did not fully remove agy-real/agy"

    agy_home="${work_dir}/agy-home"
    agy_settings="${agy_home}/.gemini/antigravity-cli/settings.json"
    agy_backup="${agy_settings}.harmon-init-autonomy-backup"
    agy_workspace="${work_dir}/trusted-workspace"
    agy_workspace_moved="${work_dir}/trusted-workspace-renamed"
    mkdir -p "$(dirname "$agy_settings")"
    printf '%s\n' '{"model":"Gemini test","toolPermission":"request-review","permissions":{"allow":["command(task)"],"bash":"deny"}}' >"$agy_settings"
    HOME="$agy_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "Gemini test" and
        .permissions == {} and
        .toolPermission == "always-proceed" and
        .artifactReviewPolicy == "always-proceed" and
        .allowNonWorkspaceAccess == true and
        .enableTerminalSandbox == false and
        .statusLine.type == "command" and
        .statusLine.command == "/etc/claude-code/statusline.sh" and
        .statusLine.enabled == true and
        .statusLine.stack_with_default == true and
        .showFeedbackSurvey == false and
        .trustedWorkspaces == [$workspace]
    ' --arg workspace "$agy_workspace" "$agy_settings" >/dev/null ||
        fail "Antigravity dev container policy was not merged correctly"
    jq -e '
        .schemaVersion == 6 and
        .present == ["toolPermission","permissions"] and
        .values.toolPermission == "request-review" and
        .values.permissions == {"allow":["command(task)"],"bash":"deny"} and
        .introducedWorkspaces == [$workspace] and
        .trustedWorkspacesKeyWasPresent == false
    ' --arg workspace "$agy_workspace" "$agy_backup" >/dev/null ||
        fail "Antigravity policy rollback state was not recorded correctly"

    local agy_fresh_home agy_fresh_settings
    agy_fresh_home="${work_dir}/agy-fresh-home"
    agy_fresh_settings="${agy_fresh_home}/.gemini/antigravity-cli/settings.json"
    HOME="$agy_fresh_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "Gemini 3.7 Flash (High)" and
        .toolPermission == "always-proceed"
    ' "$agy_fresh_settings" >/dev/null ||
        fail "fresh Antigravity settings did not seed default model Gemini 3.7 Flash (High)"

    local agy_mig_home agy_mig_settings agy_mig_backup
    agy_mig_home="${work_dir}/agy-mig-home"
    agy_mig_settings="${agy_mig_home}/.gemini/antigravity-cli/settings.json"
    agy_mig_backup="${agy_mig_home}/.gemini/antigravity-cli/settings.json.harmon-init-autonomy-backup"
    mkdir -p "${agy_mig_home}/.gemini/antigravity-cli"
    printf '%s\n' '{"schemaVersion":3,"present":["toolPermission"],"values":{"toolPermission":"request-review"},"introducedWorkspaces":["/tmp/old"],"trustedWorkspacesKeyWasPresent":false}' >"$agy_mig_backup"
    printf '%s\n' '{"statusLine":{"type":"command","command":"/custom/statusline.sh"}}' >"$agy_mig_settings"
    HOME="$agy_mig_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .schemaVersion == 6 and
        (.present | index("statusLine") != null) and
        .values.statusLine.command == "/custom/statusline.sh"
    ' "$agy_mig_backup" >/dev/null ||
        fail "legacy schemaVersion 3 backup was not migrated to schemaVersion 6 with custom statusLine captured"

    # Test that restore also handles legacy schemaVersion 3 rollback state and preserves user statusLine
    printf '%s\n' '{"schemaVersion":3,"present":["toolPermission"],"values":{"toolPermission":"request-review"},"introducedWorkspaces":["/tmp/old"],"trustedWorkspacesKeyWasPresent":false}' >"$agy_mig_backup"
    printf '%s\n' '{"toolPermission":"always-proceed","artifactReviewPolicy":"always-proceed","allowNonWorkspaceAccess":true,"enableTerminalSandbox":false,"statusLine":{"type":"command","command":"/custom/statusline.sh"},"trustedWorkspaces":["/tmp/old"]}' >"$agy_mig_settings"
    HOME="$agy_mig_home" bash "$agy_apply" restore >/dev/null
    jq -e '
        .toolPermission == "request-review" and
        has("artifactReviewPolicy") == false and
        has("allowNonWorkspaceAccess") == false and
        has("enableTerminalSandbox") == false and
        .statusLine.command == "/custom/statusline.sh" and
        has("trustedWorkspaces") == false
    ' "$agy_mig_settings" >/dev/null ||
        fail "Antigravity policy rollback did not handle legacy schemaVersion 3 backup on restore while preserving statusLine"

    HOME="$agy_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace_moved" >/dev/null
    jq -e '.trustedWorkspaces == [$first, $second]' \
        --arg first "$agy_workspace" --arg second "$agy_workspace_moved" \
        "$agy_settings" >/dev/null ||
        fail "Antigravity did not trust the repository after its workspace path changed"
    jq -e '.introducedWorkspaces == [$first, $second]' \
        --arg first "$agy_workspace" --arg second "$agy_workspace_moved" \
        "$agy_backup" >/dev/null ||
        fail "Antigravity rollback state did not track every introduced workspace"

    jq '.model = "changed after opt-in"' "$agy_settings" >"${agy_settings}.new"
    mv "${agy_settings}.new" "$agy_settings"
    HOME="$agy_home" bash "$agy_apply" restore >/dev/null
    jq -e '
        .model == "changed after opt-in" and
        .toolPermission == "request-review" and
        has("artifactReviewPolicy") == false and
        has("allowNonWorkspaceAccess") == false and
        has("enableTerminalSandbox") == false and
        has("statusLine") == false and
        has("showFeedbackSurvey") == false and
        has("trustedWorkspaces") == false
    ' "$agy_settings" >/dev/null ||
        fail "Antigravity policy rollback did not restore only the managed keys"
    [ ! -e "$agy_backup" ] ||
        fail "Antigravity policy rollback state remains after a successful restore"

    local agy_before
    printf '%s\n' '{"model":"first"}' '{"model":"second"}' >"$agy_settings"
    agy_before="${work_dir}/agy-settings-before"
    cp "$agy_settings" "$agy_before"
    HOME="$agy_home" bash "$agy_apply" apply "$agy_defaults" "$agy_workspace" >/dev/null 2>&1
    cmp -s "$agy_settings" "$agy_before" ||
        fail "invalid Antigravity settings were overwritten"

    # Antigravity settings/CLI management is no longer conditionally CALLED
    # from post-create.sh based on the Copier answer — ensure-antigravity-
    # cli.sh and bot-autonomy.sh apply (which the Codex/Claude checks above
    # already require) always run; their own internal
    # HARMON_BOT_AUTONOMY_ANTIGRAVITY marker check decides what happens.
    # apply-antigravity-settings.sh itself is called directly only by
    # dev/post-create.sh (no bot-autonomy module exists for the dev profile)
    # and, internally, by the bot-autonomy antigravity module — never by bot
    # post-create.sh.
    grep 'ensure-antigravity-cli.sh' "${repo_root}/.devcontainer/post-create.sh" >/dev/null ||
        fail "bot post-create does not run ensure-antigravity-cli.sh"
    if grep 'apply-antigravity-settings.sh' "${repo_root}/.devcontainer/post-create.sh" >/dev/null; then
        fail "bot post-create calls apply-antigravity-settings.sh directly — that belongs to the bot-autonomy antigravity module now"
    fi
    grep '"HARMON_BOT_AUTONOMY_ANTIGRAVITY"' "${repo_root}/.devcontainer/devcontainer.json" >/dev/null ||
        fail "bot devcontainer.json does not set the HARMON_BOT_AUTONOMY_ANTIGRAVITY marker"
    grep '"HARMON_BOT_AUTONOMY_ANTIGRAVITY"' "${repo_root}/.devcontainer/dev/devcontainer.json" >/dev/null ||
        fail "dev devcontainer.json does not set the HARMON_BOT_AUTONOMY_ANTIGRAVITY marker"
    grep '"AGY_CLI_DISABLE_AUTO_UPDATE": *"true"' "${repo_root}/.devcontainer/devcontainer.json" >/dev/null ||
        fail "bot profile permits the compatibility Antigravity binary to auto-update"
    grep 'HARMON_BOT_AUTONOMY_ANTIGRAVITY' "${repo_root}/.devcontainer/dev/post-create.sh" >/dev/null ||
        fail "dev post-create does not branch on the HARMON_BOT_AUTONOMY_ANTIGRAVITY marker"
    grep 'apply-antigravity-settings.sh restore' "${repo_root}/.devcontainer/dev/post-create.sh" >/dev/null ||
        fail "dev post-create has no restore path for a disabled Antigravity option"
    # ── Balanced dev-profile policy (antigravity-settings-dev.json) ──
    # The human profile auto-accepts edits and an allowlist of common commands
    # but still gates unlisted ones — never the bot's blanket always-proceed.
    local agy_dev_home agy_dev_settings agy_dev_backup
    agy_dev_home="${work_dir}/agy-dev-home"
    agy_dev_settings="${agy_dev_home}/.gemini/antigravity-cli/settings.json"
    agy_dev_backup="${agy_dev_settings}.harmon-init-autonomy-backup"
    mkdir -p "$(dirname "$agy_dev_settings")"
    printf '%s\n' '{"model":"keep"}' >"$agy_dev_settings"
    HOME="$agy_dev_home" bash "$agy_apply" apply "$agy_dev_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "keep" and
        .toolPermission == "request-review" and
        .artifactReviewPolicy == "always-proceed" and
        (.permissions.allow | index("command(task)")) != null and
        (.permissions.deny | index("command(rm -rf /)")) != null and
        (.trustedWorkspaces | index($workspace)) != null
    ' --arg workspace "$agy_workspace" "$agy_dev_settings" >/dev/null ||
        fail "balanced Antigravity dev policy was not merged correctly"
    jq -e '.schemaVersion == 6' "$agy_dev_backup" >/dev/null ||
        fail "balanced Antigravity dev policy did not record a schemaVersion 6 rollback"

    local agy_dev_fresh_home agy_dev_fresh_settings
    agy_dev_fresh_home="${work_dir}/agy-dev-fresh-home"
    agy_dev_fresh_settings="${agy_dev_fresh_home}/.gemini/antigravity-cli/settings.json"
    HOME="$agy_dev_fresh_home" bash "$agy_apply" apply "$agy_dev_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .model == "Gemini 3.7 Flash (High)" and
        .toolPermission == "request-review"
    ' "$agy_dev_fresh_settings" >/dev/null ||
        fail "fresh balanced Antigravity dev settings did not seed default model Gemini 3.7 Flash (High)"

    # ── schemaVersion 5 → 6 migration must not discard user permissions ──
    # A pre-permissions (v4) backup never owned `permissions`; migrating and
    # later restoring must leave the user's own permissions block intact.
    local agy_v4_home agy_v4_settings agy_v4_backup
    agy_v4_home="${work_dir}/agy-v4-home"
    agy_v4_settings="${agy_v4_home}/.gemini/antigravity-cli/settings.json"
    agy_v4_backup="${agy_v4_settings}.harmon-init-autonomy-backup"
    mkdir -p "$(dirname "$agy_v4_settings")"
    printf '%s\n' '{"schemaVersion":4,"present":["toolPermission"],"values":{"toolPermission":"request-review"},"introducedWorkspaces":[],"trustedWorkspacesKeyWasPresent":false}' >"$agy_v4_backup"
    printf '%s\n' '{"toolPermission":"always-proceed","permissions":{"allow":["command(mine)"]}}' >"$agy_v4_settings"
    HOME="$agy_v4_home" bash "$agy_apply" apply "$agy_dev_defaults" "$agy_workspace" >/dev/null
    jq -e '
        .schemaVersion == 6 and
        (.present | index("permissions")) != null and
        .values.permissions == {"allow":["command(mine)"]}
    ' "$agy_v4_backup" >/dev/null ||
        fail "schemaVersion 5 backup did not migrate to 6 while capturing the user permissions block"
    HOME="$agy_v4_home" bash "$agy_apply" restore >/dev/null
    jq -e '.permissions == {"allow":["command(mine)"]} and .toolPermission == "request-review"' \
        "$agy_v4_settings" >/dev/null ||
        fail "restore did not return the user permissions block after a 5 -> 6 migration"

    # The human dev profile may apply its own BALANCED policy
    # (antigravity-settings-dev.json); it must never apply the bot's blanket
    # always-proceed policy (antigravity-settings.json). Strip comment lines
    # first so an explanatory comment naming the bot file is not a false match;
    # the regex then matches the bot defaults filename but not the "-dev.json".
    if grep -E 'antigravity-settings\.json' < <(grep -Ev '^[[:space:]]*#' "${repo_root}/.devcontainer/dev/post-create.sh") >/dev/null; then
        fail "human dev profile applies the bot-only always-proceed Antigravity policy"
    fi

    # 9. The GitHub CLI browser bridge must use the VS Code host opener when it
    #    works, and print the exact URL when that command is absent or fails.
    #    Remote VS Code's `code --open-url` is a false friend: it can ignore the
    #    option and exit 0, so prefer its bundled browser helper and capability-
    #    check any desktop CLI fallback.
    #    Generic discovery is intentionally forbidden: terminal browsers are
    #    installed in the image and would trap the OAuth flow in-container.
    local browser_bin browser_helpers browser_log browser_sentinel browser_out browser_url
    browser_bin="${work_dir}/browser-bin"
    browser_helpers="${work_dir}/helpers"
    browser_log="${work_dir}/browser-args"
    browser_sentinel="${work_dir}/terminal-browser-ran"
    browser_url='https://github.com/login/device?user_code=ABCD-EFGH&source=gh'
    mkdir -p "$browser_bin" "$browser_helpers"
    ln -s "$bash_bin" "${browser_bin}/bash"
    for browser_dependency in dirname grep readlink; do
        ln -s "$(command -v "$browser_dependency")" "${browser_bin}/${browser_dependency}"
    done
    printf '%s\n' '#!/bin/sh' \
        'if [ "${1:-}" = "--help" ]; then' \
        '    [ "${GH_BROWSER_TEST_OPEN_URL_SUPPORT:-0}" = "1" ] && echo "  --open-url"' \
        '    exit 0' \
        'fi' \
        'printf "%s\\n" "$@" >"$GH_BROWSER_TEST_LOG"' \
        'exit "${GH_BROWSER_TEST_CODE_RC:-0}"' >"${browser_bin}/code"
    chmod 0755 "${browser_bin}/code"
    printf '%s\n' '#!/bin/sh' \
        'printf "%s\\n" "$@" >"$GH_BROWSER_TEST_LOG"' \
        'if [ "${GH_BROWSER_TEST_HELPER_ERROR:-0}" = "1" ]; then' \
        '    echo "host handoff diagnostic with unstable wording" >&2' \
        'fi' \
        'exit "${GH_BROWSER_TEST_HELPER_RC:-0}"' >"${browser_helpers}/browser.sh"
    chmod 0755 "${browser_helpers}/browser.sh"
    for terminal_browser in w3m lynx sensible-browser xdg-open; do
        printf '%s\n' '#!/bin/sh' \
            'printf "%s\\n" "$0" >"$GH_BROWSER_TEST_SENTINEL"' \
            'exit 99' >"${browser_bin}/${terminal_browser}"
        chmod 0755 "${browser_bin}/${terminal_browser}"
    done

    GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url"
    [ "$(cat "$browser_log")" = "$browser_url" ] ||
        fail "GitHub browser bridge did not pass the exact URL to the remote helper"
    [ ! -e "$browser_sentinel" ] ||
        fail "GitHub browser bridge invoked a terminal browser after the remote helper succeeded"

    browser_out="$(GH_BROWSER_TEST_HELPER_ERROR=1 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge trusted unexpected output from the remote helper: ${browser_out}" ;;
    esac

    browser_out="$(GH_BROWSER_TEST_HELPER_RC=1 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge did not print the URL after the remote helper failed: ${browser_out}" ;;
    esac
    [ ! -e "$browser_sentinel" ] ||
        fail "GitHub browser bridge invoked a terminal browser after the remote helper failed"

    rm "${browser_helpers}/browser.sh"
    GH_BROWSER_TEST_OPEN_URL_SUPPORT=1 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url"
    [ "$(sed -n '1p' "$browser_log")" = "--open-url" ] &&
        [ "$(sed -n '2p' "$browser_log")" = "$browser_url" ] &&
        [ "$(wc -l <"$browser_log" | tr -d ' ')" = "2" ] ||
        fail "GitHub browser bridge did not pass the exact URL to a supported code --open-url"

    browser_out="$(GH_BROWSER_TEST_OPEN_URL_SUPPORT=0 GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge trusted an unsupported code --open-url: ${browser_out}" ;;
    esac

    rm "${browser_bin}/code"
    browser_out="$(GH_BROWSER_TEST_LOG="$browser_log" \
        GH_BROWSER_TEST_SENTINEL="$browser_sentinel" \
        PATH="$browser_bin" "$gh_browser" "$browser_url" 2>&1)"
    case "$browser_out" in
    *"$browser_url"*) ;;
    *) fail "GitHub browser bridge did not print the URL when code was absent: ${browser_out}" ;;
    esac
    [ ! -e "$browser_sentinel" ] ||
        fail "GitHub browser bridge invoked a terminal browser when code was absent"

    # 10. The shared post-create guidance must never steer a BOT container to an
    #    operator `gh auth login`. Following that advice would put a human
    #    credential — `workflow` scope included — inside a bypassPermissions
    #    agent container, which is the escalation the bot PAT's denials exist to
    #    stop. Each profile opts in via DEVCONTAINER_GH_AUTH, so the DEFAULT has
    #    to be the conservative token message: an unset or misspelled value must
    #    fail safe, not print the operator instructions.
    local post_create_common helper_src help_out
    post_create_common="${repo_root}/.devcontainer/scripts/post-create-common.sh"
    [ -f "$post_create_common" ] || fail "post-create-common.sh not found at ${post_create_common}"
    helper_src="${work_dir}/gh-auth-help.sh"
    sed -n '/^gh_auth_help()/,/^}/p' "$post_create_common" >"$helper_src"
    [ -s "$helper_src" ] || fail "could not extract gh_auth_help() from ${post_create_common}"

    # The banner asks scripts/gh-scopes.sh for the scope list (the single
    # source shared with status.sh and setup:gh-scopes), and the extraction
    # above takes the function body ALONE. Without the library, the call
    # resolves to nothing, the banner renders `--scopes ""`, and a check that
    # only looked for a login command would pass on a broken banner.
    local scopes_lib="${repo_root}/scripts/gh-scopes.sh"
    [ -f "$scopes_lib" ] || fail "scripts/gh-scopes.sh not found at ${scopes_lib}"

    # Match a pasteable COMMAND line — `gh` as the first token — not the bare
    # phrase. The token message names `gh auth login` on purpose, in a "do NOT
    # run this here" warning; a substring test would read that warning as the
    # very thing it warns against, and the check would be worse than useless.
    offers_login() {
        grep -E '^[[:space:]]*gh[[:space:]]+auth[[:space:]]+login' <<<"$1" >/dev/null
    }

    help_out="$(unset DEVCONTAINER_GH_AUTH && "$bash_bin" -c '. "$2"; . "$1"; gh_auth_help "gh auth setup-git"' _ "$helper_src" "$scopes_lib")"
    if offers_login "$help_out"; then
        fail "post-create gh guidance offers an operator login by default — a bot container must never be told to run one"
    fi

    help_out="$(DEVCONTAINER_GH_AUTH=login "$bash_bin" -c '. "$2"; . "$1"; gh_auth_help "gh auth setup-git"' _ "$helper_src" "$scopes_lib")"
    if ! offers_login "$help_out"; then
        fail "post-create gh guidance omits the operator login where the profile declares one"
    fi

    # The login it offers must carry the DERIVED scopes, not an empty or
    # hardcoded list — that agreement between the banner and the scope check is
    # the acceptance criterion the single source exists to satisfy (#827).
    case "$help_out" in
    *'--scopes ""'*) fail "post-create login line renders an empty scope list — gh-scopes.sh was not in scope" ;;
    esac
    for required_scope in repo workflow; do
        case "$help_out" in
        *"${required_scope}"*) ;;
        *) fail "post-create login line omits the '${required_scope}' scope: ${help_out}" ;;
        esac
    done

    # 10b. The bot profile's gh-identity tripwire (harmon-init#1236). The git-identity
    #    assertions prove who a container COMMITS as; nothing proved who `gh`
    #    WRITES as. A bot container whose gh holds a human credential
    #    attributes every issue, PR, and comment to that human — and parks a
    #    personal credential inside a bypassPermissions container. The helper
    #    decides from `gh auth status` output ALONE (the stored-credential
    #    shapes name their account even when validation fails), so these cases
    #    run against a stub gh with no network. The contract under test:
    #    unauthenticated passes-with-remedy (a fresh container before token
    #    provisioning is healthy), any credential naming a non-bot account is
    #    a violation, and an unverifiable token is indeterminate — never a
    #    failure.
    local gh_check gh_id_bin gh_id_fixture gh_id_out gh_id_rc
    gh_check="${repo_root}/.devcontainer/scripts/check-bot-gh-identity.sh"
    [ -f "$gh_check" ] || fail "check-bot-gh-identity.sh not found at ${gh_check}"

    gh_id_bin="${work_dir}/gh-identity-bin"
    gh_id_fixture="${work_dir}/gh-identity-fixture"
    mkdir -p "$gh_id_bin"
    ln -s "$bash_bin" "${gh_id_bin}/bash"
    for gh_id_dep in cat grep awk sort sleep; do
        ln -s "$(command -v "$gh_id_dep")" "${gh_id_bin}/${gh_id_dep}"
    done
    # timeout: Homebrew coreutils on macOS ships it as gtimeout (the same
    # split scripts/status.sh handles), so resolve whichever exists and link
    # it under the name the helper probes — the wedged-gh case below depends
    # on the bound existing, and `ln -s ""` under set -e would otherwise
    # abort the whole unit run before any identity case.
    local gh_id_timeout
    gh_id_timeout="$(command -v timeout || command -v gtimeout)" ||
        fail "neither timeout nor gtimeout is available for the gh-identity unit cases"
    ln -s "$gh_id_timeout" "${gh_id_bin}/timeout"

    gh_identity_run() {
        # $1 = stub gh exit code; the fixture file holds the stub's output.
        # The token aliases are cleared explicitly: unit mode also runs
        # inside the bot container, whose real GH_TOKEN would otherwise
        # leak into every case's environment.
        gh_id_rc=0
        gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" \
            GH_IDENTITY_TEST_RC="$1" \
            GH_TOKEN= GITHUB_TOKEN= GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
            PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    }

    # gh ABSENT from PATH: indeterminate (3), never a violation — the image
    # toolchain checks own "gh is installed"; this check owns identity only.
    # Runs before the stub gh below is created, so the constrained PATH
    # genuinely has no gh.
    gh_id_rc=0
    PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "gh-identity check exited ${gh_id_rc} with no gh on PATH — expected indeterminate (3)"

    printf '%s\n' '#!/bin/sh' 'cat "$GH_IDENTITY_TEST_FIXTURE"' \
        'exit "${GH_IDENTITY_TEST_RC:-0}"' >"${gh_id_bin}/gh"
    chmod 0755 "${gh_id_bin}/gh"

    # Fresh container, token never provisioned: PASS-WITH-REMEDY (2). The
    # remedy must name GH_TOKEN and the env-file, and must never be an
    # operator login — gh's own output suggests exactly that, which is how
    # the live violation happened.
    printf '%s\n' \
        'You are not logged into any GitHub hosts. To log in, run: gh auth login' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "2" ] ||
        fail "unauthenticated gh exited ${gh_id_rc}, expected pass-with-remedy (2)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "unauthenticated gh-identity warning does not name GH_TOKEN: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *.devcontainer/devcontainer.env*) ;;
    *) fail "unauthenticated gh-identity warning does not name .devcontainer/devcontainer.env: ${gh_id_out}" ;;
    esac
    # The remedy must describe the PROVISIONING chain (harmon-init#1236 scope correction):
    # on Coder the PAT arrives from the workspace's template parameter, and
    # generically from the host env init-env.sh projects — never a
    # hand-authored secret file, and never an interactive login.
    case "$gh_id_out" in
    *"template parameter"*) ;;
    *) fail "unauthenticated gh-identity warning does not name the Coder template parameter: ${gh_id_out}" ;;
    esac
    if offers_login "$gh_id_out"; then
        fail "gh-identity warning offers an operator login in a bot container"
    fi

    # Authenticated as the bot: OK. The RELATIONSHIP (a '-bot' suffix, same
    # style as the git-identity assertions) — never a literal account name.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "0" ] ||
        fail "bot-suffixed gh login exited ${gh_id_rc}, expected pass (0)"

    # The observed violation (harmon-init#1236): an operator login in the bot container.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        '  - Active account: true' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot gh login exited ${gh_id_rc}, expected violation (1)"
    case "$gh_id_out" in
    *someoperator*) ;;
    *) fail "gh-identity violation warning does not name the offending login: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "gh-identity violation warning does not name the GH_TOKEN remedy: ${gh_id_out}" ;;
    esac
    if offers_login "$gh_id_out"; then
        fail "gh-identity violation warning offers an operator login in a bot container"
    fi

    # A stored login names its account even when validation fails (offline
    # or revoked): the CREDENTIAL is the violation, not the token's
    # freshness, so this must not degrade to indeterminate.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com account someoperator (/home/vscode/.config/gh/hosts.yml)' \
        '  - Active account: true' \
        '  - The token in /home/vscode/.config/gh/hosts.yml is invalid.' \
        '  - To re-authenticate, run: gh auth refresh -h github.com' \
        '  - To forget about this account, run: gh auth logout -h github.com -u someoperator' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "1" ] ||
        fail "stale non-bot gh credential exited ${gh_id_rc}, expected violation (1)"
    if offers_login "$gh_id_out"; then
        fail "stale-credential gh-identity warning offers an operator login in a bot container"
    fi

    # GH_TOKEN present but unverifiable (offline, rate-limited, expired):
    # gh names no account, so identity is INDETERMINATE (3) — a network
    # hiccup must not fail the assert or block a fresh container.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '  - The token in GH_TOKEN is invalid.' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "3" ] ||
        fail "unverifiable GH_TOKEN exited ${gh_id_rc}, expected indeterminate (3)"

    # A human credential parked BESIDE a valid bot token is still a
    # violation: gh can switch accounts, and the personal credential is
    # inside the container either way.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 0
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot credential beside the bot token exited ${gh_id_rc}, expected violation (1)"

    # An UNNAMED failed-token entry beside a named stored bot login: gh
    # prefers an environment token for writes, so while one is unverified
    # the ACTIVE identity is unknown no matter which stored logins are also
    # present — indeterminate (3), never a clean 0 off the stored account.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '' \
        '  ✓ Logged in to github.com account someowner-bot (keyring)' \
        '  - Active account: false' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "3" ] ||
        fail "unverifiable token beside a stored bot login exited ${gh_id_rc}, expected indeterminate (3)"

    # ...but a KNOWN non-bot credential still outranks that indeterminacy:
    # the stored human login is a violation regardless of what the unnamed
    # token would have resolved to.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        '  - Active account: false' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot stored login beside an unverifiable token exited ${gh_id_rc}, expected violation (1)"

    # A SHADOWED environment-token alias is credential material gh cannot
    # enumerate: with both GH_TOKEN and GITHUB_TOKEN set, gh auth status
    # reports only GH_TOKEN (verified live), so a valid bot token in front
    # of a different personal token must not read as "every credential is
    # a bot". Indeterminate — and the warning names the alias, never the
    # value.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN=sentinel-shadowed \
        GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "a shadowed GITHUB_TOKEN behind a bot GH_TOKEN exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *GITHUB_TOKEN*) ;;
    *) fail "shadowed-alias warning does not name the shadowed variable: ${gh_id_out}" ;;
    esac
    case "$gh_id_out" in
    *sentinel-shadowed* | *sentinel-primary*)
        fail "shadowed-alias warning printed a token VALUE"
        ;;
    esac

    # The same value spelled through two aliases is one credential twice,
    # not a shadow: stays clean.
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN=sentinel-primary \
        GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "0" ] ||
        fail "duplicate same-value aliases exited ${gh_id_rc}, expected pass (0)"

    # A known non-bot login still outranks the shadow's indeterminacy.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN=sentinel-shadowed \
        GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "1" ] ||
        fail "non-bot login beside shadowed aliases exited ${gh_id_rc}, expected violation (1)"

    # An environment token gh attributes to NO host (an enterprise alias
    # with no configured GHES host) must not read as clean-unauthenticated:
    # the credential is present, just invisible to the enumeration.
    printf '%s\n' \
        'You are not logged into any GitHub hosts. To log in, run: gh auth login' \
        >"$gh_id_fixture"
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=1 \
        GH_TOKEN= GITHUB_TOKEN= GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "an unattributed enterprise token with no logins exited ${gh_id_rc}, expected indeterminate (3)"

    # gh's own BUILT-IN timeout is a fourth status shape: it exits with the
    # ordinary failure code (not 124/137) and writes "Timeout ... log in to
    # <host> using token" / "... account <login>". A timed-out active token
    # beside a stored bot login must stay unverified, not clean.
    printf '%s\n' \
        'github.com' \
        '  X Timeout trying to log in to github.com using token (GH_TOKEN)' \
        '  - Active account: true' \
        '' \
        '  ✓ Logged in to github.com account someowner-bot (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "3" ] ||
        fail "a gh-internal token timeout beside a stored bot login exited ${gh_id_rc}, expected indeterminate (3)"

    # ...and a timeout record that NAMES a non-bot account is still a
    # credential claiming a human identity: violation, whatever wording
    # variant gh used.
    printf '%s\n' \
        'github.com' \
        '  X Timeout error trying to log in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "1" ] ||
        fail "a gh-internal timeout naming a non-bot account exited ${gh_id_rc}, expected violation (1)"

    # The two alias pairs are INDEPENDENT precedence groups (gh help
    # environment): a bot GH_TOKEN beside a different GH_ENTERPRISE_TOKEN,
    # both enumerated as bot accounts on their own hosts, is a legitimate
    # setup — never a shadow.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        '' \
        'ghe.example.com' \
        '  ✓ Logged in to ghe.example.com account someowner-bot (GH_ENTERPRISE_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN= \
        GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    [ "$gh_id_rc" = "0" ] ||
        fail "cross-pair bot tokens on their own hosts exited ${gh_id_rc}, expected pass (0)"

    # A *.ghe.com tenant host is served by GH_TOKEN (gh help environment),
    # so its presence is NOT evidence the enterprise token was enumerated:
    # only a record explicitly sourced from the enterprise alias is.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        '' \
        'tenant.ghe.com' \
        '  ✓ Logged in to tenant.ghe.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN= \
        GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "an enterprise token with only GH_TOKEN-sourced ghe.com records exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *"never enumerated"*) ;;
    *) fail "the ghe.com-tenant note does not say the enterprise token was never enumerated: ${gh_id_out}" ;;
    esac

    # gh's "(default)" pseudo-source — GH_HOST selecting a host with
    # neither a stored login nor a token — is the ordinary unauthenticated
    # state, not an unverified token: the banner-and-remedy exit, never a
    # false token-present indeterminate.
    printf '%s\n' \
        'github.com' \
        '  X Failed to log in to github.com using token (default)' \
        >"$gh_id_fixture"
    gh_identity_run 1
    [ "$gh_id_rc" = "2" ] ||
        fail "a (default) pseudo-source with no aliases exited ${gh_id_rc}, expected unauthenticated (2)"
    case "$gh_id_out" in
    *GH_TOKEN*) ;;
    *) fail "the (default) unauthenticated banner does not name GH_TOKEN: ${gh_id_out}" ;;
    esac
    if offers_login "$gh_id_out"; then
        fail "the (default) unauthenticated banner offers an operator login"
    fi

    # ...but an enterprise token gh attributes to NO host was never
    # enumerated: present-but-invisible credential material, indeterminate
    # even while the github.com login reads bot.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TEST_FIXTURE="$gh_id_fixture" GH_IDENTITY_TEST_RC=0 \
        GH_TOKEN=sentinel-primary GITHUB_TOKEN= \
        GH_ENTERPRISE_TOKEN=sentinel-ghes GITHUB_ENTERPRISE_TOKEN= \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    [ "$gh_id_rc" = "3" ] ||
        fail "an enterprise token with no GHES host enumerated exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *"never enumerated"*) ;;
    *) fail "the unattributed enterprise-token note does not say the token was never enumerated: ${gh_id_out}" ;;
    esac

    # A TIMED-OUT enumeration is INCOMPLETE, not clean: gh validates
    # accounts sequentially, so a probe killed after printing the bot
    # account but before a later stored human credential must not read as
    # "every credential is a bot". The stub reproduces the partial output
    # and timeout(1)'s 124.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someowner-bot (GH_TOKEN)' \
        >"$gh_id_fixture"
    gh_identity_run 124
    [ "$gh_id_rc" = "3" ] ||
        fail "timed-out bot-only enumeration exited ${gh_id_rc}, expected indeterminate (3)"

    # ...while a non-bot login already parsed BEFORE the deadline is
    # evidence that stands: the violation outranks the incompleteness.
    printf '%s\n' \
        'github.com' \
        '  ✓ Logged in to github.com account someoperator (keyring)' \
        >"$gh_id_fixture"
    gh_identity_run 124
    [ "$gh_id_rc" = "1" ] ||
        fail "timed-out enumeration with a parsed non-bot login exited ${gh_id_rc}, expected violation (1)"

    # A WEDGED gh (stalled network, DNS, or credential backend) must not
    # hang the callers: post-start and the container assert invoke the
    # helper with no wrapper, so the bound has to live inside it. The stub
    # sleeps far past the 1s override; only the helper's own timeout can
    # end the run quickly, and the elapsed bound is what catches an
    # unbounded probe.
    local gh_id_start gh_id_elapsed
    printf '%s\n' '#!/bin/sh' 'sleep 45' >"${gh_id_bin}/gh"
    gh_id_start="$(date +%s)"
    gh_id_rc=0
    GH_IDENTITY_TIMEOUT=1 PATH="$gh_id_bin" "$bash_bin" "$gh_check" >/dev/null 2>&1 || gh_id_rc=$?
    gh_id_elapsed=$(($(date +%s) - gh_id_start))
    [ "$gh_id_elapsed" -lt 30 ] ||
        fail "gh-identity probe ran ${gh_id_elapsed}s against a wedged gh — the helper carries no timeout"
    [ "$gh_id_rc" = "3" ] ||
        fail "wedged gh exited ${gh_id_rc}, expected indeterminate (3) via the helper's own timeout"

    # A kill-resistant gh (TERM trapped) must still resolve inside the
    # caller's window: the kill grace is parameterized so the status
    # board's outer bound can contain deadline + grace, and the helper's
    # own timed-out note survives to be printed. Elapsed is the assertion:
    # the default 5s grace would run ~6s and lose the note to the outer
    # kill.
    printf '%s\n' '#!/bin/sh' "trap '' TERM" 'sleep 45' >"${gh_id_bin}/gh"
    gh_id_start="$(date +%s)"
    gh_id_rc=0
    gh_id_out="$(GH_IDENTITY_TIMEOUT=1 GH_IDENTITY_KILL_GRACE=1 \
        PATH="$gh_id_bin" "$bash_bin" "$gh_check" 2>&1)" || gh_id_rc=$?
    gh_id_elapsed=$(($(date +%s) - gh_id_start))
    [ "$gh_id_elapsed" -lt 5 ] ||
        fail "kill-resistant gh took ${gh_id_elapsed}s under a 1s deadline + 1s grace — the grace is not parameterized"
    [ "$gh_id_rc" = "3" ] ||
        fail "kill-resistant gh exited ${gh_id_rc}, expected indeterminate (3)"
    case "$gh_id_out" in
    *"timed out"*) ;;
    *) fail "kill-resistant gh lost the helper's own timed-out note: ${gh_id_out}" ;;
    esac

    # Wiring: the BOT post-start runs the tripwire on every start (an
    # interactive login can happen at any point in a container's life, not
    # just at create); the human profile must not — a human login is that
    # profile's correct state.
    grep -q 'check-bot-gh-identity.sh' "${repo_root}/.devcontainer/post-start.sh" ||
        fail "bot post-start does not run the gh-identity tripwire"
    if grep -q 'check-bot-gh-identity.sh' "${repo_root}/.devcontainer/dev/post-start.sh"; then
        fail "human post-start runs the bot-only gh-identity tripwire"
    fi

    # Post-start redirects everything to a log nobody watches, so the board
    # is the VISIBLE surface (same reasoning as check-image-staleness.sh):
    # the session-start hook runs the creds section, which must run the
    # tripwire — gated to the bot profile by its FOREMAN_DEVCONTAINER=bot
    # containerEnv marker, so the human profile's board never prints a
    # bot warning.
    #
    # Two SEPARATE assertions, because one grep over both cannot tell them
    # apart. The guarded block opens with a `[ -r … ]` readability test that
    # NAMES the helper, so a proximity match on the filename alone passes on
    # that test while the line that actually runs the helper says something
    # else entirely — verified by mutation: replacing the invocation's path
    # left a filename-proximity check green. So assert the guard and the
    # INVOCATION independently, and require the invocation to be a real
    # execution (optionally wrapped in run_timeout and env overrides) rather
    # than any mention.
    local status_sh status_guard_line status_invoke_line
    status_sh="${repo_root}/scripts/status.sh"
    status_invoke_line="$(grep -nE '^[[:space:]]*([A-Z_]+=[^[:space:]]*[[:space:]]+)*(run_timeout[[:space:]]+[0-9]+[[:space:]]+)?bash[[:space:]]+[^[:space:]|]*check-bot-gh-identity\.sh' \
        "$status_sh" | head -1 | cut -d: -f1)"
    [ -n "$status_invoke_line" ] ||
        fail "status board never executes check-bot-gh-identity.sh (a mention in a [ -r ] test is not a run)"
    # The invocation must sit INSIDE a bot guard. Anchor on the guard NEAREST
    # ABOVE the invocation, not the file's first one: status.sh also consults
    # the same marker in gh_login_remedy several hundred lines earlier, and
    # anchoring on that match would measure the distance to an unrelated guard.
    status_guard_line="$(grep -n 'FOREMAN_DEVCONTAINER:-}" = "bot"' "$status_sh" |
        cut -d: -f1 | awk -v n="$status_invoke_line" '$1 < n { g = $1 } END { print g }')"
    [ -n "$status_guard_line" ] ||
        fail "status board runs the gh-identity tripwire with no FOREMAN_DEVCONTAINER=bot guard above it"
    [ "$((status_invoke_line - status_guard_line))" -le 10 ] ||
        fail "status board's gh-identity run (line ${status_invoke_line}) is too far from its bot-profile guard (line ${status_guard_line}) to be inside it"

    # EVERY render_local_credentials call site must be covered, not just the
    # first. `should_show creds` is false under SECTION=setup, so an inline
    # launch at the creds site alone left `task status:setup` printing a green
    # authenticated gh line with no identity warning in a bot container
    # authenticated as a human — the exact state the tripwire exists to
    # surface. Found by the challenge stage; this is its regression test.
    local render_sites launch_sites
    render_sites="$(grep -cE '^[[:space:]]*render_local_credentials([[:space:]]|\||$)' "$status_sh")"
    launch_sites="$(grep -cE '^[[:space:]]*gh_identity_launch[[:space:]]*$' "$status_sh")"
    [ "$render_sites" -gt 0 ] ||
        fail "status board has no render_local_credentials call site to guard"
    [ "$launch_sites" -ge "$render_sites" ] ||
        fail "status board renders local credentials at ${render_sites} site(s) but launches the gh-identity tripwire at only ${launch_sites} — a section that renders creds without it reports a human login as healthy"
    # ...and each launch must be paired with a collect, or the banner is
    # computed and never printed.
    [ "$(grep -cE '^[[:space:]]*gh_identity_collect[[:space:]]*$' "$status_sh")" = "$launch_sites" ] ||
        fail "status board's gh_identity_launch and gh_identity_collect calls are unpaired — a launched probe whose output is never collected prints nothing"

    # NO user-facing output line in the status board may hardcode the
    # interactive-login remedy: in the bot profile it would contradict the
    # tripwire banner printed on the same screen and re-create the escalation
    # this change exists to stop. gh_login_remedy is the single place that
    # decides the wording, so every echo/printf/checkline must route through
    # it. Comments are exempt (they explain the rule); the helper's own body is
    # exempt because it IS the rule. Found by challenge round 2, which caught a
    # third remedy site in the setup audit that the first pass missed.
    local stray_remedy
    stray_remedy="$(grep -nE "(echo|printf|checkline)[^#]*gh auth login" "$status_sh" |
        grep -vE '^[0-9]+:[[:space:]]*#' |
        awk -F: -v s="$(grep -n '^gh_login_remedy() {' "$status_sh" | cut -d: -f1)" \
            -v e="$(awk '/^gh_login_remedy\(\) \{/{f=1} f&&/^\}/{print NR; exit}' "$status_sh")" \
            '$1 < s || $1 > e' || true)"
    [ -z "$stray_remedy" ] ||
        fail "status board hardcodes the interactive-login remedy outside gh_login_remedy — it would contradict the bot tripwire banner: ${stray_remedy}"

    # The credential line's own remedy must not contradict the tripwire banner
    # on the same screen: in the bot profile an operator `gh auth login` is the
    # escalation harmon-init#1236 exists to stop.
    local remedy_out
    remedy_out="$(FOREMAN_DEVCONTAINER=bot "$bash_bin" -c \
        "$(sed -n '/^gh_login_remedy() {/,/^}/p' "$status_sh"); gh_login_remedy")"
    if offers_login "$remedy_out"; then
        fail "status board's gh remedy offers an interactive login in the bot profile: ${remedy_out}"
    fi
    case "$remedy_out" in
    *GH_TOKEN*) ;;
    *) fail "status board's bot-profile gh remedy does not name GH_TOKEN: ${remedy_out}" ;;
    esac
    remedy_out="$(FOREMAN_DEVCONTAINER= "$bash_bin" -c \
        "$(sed -n '/^gh_login_remedy() {/,/^}/p' "$status_sh"); gh_login_remedy")"
    if ! offers_login "$remedy_out"; then
        fail "status board's gh remedy omits the operator login outside the bot profile: ${remedy_out}"
    fi

    # 11. Static devcontainer.json invariants via the devcontainers CLI.
    assert_config_invariants "$repo_root" "$bot_config" bot
    assert_config_invariants "$repo_root" "$dev_config" dev

    echo "==> devcontainer unit assertions passed."
}

# assert_config_invariants <repo_root> <config> <profile>
# bot: NO tailscale feature, NO 1Password CLI feature, NO /dev/net/tun runArg,
#      NO TS_AUTHKEY in initializeCommand — the bot container must hold no path
#      to production secrets or the tailnet. dev: all four present.
# GH_TOKEN is the one invariant that runs the OTHER way. The bot's scoped PAT
# belongs in the bot profile only; the dev profile commits as the operator and
# so must authenticate as the operator, never as the bot. Asserted statically
# because the failure is silent at runtime: `gh` prefers GH_TOKEN over a stored
# credential unconditionally, so a re-added allow-list entry would quietly put
# the bot back in charge of a human's pushes.
assert_config_invariants() {
    local repo_root="$1" config="$2" profile="$3"
    local cfg has_ts_feature has_op_feature has_tun has_ts_init has_gh_init

    # read-configuration 0.87+ probes Docker for an existing container even
    # though this assertion only needs the static JSONC. A no-op docker path
    # keeps this unit check daemon-independent as documented.
    cfg="$(devcontainer_cli read-configuration \
        --docker-path /usr/bin/true \
        --workspace-folder "$repo_root" \
        --config "$config")" ||
        fail "read-configuration failed for ${config}"

    has_ts_feature="$(printf '%s' "$cfg" |
        jq -r '[.configuration.features // {} | keys[] | select(test("tailscale";"i"))] | length')"
    has_op_feature="$(printf '%s' "$cfg" |
        jq -r '[.configuration.features // {} | keys[] | select(test("1password";"i"))] | length')"
    has_tun="$(printf '%s' "$cfg" |
        jq -r '[.configuration.runArgs // [] | .[] | select(test("/dev/net/tun"))] | length')"
    has_ts_init="$(printf '%s' "$cfg" |
        jq -r '(.configuration.initializeCommand // "") | test("TS_AUTHKEY") | if . then 1 else 0 end')"
    has_gh_init="$(printf '%s' "$cfg" |
        jq -r '(.configuration.initializeCommand // "") | test("GH_TOKEN") | if . then 1 else 0 end')"
    local foreman_marker gh_browser_config terminal_browser_config
    foreman_marker="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.FOREMAN_DEVCONTAINER // ""')"
    gh_browser_config="$(printf '%s' "$cfg" |
        jq -r '.configuration.containerEnv.GH_BROWSER // ""')"
    terminal_browser_config="$(printf '%s' "$cfg" |
        jq -r '.configuration.customizations.vscode.settings["terminal.integrated.env.linux"].BROWSER // "<absent>"')"
    [ "$terminal_browser_config" = "" ] ||
        fail "${profile} config no longer blanks generic BROWSER in VS Code terminals"

    if [ "$profile" = "bot" ]; then
        [ "$has_ts_feature" = "0" ] || fail "bot config has a tailscale feature"
        [ "$has_op_feature" = "0" ] || fail "bot config has a 1Password CLI feature (no secret-store path in the bot container)"
        [ "$has_tun" = "0" ] || fail "bot config requests /dev/net/tun"
        [ "$has_ts_init" = "0" ] || fail "bot config references TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "1" ] || fail "bot config does not reference GH_TOKEN in initializeCommand"
        [ -z "$gh_browser_config" ] || fail "bot config sets GH_BROWSER — operator OAuth belongs only in the human profile"
        # Foreman's D2 startup tripwire: it refuses even read-only commands
        # unless FOREMAN_DEVCONTAINER=bot, so losing this marker breaks every
        # task foreman:* while verify stays green.
        [ "$foreman_marker" = "bot" ] || fail "bot config does not set containerEnv.FOREMAN_DEVCONTAINER=bot (foreman refuses to start)"
    else
        [ "$has_ts_feature" != "0" ] || fail "dev config is missing the tailscale feature"
        [ "$has_op_feature" != "0" ] || fail "dev config is missing the 1Password CLI feature"
        [ "$has_tun" != "0" ] || fail "dev config is missing the /dev/net/tun device"
        [ "$has_ts_init" = "1" ] || fail "dev config does not reference TS_AUTHKEY in initializeCommand"
        [ "$has_gh_init" = "0" ] || fail "dev config references GH_TOKEN in initializeCommand (a human profile must carry no bot credential)"
        [ -z "$foreman_marker" ] || fail "dev config sets FOREMAN_DEVCONTAINER — foreman must refuse to run in the human profile"
        [ "$gh_browser_config" = "/usr/local/share/devcontainer-config/gh-browser.sh" ] ||
            fail "dev config does not route GH_BROWSER through the host-browser bridge; found '${gh_browser_config}'"

        # Dropping GH_TOKEN only removes the FIRST link in gh's credential
        # chain. GITHUB_TOKEN and the enterprise aliases outrank the stored
        # `gh auth login` too, and init-env.sh does not recognize those names,
        # so an env-file carrying one would quietly own this profile's identity
        # while every check above still passed. containerEnv (docker --env,
        # which outranks --env-file) must blank each one; gh reads empty as
        # unset. A MISSING key is a failure, not a pass — that is the state
        # this assertion exists to catch.
        local alias_var blanked
        for alias_var in GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
            blanked="$(printf '%s' "$cfg" |
                jq -r --arg v "$alias_var" '(.configuration.containerEnv // {})[$v] // "<absent>"')"
            [ "$blanked" = "" ] ||
                fail "dev config does not blank ${alias_var} in containerEnv (gh would prefer it over the operator's login); found '${blanked}'"
        done
    fi
}

# ── container mode ────────────────────────────────────────────────────
# assert_container <config> <container-id> <profile> <workspace-folder>
assert_container() {
    local config="$1" container_id="$2" profile="$3" workspace_folder="$4"
    [ -n "$container_id" ] || fail "container mode requires a container id"
    [ -n "$workspace_folder" ] || fail "container mode requires a workspace folder"

    local git_name git_email codex_sandbox codex_approval codex_model codex_effort
    git_name="$(docker exec -u vscode "$container_id" git config --global user.name)" ||
        fail "could not read git user.name in container"
    git_email="$(docker exec -u vscode "$container_id" git config --global user.email)" ||
        fail "could not read git user.email in container"
    codex_model="$(docker exec -u vscode "$container_id" cat /etc/codex/managed_config.toml | toml_root_scalar model -)" ||
        fail "could not read the managed Codex model"
    codex_effort="$(docker exec -u vscode "$container_id" cat /etc/codex/managed_config.toml | toml_root_scalar model_reasoning_effort -)" ||
        fail "could not read the managed Codex reasoning effort"
    codex_sandbox="$(docker exec -u vscode "$container_id" cat /etc/codex/managed_config.toml | toml_root_scalar sandbox_mode -)" ||
        fail "could not read the managed Codex sandbox mode"
    codex_approval="$(docker exec -u vscode "$container_id" cat /etc/codex/managed_config.toml | toml_root_scalar approval_policy -)" ||
        fail "could not read the managed Codex approval policy"
    [ "$codex_model" = "gpt-5.6-sol" ] || fail "Codex model is '${codex_model}', expected gpt-5.6-sol"
    [ "$codex_effort" = "medium" ] || fail "Codex reasoning is '${codex_effort}', expected medium"

    # `task` ships from the pinned shared image, NOT a devcontainer Feature
    # (harmon-init#427 history). The expected version comes from the image's
    # own machine-readable manifest, and the manifest's revision must match
    # the Dockerfile's pinned source commit — proving the running container
    # was really built from the approved immutable reference, not a stale or
    # floating image that happens to have the binaries.
    local script_dir repo_root pinned_source manifest manifest_revision pinned_task actual_task
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
    pinned_source="$(assert_image_pin "${repo_root}/.devcontainer/Dockerfile")"
    manifest="$(docker exec -u vscode "$container_id" cat "$HARMON_IMAGE_MANIFEST" 2>/dev/null)" ||
        fail "image manifest ${HARMON_IMAGE_MANIFEST} is missing in the ${profile} container"
    manifest_revision="$(printf '%s' "$manifest" | jq -r '.image.revision // empty')" ||
        fail "image manifest in the ${profile} container is not valid JSON"
    [ "$manifest_revision" = "$pinned_source" ] ||
        fail "container image revision '${manifest_revision}' does not match the Dockerfile pin '${pinned_source}' in the ${profile} container"
    pinned_task="$(printf '%s' "$manifest" | jq -r '.tools.task // empty')"
    [ -n "$pinned_task" ] ||
        fail "image manifest lists no task version in the ${profile} container"
    actual_task="$(docker exec -u vscode "$container_id" sh -c 'task --version' 2>/dev/null)" ||
        fail "task is not runnable in the ${profile} container"
    # Compare EXACTLY, not as a substring: `*3.5.2*` also matches the output
    # "3.5.20", which would wave through a binary that is not the pinned one.
    # `task --version` prints a bare "3.52.0"; older builds printed
    # "Task version: v3.52.0" — reduce both shapes to the bare version first.
    local actual_version
    actual_version="$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$actual_task")"
    [ -n "$actual_version" ] ||
        fail "could not parse a version out of 'task --version' output '${actual_task}' in the ${profile} container"
    [ "$actual_version" = "$pinned_task" ] ||
        fail "task version '${actual_version}' in the ${profile} container does not match the pin '${pinned_task}'"

    if [ "$profile" = "bot" ]; then
        [ "$codex_sandbox" = "danger-full-access" ] || fail "bot Codex sandbox is '${codex_sandbox}'"
        [ "$codex_approval" = "never" ] || fail "bot Codex approval policy is '${codex_approval}'"
        # Assert the bot identity RELATIONSHIP, not literal values, so the
        # script stays valid verbatim in generated projects.
        case "$git_email" in
        *-bot@*) ;;
        *) fail "bot git email '${git_email}' does not contain '-bot@'" ;;
        esac
        case "$git_name" in
        *-bot) ;;
        *) fail "bot git name '${git_name}' does not end with '-bot'" ;;
        esac

        # Who gh WRITES as, not just who git commits as (harmon-init#1236) —
        # the live counterpart of unit check 10b. The checkout's helper runs
        # inside the container over stdin, so no workspace mount path is
        # assumed. Only exit 1 — a credential naming a non-bot account — is the
        # violation this assert exists to catch. Unauthenticated (2) passes:
        # the helper already printed the GH_TOKEN remedy, and a fresh
        # container before token provisioning is healthy. Indeterminate (3:
        # offline, rate-limited, or an unverifiable token) is not evidence
        # of a violation and must not fail a smoke run.
        local gh_identity_rc=0
        docker exec -i -u vscode "$container_id" bash -s \
            <"${repo_root}/.devcontainer/scripts/check-bot-gh-identity.sh" ||
            gh_identity_rc=$?
        case "$gh_identity_rc" in
        0 | 2 | 3) ;;
        1) fail "bot container gh credential does not match the '-bot' relationship (see warning above)" ;;
        *) fail "could not run the gh-identity check in the bot container (exit ${gh_identity_rc})" ;;
        esac

        # `command` is a shell BUILTIN, so it must run inside a shell: bare
        # `docker exec <id> command -v x` execs a binary that does not exist
        # and always fails, which silently made this check vacuous.
        if docker exec -u vscode "$container_id" sh -c 'command -v tailscale' >/dev/null 2>&1; then
            fail "tailscale CLI is present in the bot container"
        fi

        # Captured, never echoed: the failure message reports only that a key
        # is set, never its value. Do NOT run this script under `set -x` — the
        # trace would expand the real key into stderr and CI logs.
        local ts_authkey
        ts_authkey="$(docker exec -u vscode "$container_id" printenv TS_AUTHKEY 2>/dev/null || true)"
        [ -z "$ts_authkey" ] || fail "TS_AUTHKEY is set in the bot container"

        # Every supported installed harness's bot policy, re-checked against
        # its live effective state — the same verifier post-create and
        # post-start already run. Reuses the one implementation rather than
        # duplicating each boundary's check a second time here (Claude Code,
        # Antigravity, and OpenCode would otherwise go completely unchecked
        # in CI despite the "every supported installed harness" claim).
        # `-w` pins the exec's cwd to the workspace folder: the Dockerfile
        # sets no WORKDIR, so `docker exec` with no `-w` defaults to `/` (or
        # whatever the base image sets), not the mounted workspace — a
        # relative script path resolves against that default, not against
        # where postCreate/postStart actually run.
        local bot_autonomy_out bot_autonomy_rc
        bot_autonomy_rc=0
        bot_autonomy_out="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
            bash .devcontainer/scripts/bot-autonomy.sh verify 2>&1)" || bot_autonomy_rc=$?
        [ "$bot_autonomy_rc" -eq 0 ] ||
            fail "bot-autonomy.sh verify failed in the bot container: ${bot_autonomy_out}"

        # The Copilot autonomy wrapper only works if it actually WINS on the
        # container-wide PATH. `bot-autonomy.sh verify` proves the wrapper
        # exists with the right bytes, but a wrong PATH order would leave
        # every real `copilot` invocation delegating straight to the system
        # binary with no --allow-all — a green verify over an ineffective
        # wrapper. Resolve the name the way a programmatic launcher does
        # (no login shell), assert WHICH file wins, and only then exercise
        # it. Gated on the marker: a default-off consumer has no wrapper to
        # win, and on a pin that predates the harness-matrix image there is
        # no `copilot` at all yet (see
        # https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/tasks.md task 5.5 —
        # this becomes live coverage once the sync-pin PR lands).
        local copilot_marker copilot_path copilot_version
        copilot_marker="$(docker exec -u vscode "$container_id" printenv HARMON_BOT_AUTONOMY_COPILOT 2>/dev/null || true)"
        copilot_path="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
            sh -c 'command -v copilot || true' 2>/dev/null || true)"
        if [ "$copilot_marker" = "enabled" ] && [ -n "$copilot_path" ]; then
            [ "$copilot_path" = "/home/vscode/.local/bin/copilot" ] ||
                fail "copilot resolves to '${copilot_path}' in the bot container, not the autonomy wrapper at /home/vscode/.local/bin/copilot — the container-wide PATH prepend is not winning"
            copilot_version="$(docker exec -u vscode -w "$workspace_folder" "$container_id" \
                copilot --version 2>&1)" ||
                fail "the copilot autonomy wrapper could not run 'copilot --version' in the bot container: ${copilot_version}"
        elif [ "$copilot_marker" = "enabled" ] &&
            [ "$(pinned_image_digest "${repo_root}/.devcontainer/Dockerfile")" = "$HARMON_PRE_HARNESS_MATRIX_DIGEST" ]; then
            # Bounded to the one pin that genuinely ships no copilot, so this
            # cannot become a standing excuse — see the constant above.
            echo "==> note: HARMON_BOT_AUTONOMY_COPILOT=enabled on the pre-harness-matrix pin, which ships no copilot binary; wrapper PATH assertion becomes live when #1152 bumps the pin"
        elif [ "$copilot_marker" = "enabled" ]; then
            fail "HARMON_BOT_AUTONOMY_COPILOT=enabled but no copilot resolves on PATH in the bot container, and this image is not the pre-harness-matrix pin — the autonomy wrapper is missing or its binary is gone"
        fi
    else
        [ "$codex_sandbox" = "workspace-write" ] || fail "human Codex sandbox is '${codex_sandbox}'"
        [ "$codex_approval" = "on-request" ] || fail "human Codex approval policy is '${codex_approval}'"
        case "$git_email" in
        *-bot@*) fail "dev git email '${git_email}' unexpectedly contains '-bot@'" ;;
        esac
        case "$git_name" in
        *-bot) fail "dev git name '${git_name}' unexpectedly ends with '-bot'" ;;
        esac

        # Same builtin caveat as the bot branch above — without `sh -c` this
        # never passes, regardless of whether tailscale is installed.
        if ! docker exec -u vscode "$container_id" sh -c 'command -v tailscale' >/dev/null 2>&1; then
            fail "tailscale CLI is missing from the dev container"
        fi

        # The live counterpart of the static GH_TOKEN invariant: a human profile
        # authenticates as the operator through `gh auth login`, so the bot's PAT
        # must not be in this container's environment. Captured, never echoed —
        # same discipline as the bot's TS_AUTHKEY check above.
        local gh_token
        gh_token="$(docker exec -u vscode "$container_id" printenv GH_TOKEN 2>/dev/null || true)"
        [ -z "$gh_token" ] || fail "GH_TOKEN is set in the dev container"
    fi

    echo "==> devcontainer container assertions passed for ${config} (${profile})."
}

# ── dispatch ──────────────────────────────────────────────────────────
mode="${1:-}"
case "$mode" in
unit)
    assert_unit
    ;;
container)
    shift
    if [ "$#" -ne 4 ]; then
        echo "Usage: $0 container <config> <container-id> <profile> <workspace-folder>" >&2
        exit 1
    fi
    assert_container "$1" "$2" "$3" "$4"
    ;;
*)
    echo "Usage: $0 <unit|container> [args...]" >&2
    exit 1
    ;;
esac
