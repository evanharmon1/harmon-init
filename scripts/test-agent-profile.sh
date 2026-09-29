#!/usr/bin/env bash
set -euo pipefail

# Unit tests for the AGENT posture
# (docs/decisions/2026-09-29-agent-posture-three-posture-model.md). No
# container, no real secrets: every fixture uses a scratch directory, a fake
# PATH, and stub resolvers. The live counterparts — the filter really refusing
# a host, the harnesses really refused — run in the built container
# (scripts/devcontainer-assert.sh container mode, CI's devcontainer-assert-agent).
#
# What each section guards:
#   1. single source      — the agent Claude settings and Codex config exist
#                           only under .devcontainer/config/agent/ (and its
#                           verbatim template twin), and the agent
#                           devcontainer installs from there
#   2. Claude settings    — auto mode, bypass disabled, no ask rules, the
#                           agreed deny list, and nothing allowed that bot
#                           denies or that bot does not itself allow
#   3. Codex config       — never danger-full-access; parity with the shared
#                           baseline except the agent's documented keys
#   4. harness refusal    — coverage of every registry slug; apply refuses a
#                           harness with no agent-capable configuration, and
#                           only under the agent marker
#   5. env allowlist      — init-env.sh --profile agent admits the agent PAT
#                           and fails closed on everything else
#   6. Docker             — no socket ever; Docker-in-Docker only with the
#                           documented opt-in
#   7. egress             — the list parses, resolves, refuses an
#                           allow-nothing filter and an over-broad literal
#                           or @github-meta range (0.0.0.0/x, wider than
#                           /16); the lifecycle
#                           snapshots it root-owned at create, applies it
#                           first, and applies only the snapshot at start

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
cd "$repo_root"

agent_config_dir=.devcontainer/config/agent
agent_settings="${agent_config_dir}/claude-managed-settings.json"
agent_codex="${agent_config_dir}/codex-managed-config.toml"
bot_settings=.devcontainer/config/claude-settings.json
codex_baseline=.devcontainer/config/codex-managed-config.toml
agent_dc=.devcontainer/agent/devcontainer.json
agent_autonomy=.devcontainer/agent/agent-autonomy.sh
init_env=.devcontainer/scripts/init-env.sh
egress=.devcontainer/scripts/egress-allowlist.sh
devcontainers_guide=docs/guides/devcontainers.md

for f in "$agent_settings" "$agent_codex" "${agent_config_dir}/harnesses.json" "$bot_settings" \
    "$codex_baseline" "$agent_dc" "$agent_autonomy" "$init_env" "$egress" \
    .devcontainer/agent/post-create.sh .devcontainer/agent/post-start.sh \
    .devcontainer/egress-allowlist.txt "$devcontainers_guide"; do
    [ -f "$f" ] || fail "missing ${f}"
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# jsonc_to_json <file> — devcontainer.json is JSONC. Strip // and /* */
# comments outside strings, then trailing commas, so jq can read it.
jsonc_to_json() {
    python3 - "$1" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out, i, n, in_str = [], 0, len(src), False
while i < n:
    c = src[i]
    if in_str:
        out.append(c)
        if c == "\\":
            out.append(src[i + 1]); i += 2; continue
        if c == '"':
            in_str = False
        i += 1
    elif c == '"':
        in_str = True; out.append(c); i += 1
    elif src.startswith("//", i):
        while i < n and src[i] != "\n":
            i += 1
    elif src.startswith("/*", i):
        i = src.index("*/", i) + 2
    else:
        out.append(c); i += 1
text = re.sub(r",(\s*[}\]])", r"\1", "".join(out))
json.dump(json.loads(text), sys.stdout)
PY
}

# ── 1. Single source ────────────────────────────────────────────────────
echo "==> 1. the agent profile has exactly one source"

# find_copies <root> — print every file under <root> (tracked or not, ignoring
# .git and gitignored paths) that duplicates an agent profile file: byte-equal,
# or the same JSON document for the settings, or the same TOML once comments
# and blank lines are stripped. The profile file itself and its verbatim
# template twin are the source, not copies.
find_copies() {
    local root="$1" src canon_json canon_toml f
    canon_json="$(jq -S -c . "${root}/${agent_settings}")"
    canon_toml="$(grep -Ev '^[[:space:]]*(#|$)' "${root}/${agent_codex}")"
    while IFS= read -r f; do
        case "$f" in
        "${agent_config_dir}"/* | "template/[% if devcontainer %].devcontainer[% endif %]/config/agent/"*) continue ;;
        esac
        [ -f "${root}/${f}" ] || continue
        for src in "$agent_settings" "$agent_codex"; do
            if cmp -s "${root}/${src}" "${root}/${f}"; then
                printf '%s (byte copy of %s)\n' "$f" "$src"
            fi
        done
        case "$f" in
        *.json | *.jsonc)
            if [ "$(jq -S -c . "${root}/${f}" 2>/dev/null)" = "$canon_json" ]; then
                printf '%s (JSON copy of %s)\n' "$f" "$agent_settings"
            fi
            ;;
        *.toml)
            if [ "$(grep -Ev '^[[:space:]]*(#|$)' "${root}/${f}")" = "$canon_toml" ]; then
                printf '%s (TOML copy of %s)\n' "$f" "$agent_codex"
            fi
            ;;
        esac
    done < <(git -C "$root" ls-files --cached --others --exclude-standard)
}

copies="$(find_copies "$repo_root")"
[ -z "$copies" ] || fail "the agent profile is duplicated outside ${agent_config_dir}: ${copies}"

# The template twin (harmon-init itself; a generated repo has none) must be
# the SAME source, byte for byte, not a fork.
twin_dir="template/[% if devcontainer %].devcontainer[% endif %]/config/agent"
if [ -d "$twin_dir" ]; then
    for f in claude-managed-settings.json codex-managed-config.toml harnesses.json; do
        cmp -s "${agent_config_dir}/${f}" "${twin_dir}/${f}" || fail "${twin_dir}/${f} is not identical to ${agent_config_dir}/${f}"
    done
fi

# Fixture: a reformatted JSON copy and a re-commented TOML copy are caught.
fixture_repo="${work_dir}/single-source"
mkdir -p "${fixture_repo}/${agent_config_dir}" "${fixture_repo}/elsewhere"
cp "$agent_settings" "$agent_codex" "${fixture_repo}/${agent_config_dir}/"
git -C "$fixture_repo" init -q
[ -z "$(find_copies "$fixture_repo")" ] || fail "single-source fixture reports a copy where there is none"
jq . "$agent_settings" >"${fixture_repo}/elsewhere/settings.json"
{
    echo "# a different header comment"
    cat "$agent_codex"
} >"${fixture_repo}/elsewhere/codex.toml"
fixture_copies="$(find_copies "$fixture_repo")"
grep -q 'elsewhere/settings.json' <<<"$fixture_copies" || fail "single-source check missed a reformatted JSON copy"
grep -q 'elsewhere/codex.toml' <<<"$fixture_copies" || fail "single-source check missed a re-commented TOML copy"

# The agent devcontainer installs from the image copy of that source.
grep -q 'CONFIG_DIR=/usr/local/share/devcontainer-config/agent' "$agent_autonomy" ||
    fail "agent-autonomy.sh no longer installs from the image copy of ${agent_config_dir}"
grep -Eq '^bash \.devcontainer/agent/agent-autonomy\.sh apply$' .devcontainer/agent/post-create.sh ||
    fail "the agent post-create does not install the agent profile (agent-autonomy.sh apply)"
grep -Eq '^bash \.devcontainer/agent/agent-autonomy\.sh verify$' .devcontainer/agent/post-start.sh ||
    fail "the agent post-start does not verify the agent profile (agent-autonomy.sh verify)"

# ── 2. Claude settings ──────────────────────────────────────────────────
echo "==> 2. agent Claude settings: auto mode, no bypass, no ask, the agreed deny list, never looser than bot"

[ "$(jq -r '.permissions.defaultMode' "$agent_settings")" = "auto" ] ||
    fail "agent Claude settings do not set permissions.defaultMode=auto (the prompt-free mode the ADR chose)"
[ "$(jq -r '.permissions.disableBypassPermissionsMode' "$agent_settings")" = "disable" ] ||
    fail "agent Claude settings do not set permissions.disableBypassPermissionsMode=disable"
[ "$(jq -r '.permissions.disableAutoMode // "unset"' "$agent_settings")" = "unset" ] ||
    fail "agent Claude settings set disableAutoMode — that would strand an unattended run"
[ "$(jq -r '.allowManagedPermissionRulesOnly' "$agent_settings")" = "true" ] ||
    fail "agent Claude settings do not set allowManagedPermissionRulesOnly — a repository's own ask rules would stall the run"
[ "$(jq '[.. | objects | select(has("ask")) | .ask[]?] | length' "$agent_settings")" = "0" ] ||
    fail "agent Claude settings contain an ask rule — an ask prompts in every mode and stalls an unattended run"
[ "$(jq -r '.skipDangerousModePermissionPrompt // "unset"' "$agent_settings")" = "unset" ] ||
    fail "agent Claude settings carry the bot's skipDangerousModePermissionPrompt"

required_deny='Bash(gh pr merge *)
Bash(gh release *)
Bash(gh repo delete *)
Bash(gh repo edit *)
Bash(gh repo rename *)
Bash(gh secret *)
Bash(gh variable set *)
Bash(gh variable delete *)
Bash(gh workflow run *)
Bash(gh workflow enable *)
Bash(gh workflow disable *)
Bash(gh api -X*)
Bash(gh api * -X*)
Bash(gh api --method*)
Bash(gh api * --method*)
Bash(gh api --input*)
Bash(gh api * --input*)
Bash(gh api -f*)
Bash(gh api * -f*)
Bash(gh api -F*)
Bash(gh api * -F*)
Bash(gh api --field*)
Bash(gh api * --field*)
Bash(gh api --raw-field*)
Bash(gh api * --raw-field*)
Bash(git push --force*)
Bash(git push * --force*)
Bash(git push -f*)
Bash(git push * -f*)
Bash(git push * +*)
Bash(git push * main)
Bash(git push * *:main)
Bash(task release*)
Bash(task secret*)
Bash(task codex:gate:disable*)
Bash(op)
Bash(op *)
Read(**/.env*)
Read(!**/.env.example)'
agent_deny="$(jq -r '.permissions.deny[]' "$agent_settings")"
while IFS= read -r rule; do
    grep -Fxq -- "$rule" <<<"$agent_deny" || fail "agent Claude deny list is missing the agreed rule '${rule}'"
done <<<"$required_deny"
# gitignore negation only carves out of rules listed BEFORE it.
[ "$(jq -r '.permissions.deny | last' "$agent_settings")" = "Read(!**/.env.example)" ] ||
    fail "the .env.example carve-out must be the last deny rule (a negation only applies to rules before it)"

# rule_prefix <rule> — the literal command prefix a Bash(...) rule matches:
# `Bash(git:*)` (legacy) and `Bash(git status *)` both reduce to the words
# before the wildcard. Non-Bash rules print nothing.
rule_prefix() {
    local spec
    case "$1" in
    Bash\(*\)) spec="${1#Bash(}" && spec="${spec%)}" ;;
    *) return 0 ;;
    esac
    spec="${spec%%\**}"
    spec="${spec%:}"
    spec="${spec% }"
    printf '%s' "$spec"
}

# prefix_covers <broad> <narrow> — broad matches everything narrow does:
# same words, or narrow extends broad at a word boundary.
prefix_covers() {
    [ -n "$1" ] || return 1
    [ "$2" = "$1" ] && return 0
    case "$2" in "$1 "*) return 0 ;; esac
    return 1
}

# check_never_looser <agent-settings> <bot-settings> — print every agent allow
# rule that a bot deny rule covers, or that no bot allow rule covers.
check_never_looser() {
    local a b ap bp covered
    while IFS= read -r a; do
        ap="$(rule_prefix "$a")"
        [ -n "$ap" ] || {
            printf 'non-Bash allow rule %s (bot allows no such tool rule)\n' "$a"
            continue
        }
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            bp="$(rule_prefix "$b")"
            if prefix_covers "$bp" "$ap" || prefix_covers "$ap" "$bp"; then
                printf 'agent allows %s, which bot denies (%s)\n' "$a" "$b"
            fi
        done < <(jq -r '.permissions.deny // [] | .[]' "$2")
        covered=0
        while IFS= read -r b; do
            prefix_covers "$(rule_prefix "$b")" "$ap" && covered=1 && break
        done < <(jq -r '.permissions.allow // [] | .[]' "$2")
        [ "$covered" -eq 1 ] || printf 'agent allows %s, which bot does not allow\n' "$a"
    done < <(jq -r '.permissions.allow[]' "$1")
}

looser="$(check_never_looser "$agent_settings" "$bot_settings")"
[ -z "$looser" ] || fail "agent Claude settings are looser than bot: ${looser}"

# Fixtures: a bot deny that covers an agent allow, and an agent allow bot
# never grants, are both reported.
jq '.permissions.deny = ["Bash(git push:*)"]' "$bot_settings" >"${work_dir}/bot-deny.json"
grep -q 'which bot denies' <<<"$(check_never_looser "$agent_settings" "${work_dir}/bot-deny.json")" ||
    fail "never-looser check missed an agent allow rule that bot denies"
jq '.permissions.allow += ["Bash(curl *)"]' "$agent_settings" >"${work_dir}/agent-wider.json"
grep -q 'Bash(curl \*), which bot does not allow' <<<"$(check_never_looser "${work_dir}/agent-wider.json" "$bot_settings")" ||
    fail "never-looser check missed an agent allow rule bot does not grant"

# ── 3. Codex config ─────────────────────────────────────────────────────
echo "==> 3. agent Codex config: workspace-write, never danger-full-access, parity with the baseline"

! grep -q 'danger-full-access' <(grep -Ev '^[[:space:]]*#' "$agent_codex") ||
    fail "agent Codex config enables danger-full-access"
grep -Eq '^sandbox_mode = "workspace-write"$' "$agent_codex" || fail "agent Codex sandbox_mode is not workspace-write"
grep -Eq '^approval_policy = "never"$' "$agent_codex" || fail "agent Codex approval_policy is not never (an unattended run cannot answer a prompt)"

# Every line but approval_policy and the [sandbox_workspace_write] table must
# match the shared baseline — the same structural parity bot's config keeps.
strip_agent_overrides() {
    grep -Ev '^[[:space:]]*#' "$1" |
        grep -Ev '^[[:space:]]*$' |
        grep -Ev '^[[:space:]]*approval_policy[[:space:]]*=' |
        grep -Ev '^\[sandbox_workspace_write\]$' |
        grep -Ev '^[[:space:]]*network_access[[:space:]]*='
}
diff <(strip_agent_overrides "$codex_baseline") <(strip_agent_overrides "$agent_codex") >/dev/null ||
    fail "agent Codex config diverges from ${codex_baseline} beyond approval_policy and [sandbox_workspace_write]"
sed 's/^approvals_reviewer = .*/approvals_reviewer = "user"/' "$agent_codex" >"${work_dir}/codex-drift.toml"
if diff <(strip_agent_overrides "$codex_baseline") <(strip_agent_overrides "${work_dir}/codex-drift.toml") >/dev/null; then
    fail "Codex parity check failed to notice a divergent approvals_reviewer"
fi

# ── 4. Harness refusal ──────────────────────────────────────────────────
echo "==> 4. harness coverage and refusal under the agent marker"

bash "$agent_autonomy" coverage >/dev/null || fail "agent-autonomy.sh coverage failed (run it for the details)"

# The dispatcher needs only these tools; a curated PATH keeps the real
# harness binaries this environment may have installed out of the fixture.
safe_bin="${work_dir}/safe-bin"
mkdir -p "$safe_bin"
for tool in bash awk jq sha256sum install chmod readlink dirname git mktemp cat sudo; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] || continue
    ln -s "$tool_path" "${safe_bin}/${tool}"
done
fake_bin="${work_dir}/fake-bin"
mkdir -p "$fake_bin"
for exe in claude codex opencode agy; do
    printf '#!/bin/sh\nexit 0\n' >"${fake_bin}/${exe}"
    chmod +x "${fake_bin}/${exe}"
done
fake_etc="${work_dir}/etc"
mkdir -p "${fake_etc}/claude-code" "${fake_etc}/codex"
echo '{}' >"${fake_etc}/claude-code/managed-settings.json"
run_autonomy() {
    AGENT_AUTONOMY_CONFIG_DIR="${repo_root}/${agent_config_dir}" \
        AGENT_AUTONOMY_REGISTRY="${repo_root}/agent-registry.json" \
        AGENT_AUTONOMY_CLAUDE_MANAGED="${fake_etc}/claude-code/managed-settings.json" \
        AGENT_AUTONOMY_CODEX_MANAGED="${fake_etc}/codex/managed_config.toml" \
        PATH="${fake_bin}:${safe_bin}" bash "$agent_autonomy" "$@"
}

if FOREMAN_DEVCONTAINER=bot run_autonomy apply >/dev/null 2>&1; then
    fail "agent-autonomy.sh apply ran outside the agent posture (FOREMAN_DEVCONTAINER=bot)"
fi
if FOREMAN_DEVCONTAINER="" run_autonomy verify >/dev/null 2>&1; then
    fail "agent-autonomy.sh verify ran outside the agent posture (FOREMAN_DEVCONTAINER unset)"
fi
[ -x "${fake_bin}/opencode" ] || fail "agent-autonomy.sh touched a harness outside the agent posture"

FOREMAN_DEVCONTAINER=agent run_autonomy apply >/dev/null || fail "agent-autonomy.sh apply failed under the agent marker"
cmp -s "$agent_settings" "${fake_etc}/claude-code/managed-settings.json" || fail "apply did not install the agent Claude settings"
cmp -s "$agent_codex" "${fake_etc}/codex/managed_config.toml" || fail "apply did not install the agent Codex config"
[ ! -x "${fake_bin}/opencode" ] || fail "apply did not refuse opencode (no agent-capable configuration)"
[ ! -x "${fake_bin}/agy" ] || fail "apply did not refuse agy (no agent-capable configuration)"
[ -x "${fake_bin}/claude" ] && [ -x "${fake_bin}/codex" ] || fail "apply refused an agent-capable harness"
FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null || fail "verify failed right after apply"

chmod +x "${fake_bin}/opencode"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed with a refused harness (opencode) executable again"
fi
chmod -x "${fake_bin}/opencode"
echo '{"permissions":{"defaultMode":"bypassPermissions"}}' >"${fake_etc}/claude-code/managed-settings.json"
if FOREMAN_DEVCONTAINER=agent run_autonomy verify >/dev/null 2>&1; then
    fail "verify passed with drifted Claude managed settings"
fi

# A registry slug with no bucket fails coverage.
jq '.harnesses += [{slug: "brand-new-harness"}]' agent-registry.json >"${work_dir}/registry-new.json"
if AGENT_AUTONOMY_REGISTRY="${work_dir}/registry-new.json" bash "$agent_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage passed with a registry slug that is neither supported, aliased, nor refused"
fi

# ── 5. Env allowlist ────────────────────────────────────────────────────
echo "==> 5. init-env.sh --profile agent admits the agent PAT and fails closed on everything else"

env_dir="${work_dir}/env"
mkdir -p "$env_dir"
git -C "$env_dir" init -q
# Host env carries the bot's and operator's credentials too; only the agent's
# may land in the file.
(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" AGENT_GH_TOKEN=agent-pat \
    CLAUDE_CODE_OAUTH_TOKEN=oauth GH_TOKEN=bot-pat FOREMAN_AGENT_GH_TOKEN=foreman-pat \
    TS_AUTHKEY=ts OP_SERVICE_ACCOUNT_TOKEN=op ANTHROPIC_API_KEY=anthropic \
    bash "${repo_root}/${init_env}" --profile agent agent.env AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN) >/dev/null 2>&1 ||
    fail "init-env.sh --profile agent failed on a clean allow-list"
grep -qx 'AGENT_GH_TOKEN=agent-pat' "${env_dir}/agent.env" || fail "the agent env-file did not admit AGENT_GH_TOKEN"
for leaked in GH_TOKEN FOREMAN_AGENT_GH_TOKEN TS_AUTHKEY OP_SERVICE_ACCOUNT_TOKEN ANTHROPIC_API_KEY; do
    ! grep -q "^${leaked}=" "${env_dir}/agent.env" || fail "the agent env-file admitted ${leaked}"
done

for forbidden in GH_TOKEN FOREMAN_AGENT_GH_TOKEN TS_AUTHKEY OP_SERVICE_ACCOUNT_TOKEN ANTHROPIC_API_KEY AGENT_DECK_TELEGRAM_KEY; do
    rm -f "${env_dir}/guard.env"
    if (cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
        bash "${repo_root}/${init_env}" --profile agent guard.env AGENT_GH_TOKEN "$forbidden") >/dev/null 2>&1; then
        fail "init-env.sh --profile agent accepted ${forbidden} on its allow-list"
    fi
    [ ! -e "${env_dir}/guard.env" ] || fail "init-env.sh wrote the env-file before failing closed on ${forbidden}"
    printf '%s=stale\n' "$forbidden" >"${env_dir}/stale.env"
    if (cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
        bash "${repo_root}/${init_env}" --profile agent stale.env AGENT_GH_TOKEN) >/dev/null 2>&1; then
        fail "init-env.sh --profile agent accepted an env-file already holding ${forbidden}"
    fi
    grep -qx "${forbidden}=stale" "${env_dir}/stale.env" || fail "init-env.sh rewrote the env-file while failing closed on ${forbidden}"
done
# A bare NAME line makes Docker pass the host's value through.
printf 'GH_TOKEN\n' >"${env_dir}/bare.env"
if (cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
    bash "${repo_root}/${init_env}" --profile agent bare.env AGENT_GH_TOKEN) >/dev/null 2>&1; then
    fail "init-env.sh --profile agent accepted a bare pass-through line"
fi
# Failure messages carry names, never values.
printf 'GH_TOKEN=super-secret-value\n' >"${env_dir}/value.env"
value_out="$(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" \
    bash "${repo_root}/${init_env}" --profile agent value.env AGENT_GH_TOKEN 2>&1 || true)"
! grep -q 'super-secret-value' <<<"$value_out" || fail "init-env.sh printed a secret value while failing closed"
# The bot and dev profiles evict the agent PAT.
printf 'AGENT_GH_TOKEN=agent-pat\nGH_TOKEN=bot\n' >"${env_dir}/bot.env"
(cd "$env_dir" && env -i PATH="$PATH" HOME="$env_dir" bash "${repo_root}/${init_env}" bot.env GH_TOKEN) >/dev/null 2>&1 ||
    fail "init-env.sh failed for the bot allow-list"
! grep -q '^AGENT_GH_TOKEN=' "${env_dir}/bot.env" || fail "the bot env-file kept AGENT_GH_TOKEN"

# The agent devcontainer invokes that mode, with admissible names only, and
# carries no 1Password or Tailscale.
agent_cfg="$(jsonc_to_json "$agent_dc")"
init_cmd="$(jq -r '.initializeCommand' <<<"$agent_cfg")"
case "$init_cmd" in
"bash .devcontainer/scripts/init-env.sh --profile agent .devcontainer/agent/devcontainer.env "*) ;;
*) fail "the agent initializeCommand does not run init-env.sh --profile agent on the agent env-file: ${init_cmd}" ;;
esac
admissible=" AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY "
for name in ${init_cmd#bash .devcontainer/scripts/init-env.sh --profile agent .devcontainer/agent/devcontainer.env }; do
    case "$admissible" in
    *" ${name} "*) ;;
    *) fail "the agent initializeCommand allow-lists ${name}" ;;
    esac
done
[ "$(jq '[.features // {} | keys[] | select(test("1password|tailscale"; "i"))] | length' <<<"$agent_cfg")" = "0" ] ||
    fail "the agent devcontainer installs a 1Password or Tailscale feature"
[ "$(jq -r '.containerEnv.FOREMAN_DEVCONTAINER' <<<"$agent_cfg")" = "agent" ] ||
    fail "the agent devcontainer does not set containerEnv.FOREMAN_DEVCONTAINER=agent"
for alias_var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    [ "$(jq -r --arg v "$alias_var" '.containerEnv[$v] // "<absent>"' <<<"$agent_cfg")" = "" ] ||
        fail "the agent devcontainer does not blank ${alias_var} (an env token would outrank the agent login)"
done

# ── 6. Docker ───────────────────────────────────────────────────────────
echo "==> 6. no Docker socket, and Docker-in-Docker only with the documented opt-in"

# docker_violations <config-json> — print why a config breaks the Docker rule.
docker_violations() {
    local cfg="$1" dind marker
    if jq -e '[((.mounts // [])[] | tostring), (.runArgs // [])[]] | any(test("docker\\.sock"))' <<<"$cfg" >/dev/null; then
        echo "mounts the host Docker socket"
    fi
    if jq -e '[.features // {} | keys[] | select(test("docker-outside-of-docker|docker-from-docker"))] | length > 0' <<<"$cfg" >/dev/null; then
        echo "uses a docker-outside-of-docker feature (the host daemon)"
    fi
    dind="$(jq '[.features // {} | keys[] | select(test("docker-in-docker"))] | length' <<<"$cfg")"
    marker="$(jq -r '.containerEnv.HARMON_AGENT_DOCKER // ""' <<<"$cfg")"
    if [ "$dind" != "0" ] && [ "$marker" != "dind" ]; then
        echo "installs Docker-in-Docker without the HARMON_AGENT_DOCKER=dind opt-in marker"
    fi
    if [ "$dind" = "0" ] && [ -n "$marker" ]; then
        echo "sets HARMON_AGENT_DOCKER='${marker}' without the Docker-in-Docker feature"
    fi
}
violations="$(docker_violations "$agent_cfg")"
[ -z "$violations" ] || fail "the agent devcontainer ${violations}"
grep -q 'HARMON_AGENT_DOCKER' "$devcontainers_guide" ||
    fail "${devcontainers_guide} does not document the agent Docker-in-Docker opt-in (HARMON_AGENT_DOCKER)"

dind_cfg="$(jq '.features["ghcr.io/devcontainers/features/docker-in-docker:2"] = {}' <<<"$agent_cfg")"
grep -q 'without the HARMON_AGENT_DOCKER=dind opt-in' <<<"$(docker_violations "$dind_cfg")" ||
    fail "Docker check missed Docker-in-Docker without the opt-in"
[ -z "$(docker_violations "$(jq '.containerEnv.HARMON_AGENT_DOCKER = "dind"' <<<"$dind_cfg")")" ] ||
    fail "Docker check rejected the documented Docker-in-Docker opt-in"
sock_cfg="$(jq '.mounts += ["source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"] | .containerEnv.HARMON_AGENT_DOCKER = "dind"' <<<"$dind_cfg")"
grep -q 'host Docker socket' <<<"$(docker_violations "$sock_cfg")" ||
    fail "Docker check missed a host Docker socket mount (even with the opt-in)"

# ── 7. Egress ───────────────────────────────────────────────────────────
echo "==> 7. egress allowlist parses, resolves, refuses an allow-nothing filter or an over-broad literal or meta range, and is applied first from a root-owned snapshot"

bash "$egress" hosts >/dev/null || fail "the shared egress allowlist does not parse"
for required in @github-meta github.com api.github.com api.anthropic.com api.openai.com chatgpt.com registry.npmjs.org pypi.org files.pythonhosted.org; do
    grep -Fxq -- "$required" <(bash "$egress" hosts) || fail "the shared egress allowlist is missing ${required}"
done

stub_resolver="${work_dir}/resolve"
printf '#!/bin/sh\ncase "$1" in\n good.example) echo 192.0.2.10; echo 192.0.2.11 ;;\n *) exit 0 ;;\nesac\n' >"$stub_resolver"
chmod +x "$stub_resolver"
printf '{"git":["140.82.112.0/20","2a0a:a440::/29"],"web":["140.82.112.0/20"],"api":[],"packages":["185.199.108.0/22"]}\n' >"${work_dir}/meta.json"
printf '@github-meta\ngood.example # trailing comment\ndead.example\n198.51.100.0/24\n' >"${work_dir}/list.txt"
plan="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_RESOLVER="$stub_resolver" EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" \
    bash "$egress" plan 2>/dev/null)" || fail "egress plan failed on a valid fixture"
expected_plan='140.82.112.0/20
185.199.108.0/22
192.0.2.10
192.0.2.11
198.51.100.0/24'
[ "$plan" = "$expected_plan" ] || fail "egress plan resolved the fixture wrong: ${plan}"

printf 'dead.example\n' >"${work_dir}/dead.txt"
if EGRESS_ALLOWLIST_SHARED="${work_dir}/dead.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_RESOLVER="$stub_resolver" bash "$egress" plan >/dev/null 2>&1; then
    fail "egress plan accepted a list that resolves to nothing (it would deny all egress silently)"
fi
printf 'not a host!\n' >"${work_dir}/bad.txt"
if EGRESS_ALLOWLIST_SHARED="${work_dir}/bad.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent bash "$egress" hosts >/dev/null 2>&1; then
    fail "egress hosts accepted a malformed entry"
fi
printf 'extra.example\n' >"${work_dir}/local.txt"
grep -Fxq extra.example <(EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL="${work_dir}/local.txt" bash "$egress" hosts) ||
    fail "egress hosts ignored the per-repo local list"

# An over-broad literal is one line that allows every destination: refused
# in either list, naming the line, and never reaching plan. A /16 (the
# widest allowed), a /24 and a bare address are accepted.
for broad in 0.0.0.0/0 0.0.0.0/8 0.0.0.0/32 0.0.0.0 10.0.0.0/8 128.0.0.0/1 172.16.0.0/12 192.0.0.0/15; do
    printf 'good.example\n%s\n' "$broad" >"${work_dir}/broad.txt"
    for which in shared local; do
        if [ "$which" = shared ]; then
            broad_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/broad.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
                EGRESS_RESOLVER="$stub_resolver" bash "$egress" plan 2>&1)" &&
                fail "egress plan accepted the over-broad entry ${broad} in the shared list"
        else
            broad_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/list.txt" EGRESS_ALLOWLIST_LOCAL="${work_dir}/broad.txt" \
                EGRESS_RESOLVER="$stub_resolver" EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" bash "$egress" plan 2>&1)" &&
                fail "egress plan accepted the over-broad entry ${broad} in the local list"
        fi
        grep -Fq "broad.txt:2: '${broad}'" <<<"$broad_out" ||
            fail "the refusal of ${broad} (${which} list) does not name the line: ${broad_out}"
    done
done
printf '172.16.0.0/16\n198.51.100.0/24\n203.0.113.7/32\n203.0.113.8\n' >"${work_dir}/narrow.txt"
[ "$(EGRESS_ALLOWLIST_SHARED="${work_dir}/narrow.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent bash "$egress" plan 2>/dev/null)" = "$(printf '172.16.0.0/16\n198.51.100.0/24\n203.0.113.7/32\n203.0.113.8')" ] ||
    fail "egress plan refused or altered a /16, /24, /32 or bare-address entry"

# A range fetched through @github-meta becomes a rule unreviewed, so it gets
# the same refusal: a meta response carrying 0.0.0.0/0 or a /8 fails the plan
# (and so apply), naming the source and the range, instead of being skipped.
printf '@github-meta\n' >"${work_dir}/meta-only.txt"
for broad in 0.0.0.0/0 10.0.0.0/8; do
    printf '{"git":["140.82.112.0/20"],"web":["%s"],"api":[],"packages":["185.199.108.0/22"]}\n' "$broad" >"${work_dir}/meta-broad.json"
    broad_out="$(EGRESS_ALLOWLIST_SHARED="${work_dir}/meta-only.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
        EGRESS_GITHUB_META_FILE="${work_dir}/meta-broad.json" bash "$egress" plan 2>&1)" &&
        fail "egress plan accepted the over-broad @github-meta range ${broad}"
    grep -Fq "@github-meta: '${broad}'" <<<"$broad_out" ||
        fail "the refusal of the @github-meta range ${broad} does not name its source and range: ${broad_out}"
done
[ "$(EGRESS_ALLOWLIST_SHARED="${work_dir}/meta-only.txt" EGRESS_ALLOWLIST_LOCAL=/nonexistent \
    EGRESS_GITHUB_META_FILE="${work_dir}/meta.json" bash "$egress" plan 2>/dev/null)" = "$(printf '140.82.112.0/20\n185.199.108.0/22')" ] ||
    fail "egress plan refused or altered a normal @github-meta response"

# The snapshot: the applier and both lists copied out of the checkout, and a
# later edit to the checkout changes nothing the snapshot applies.
# EGRESS_SNAPSHOT_DIR stands in for the root-owned directory.
snap_checkout="${work_dir}/snap-checkout/.devcontainer"
snap_dir="${work_dir}/snap-root/harmon-egress"
mkdir -p "${snap_checkout}/scripts"
cp "$egress" "${snap_checkout}/scripts/egress-allowlist.sh"
printf 'good.example\n198.51.100.0/24\n' >"${snap_checkout}/egress-allowlist.txt"
printf '203.0.113.0/24\n' >"${snap_checkout}/egress-allowlist.local.txt"
EGRESS_SNAPSHOT_DIR="$snap_dir" bash "${snap_checkout}/scripts/egress-allowlist.sh" snapshot >/dev/null ||
    fail "egress snapshot failed on a valid checkout"
cmp -s "$egress" "${snap_dir}/scripts/egress-allowlist.sh" || fail "the snapshot does not carry the applier"
[ -x "${snap_dir}/scripts/egress-allowlist.sh" ] || fail "the snapshot applier is not executable"
snap_plan_before="$(EGRESS_RESOLVER="$stub_resolver" bash "${snap_dir}/scripts/egress-allowlist.sh" plan 2>/dev/null)"
[ "$snap_plan_before" = "$(printf '192.0.2.10\n192.0.2.11\n198.51.100.0/24\n203.0.113.0/24')" ] ||
    fail "the snapshot applier did not resolve the snapshot's own lists: ${snap_plan_before}"
printf 'good.example\n198.51.100.0/24\n192.0.2.0/24\n' >"${snap_checkout}/egress-allowlist.txt"
printf '203.0.113.0/24\n100.64.0.0/16\n' >"${snap_checkout}/egress-allowlist.local.txt"
printf '#!/bin/sh\necho 0.0.0.0/0\n' >"${snap_checkout}/scripts/egress-allowlist.sh"
[ "$(EGRESS_RESOLVER="$stub_resolver" bash "${snap_dir}/scripts/egress-allowlist.sh" plan 2>/dev/null)" = "$snap_plan_before" ] ||
    fail "editing the checkout's lists after the snapshot changed what the snapshot applies"
# A re-snapshot drops a local list the checkout no longer has, and refuses a
# list apply would refuse without touching the good snapshot.
cp "$egress" "${snap_checkout}/scripts/egress-allowlist.sh"
rm "${snap_checkout}/egress-allowlist.local.txt"
EGRESS_SNAPSHOT_DIR="$snap_dir" bash "${snap_checkout}/scripts/egress-allowlist.sh" snapshot >/dev/null ||
    fail "egress re-snapshot failed on a valid checkout"
[ ! -e "${snap_dir}/egress-allowlist.local.txt" ] || fail "a re-snapshot kept a local list the checkout no longer has"
snap_good="$(cat "${snap_dir}/egress-allowlist.txt")"
printf '0.0.0.0/0\n' >>"${snap_checkout}/egress-allowlist.txt"
if EGRESS_SNAPSHOT_DIR="$snap_dir" bash "${snap_checkout}/scripts/egress-allowlist.sh" snapshot >/dev/null 2>&1; then
    fail "egress snapshot accepted an over-broad list"
fi
[ "$(cat "${snap_dir}/egress-allowlist.txt")" = "$snap_good" ] || fail "a refused snapshot overwrote the good one"

# The lifecycle: post-create snapshots, then applies FROM the snapshot before
# anything else; post-start applies only the snapshot and never reads the
# checkout's applier.
snap_applier=/usr/local/share/harmon-egress/scripts/egress-allowlist.sh
grep -q "^SNAPSHOT_DIR=${snap_applier%/scripts/*}\$" "$egress" ||
    fail "egress-allowlist.sh does not snapshot to ${snap_applier%/scripts/*}, the path the lifecycle applies from"
[ "$(grep -Ev '^[[:space:]]*(#|$)' .devcontainer/agent/post-create.sh | sed -n 's/^\(bash .*\)$/\1/p' | head -n 2)" = "bash .devcontainer/scripts/egress-allowlist.sh snapshot
bash ${snap_applier} apply" ] ||
    fail "the agent post-create does not snapshot the egress lists and apply the snapshot before anything else"
[ "$(grep -Ev '^[[:space:]]*(#|$)' .devcontainer/agent/post-start.sh | sed -n 's/^\(bash .*\)$/\1/p' | head -n 1)" = "bash ${snap_applier} apply" ] ||
    fail "the agent post-start does not apply the egress snapshot before anything else"
! grep -Ev '^[[:space:]]*#' .devcontainer/agent/post-start.sh | grep -q 'egress-allowlist\.txt\|\.devcontainer/scripts/egress-allowlist\.sh' ||
    fail "the agent post-start reads the checkout's egress applier or lists (only the root-owned snapshot may be applied at start)"
jq -e '.runArgs | index("--cap-add=NET_ADMIN")' <<<"$agent_cfg" >/dev/null ||
    fail "the agent devcontainer lacks --cap-add=NET_ADMIN, so the egress filter cannot be installed"

echo "==> agent posture unit tests passed."
