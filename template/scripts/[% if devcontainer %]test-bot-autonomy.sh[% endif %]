#!/usr/bin/env bash
set -euo pipefail

# Unit tests for .devcontainer/scripts/bot-autonomy.sh and its modules — the
# registry-completeness and structural-parity gates from
# openspec/changes/bot-autonomy-bootstrap (tasks 1.3, 1.4, 2.3), plus
# behavioral fixtures for the per-harness modules not already covered by
# scripts/devcontainer-assert.sh's unit mode. No container, no real
# secrets — every fixture uses a scratch HOME/PATH/config file, never the
# repository's own /etc or ~/.gemini state.
#
# Deliberately carries NO devcontainer paths: filter in
# .github/workflows/devcontainer-build.yml: it is wired into `task verify`
# (build.yml's aggregate gate, required unconditionally), so a registry
# change that adds a harness slug with no coverage entry fails an
# already-required check regardless of which paths a PR touches. See
# design.md - Risks ("Forgetting to add oh-my-pi's unsupported entry...").

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
bot_autonomy="${repo_root}/.devcontainer/scripts/bot-autonomy.sh"
module_dir="${repo_root}/.devcontainer/config/bot-autonomy"
registry="${repo_root}/agent-registry.json"
codex_baseline="${repo_root}/.devcontainer/config/codex-managed-config.toml"
codex_bot="${repo_root}/.devcontainer/config/codex-managed-config.bot.toml"

[ -x "$bot_autonomy" ] || fail "bot-autonomy.sh missing or not executable at ${bot_autonomy}"
[ -d "$module_dir" ] || fail "bot-autonomy module directory missing at ${module_dir}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# verify/coverage now also check the REVERSE direction: every module file's
# executable, if installed, must be reachable from the current registry
# (task added in challenge round 3). A test environment that already has
# the real claude/codex/agy/opencode binaries on PATH (this repo's own bot
# devcontainer, for instance) would otherwise trip that check the moment a
# narrow, single-slug fixture registry is used below — an environment
# accident, not something under test. Directory-level exclusion cannot fix
# this: on a merged-/usr system /bin and /usr/bin are the same directory,
# so excluding it to hide claude/codex/opencode would also hide jq. Instead
# build ONE curated bin directory, symlinking only the tools bot-autonomy.sh
# and its modules actually shell out to, and use that as SAFE_PATH —
# claude/codex/agy/opencode are never among them, by construction.
safe_bin="${work_dir}/safe-bin"
mkdir -p "$safe_bin"
for tool in bash jq sha256sum git mktemp mv chmod install mkdir basename dirname cmp rm; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] && ln -sf "$tool_path" "${safe_bin}/${tool}"
done
SAFE_PATH="$safe_bin"

echo "==> 1. coverage passes against the real registry and tables"
BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" coverage >/dev/null ||
    fail "bot-autonomy.sh coverage failed against the real agent-registry.json"

echo "==> 1b. apply/verify/coverage all fail loudly when the registry cannot be read"
# Regression guard: a `while read < <(cmd)` pattern silently reports success
# when `cmd` fails, because the exit status of a while loop whose body never
# runs is 0, not the substituted command's — exactly the silent-failure shape
# this whole change exists to eliminate. Each subcommand must exit non-zero
# here, not fall through to its "passed" message.
for sub in apply verify coverage; do
    if BOT_AUTONOMY_REGISTRY="${work_dir}/does-not-exist.json" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
        bash "$bot_autonomy" "$sub" >/dev/null 2>&1; then
        fail "bot-autonomy.sh ${sub} exited 0 with an unreadable agent-registry.json"
    fi
done

echo "==> 1c. an alias dispatches its target module even if the target's own slug is absent from the registry"
orphan_registry="${work_dir}/registry-orphan-target.json"
jq -n '{harnesses: [{slug: "claude-code-qwen"}]}' >"$orphan_registry"
orphan_bin="${work_dir}/orphan-bin"
mkdir -p "$orphan_bin"
printf '#!/bin/sh\nexit 0\n' >"${orphan_bin}/claude"
chmod +x "${orphan_bin}/claude"
orphan_managed="${work_dir}/orphan-claude-managed.json"
echo '{}' >"$orphan_managed"
BOT_AUTONOMY_REGISTRY="$orphan_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    BOT_AUTONOMY_CLAUDE_MANAGED="$orphan_managed" PATH="${orphan_bin}:${SAFE_PATH}" \
    bash "$bot_autonomy" apply >/dev/null
jq -e '.permissions.defaultMode == "bypassPermissions"' "$orphan_managed" >/dev/null ||
    fail "apply did not dispatch the claude-code module via an alias whose target slug is absent from the registry"

echo "==> 2. coverage fails an uncovered slug"
uncovered_registry="${work_dir}/registry-uncovered.json"
jq -n '{harnesses: [{slug: "totally-new-harness"}]}' >"$uncovered_registry"
if BOT_AUTONOMY_REGISTRY="$uncovered_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail on an uncovered registry slug"
fi

echo "==> 2b. coverage fails an alias whose target has no module"
broken_alias_dir="${work_dir}/broken-alias-config"
mkdir -p "$broken_alias_dir"
cp "${module_dir}"/*.sh "${module_dir}/unsupported.json" "$broken_alias_dir/"
jq -n '{"claude-code-broken": "totally-nonexistent-module"}' >"${broken_alias_dir}/aliases.json"
broken_alias_registry="${work_dir}/registry-broken-alias.json"
jq -n '{harnesses: [{slug: "claude-code-broken"}]}' >"$broken_alias_registry"
if BOT_AUTONOMY_REGISTRY="$broken_alias_registry" BOT_AUTONOMY_CONFIG_DIR="$broken_alias_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail when an alias's target has no module (misspelled or removed)"
fi

echo "==> 3. coverage fails a doubly-covered slug"
double_dir="${work_dir}/double-config"
mkdir -p "$double_dir"
cp "${module_dir}"/*.sh "$double_dir/"
cp "${module_dir}/unsupported.json" "$double_dir/"
jq '. + {"claude-code": "codex-cli"}' "${module_dir}/aliases.json" >"${double_dir}/aliases.json"
double_registry="${work_dir}/registry-double.json"
jq -n '{harnesses: [{slug: "claude-code"}]}' >"$double_registry"
if BOT_AUTONOMY_REGISTRY="$double_registry" BOT_AUTONOMY_CONFIG_DIR="$double_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail when a slug is both a module and an alias"
fi

echo "==> 4. coverage fails a malformed unsupported executable field"
malformed_dir="${work_dir}/malformed-config"
mkdir -p "$malformed_dir"
cp "${module_dir}"/*.sh "${module_dir}/aliases.json" "$malformed_dir/"
jq -n '{"broken-harness": {"executable": 123, "reason": "not a string or null"}}' >"${malformed_dir}/unsupported.json"
malformed_registry="${work_dir}/registry-malformed.json"
jq -n '{harnesses: [{slug: "broken-harness"}]}' >"$malformed_registry"
if BOT_AUTONOMY_REGISTRY="$malformed_registry" BOT_AUTONOMY_CONFIG_DIR="$malformed_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail on an unsupported entry whose executable is neither a string nor null"
fi

# Omitting the field entirely is distinct from an explicit `null` (a real
# "no binary at all" entry like claude-code-action) and must also fail.
omitted_dir="${work_dir}/omitted-config"
mkdir -p "$omitted_dir"
cp "${module_dir}"/*.sh "${module_dir}/aliases.json" "$omitted_dir/"
jq -n '{"broken-harness-2": {"reason": "executable field omitted entirely"}}' >"${omitted_dir}/unsupported.json"
omitted_registry="${work_dir}/registry-omitted.json"
jq -n '{harnesses: [{slug: "broken-harness-2"}]}' >"$omitted_registry"
if BOT_AUTONOMY_REGISTRY="$omitted_registry" BOT_AUTONOMY_CONFIG_DIR="$omitted_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not fail on an unsupported entry that omits its executable field entirely"
fi

echo "==> 5. verify fails when an unsupported harness's named executable becomes installed"
# Real registry/tables, but a scratch PATH exposing only ONE fake binary at a
# time — module executables (claude/codex/agy/opencode) are absent from this
# PATH, so the four real modules' own apply/verify are never reached; only
# the unsupported-bucket check is exercised.
assert_unsupported_fails() {
    local slug="$1" fake_exe="$2"
    local fake_bin_dir="${work_dir}/fake-bin-${fake_exe}"
    mkdir -p "$fake_bin_dir"
    printf '#!/bin/sh\nexit 0\n' >"${fake_bin_dir}/${fake_exe}"
    chmod +x "${fake_bin_dir}/${fake_exe}"
    local out rc=0
    out="$(BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
        PATH="${fake_bin_dir}:${SAFE_PATH}" bash "$bot_autonomy" verify 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || fail "verify did not fail with a fake '${fake_exe}' installed for unsupported slug '${slug}'"
    case "$out" in
    *"$slug"*) ;;
    *) fail "verify's failure for '${fake_exe}' did not name the harness slug '${slug}': ${out}" ;;
    esac
}
# Fixtures are named after each entry's EXECUTABLE field, not its slug —
# qwen-code's binary is "qwen", cline's published @cline/cli package's binary
# is "clite" (not "cline"). A fixture using the slug itself would never be
# found by `command -v` and would silently fail to exercise this at all.
assert_unsupported_fails "copilot-cli" "copilot"
assert_unsupported_fails "qwen-code" "qwen"
assert_unsupported_fails "goose" "goose"
assert_unsupported_fails "cline" "clite"
assert_unsupported_fails "pi" "pi"
# A fixture literally named "cline" must NOT trip the cline entry (its real
# executable is "clite") — confirms the check keys off `executable`, not slug.
cline_slug_bin_dir="${work_dir}/fake-bin-cline-slug"
mkdir -p "$cline_slug_bin_dir"
printf '#!/bin/sh\nexit 0\n' >"${cline_slug_bin_dir}/cline"
chmod +x "${cline_slug_bin_dir}/cline"
only_cline_registry="${work_dir}/registry-only-cline.json"
jq -n '{harnesses: [{slug: "cline"}]}' >"$only_cline_registry"
BOT_AUTONOMY_REGISTRY="$only_cline_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="${cline_slug_bin_dir}:${SAFE_PATH}" bash "$bot_autonomy" verify >/dev/null 2>&1 ||
    fail "verify failed on a binary named 'cline' — the unsupported entry's executable is 'clite', not the slug"

echo "==> 6. claude-code-action (executable: null) is never checked for installation"
null_registry="${work_dir}/registry-null.json"
jq -n '{harnesses: [{slug: "claude-code-action"}]}' >"$null_registry"
BOT_AUTONOMY_REGISTRY="$null_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="$SAFE_PATH" bash "$bot_autonomy" verify >/dev/null 2>&1 ||
    fail "verify unexpectedly failed for the executable:null claude-code-action entry"

echo "==> 6b. verify and coverage fail when a module's slug is removed from the registry entirely (not aliased, just gone) while its executable stays installed"
gone_registry="${work_dir}/registry-claude-gone.json"
jq -n '{harnesses: [{slug: "codex-cli"}]}' >"$gone_registry"
gone_bin="${work_dir}/gone-bin"
mkdir -p "$gone_bin"
printf '#!/bin/sh\nexit 0\n' >"${gone_bin}/claude"
chmod +x "${gone_bin}/claude"
if BOT_AUTONOMY_REGISTRY="$gone_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    PATH="${gone_bin}:${SAFE_PATH}" bash "$bot_autonomy" verify >/dev/null 2>&1; then
    fail "verify did not notice claude-code's executable installed with no registry slug (direct or aliased) reaching it"
fi
if BOT_AUTONOMY_REGISTRY="$gone_registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" coverage >/dev/null 2>&1; then
    fail "coverage did not notice the claude-code module has no registry slug (direct or aliased) reaching it"
fi

echo "==> 7. Codex structural parity: bot config matches the shared baseline on every key but sandbox_mode/approval_policy"
[ -f "$codex_baseline" ] || fail "Codex shared baseline not found at ${codex_baseline}"
[ -f "$codex_bot" ] || fail "Codex bot config not found at ${codex_bot}"
strip_overrides() {
    # Drop the two intentionally-divergent keys and comment/blank lines so a
    # line-for-line diff isolates real structural drift.
    grep -Ev '^[[:space:]]*(sandbox_mode|approval_policy)[[:space:]]*=' "$1" |
        grep -Ev '^[[:space:]]*#' |
        grep -Ev '^[[:space:]]*$'
}
diff <(strip_overrides "$codex_baseline") <(strip_overrides "$codex_bot") >/dev/null ||
    fail "codex-managed-config.bot.toml diverges from codex-managed-config.toml on a key other than sandbox_mode/approval_policy"

echo "==> 8. Codex structural parity test actually catches drift (fixture)"
parity_baseline="${work_dir}/parity-baseline.toml"
parity_bot="${work_dir}/parity-bot.toml"
cp "$codex_baseline" "$parity_baseline"
cp "$codex_bot" "$parity_bot"
sed -i.bak 's/^model = .*/model = "a-different-model"/' "$parity_bot" && rm -f "${parity_bot}.bak"
if diff <(strip_overrides "$parity_baseline") <(strip_overrides "$parity_bot") >/dev/null; then
    fail "structural parity check failed to notice a divergent 'model' key"
fi

echo "==> 9. Antigravity wrapper: flag injection, passthrough, and agy-real preference"
agy_module="${module_dir}/antigravity.sh"
wrapper_home="${work_dir}/agy-wrapper-home"
mkdir -p "${wrapper_home}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${wrapper_home}/.local/bin/agy-real"
chmod +x "${wrapper_home}/.local/bin/agy-real"
HOME="$wrapper_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    BOT_AUTONOMY_ANTIGRAVITY_SETTINGS="${wrapper_home}/.gemini/antigravity-cli/settings.json" \
    bash "$agy_module" apply >/dev/null
wrapper_out="$("${wrapper_home}/.local/bin/agy" -p "do a thing")"
case "$wrapper_out" in
"REAL --dangerously-skip-permissions -p"*) ;;
*) fail "wrapper did not inject --dangerously-skip-permissions for a headless invocation: ${wrapper_out}" ;;
esac
for passthrough in "" "--version" "agent foo" "update" "--help"; do
    # shellcheck disable=SC2086
    wrapper_out="$("${wrapper_home}/.local/bin/agy" $passthrough)"
    case "$wrapper_out" in
    "REAL --dangerously-skip-permissions"*) fail "wrapper injected the flag on a passthrough invocation '${passthrough}': ${wrapper_out}" ;;
    esac
done
wrapper_out="$("${wrapper_home}/.local/bin/agy" -p "already flagged" --dangerously-skip-permissions)"
case "$wrapper_out" in
*"--dangerously-skip-permissions --dangerously-skip-permissions"*) fail "wrapper duplicated an already-present flag: ${wrapper_out}" ;;
esac

echo "==> 10. Antigravity: dangling symlink fails verify regardless of marker"
dangling_home="${work_dir}/agy-dangling-home"
mkdir -p "${dangling_home}/.local/bin"
ln -s "${dangling_home}/.local/bin/agy-real" "${dangling_home}/.local/bin/agy"
if HOME="$dangling_home" bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify did not fail on a dangling agy symlink (marker disabled)"
fi
if HOME="$dangling_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify did not fail on a dangling agy symlink (marker enabled)"
fi

echo "==> 10b. Antigravity: verify checks every autonomy key (including permissions), not toolPermission alone"
drift_home="${work_dir}/agy-drift-home"
mkdir -p "$drift_home"
HOME="$drift_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
for key in artifactReviewPolicy allowNonWorkspaceAccess enableTerminalSandbox permissions; do
    drift_settings="${drift_home}/.gemini/antigravity-cli/settings.json"
    drift_backup="$(cat "$drift_settings")"
    case "$key" in
    enableTerminalSandbox) jq ".${key} = true" "$drift_settings" >"${drift_settings}.tmp" ;;
    # An explicit per-tool deny that apply-antigravity-settings.sh's own
    # merge would otherwise leave in place untouched (the bot defaults had
    # no opinion on this key before), silently defeating toolPermission.
    permissions) jq ".${key} = {\"bash\": \"deny\"}" "$drift_settings" >"${drift_settings}.tmp" ;;
    *) jq ".${key} = \"request-review\"" "$drift_settings" >"${drift_settings}.tmp" ;;
    esac
    mv "${drift_settings}.tmp" "$drift_settings"
    if HOME="$drift_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null 2>&1; then
        fail "antigravity verify did not notice ${key} drifting while toolPermission stayed correct"
    fi
    printf '%s' "$drift_backup" >"$drift_settings"
done

echo "==> 10c. Antigravity: verify passes on a genuinely correct enabled state; fails when the backend is unrunnable or the workspace-trust entry is missing"
correct_home="${work_dir}/agy-correct-home"
mkdir -p "${correct_home}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${correct_home}/.local/bin/agy-real"
chmod +x "${correct_home}/.local/bin/agy-real"
HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null ||
    fail "verify failed against a genuinely correct enabled state (agy-real present, trustedWorkspaces set by the real apply-antigravity-settings.sh)"

# The wrapper's own bytes stay exactly correct (apply is not re-run) but every
# invocation would now exit 127 — content-matching alone cannot see this.
# HARMON_ANTIGRAVITY_SYSTEM_BINARY must point off this sandbox's own real
# /usr/local/bin/agy (the pinned image ships one), or the fallback the
# module is designed to have would incidentally mask the deleted agy-real.
rm -f "${correct_home}/.local/bin/agy-real"
if HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled \
    HARMON_ANTIGRAVITY_SYSTEM_BINARY="${work_dir}/no-such-agy" \
    bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify passed with no runnable backend (agy-real deleted, no system fallback present)"
fi
printf '#!/bin/sh\necho REAL "$@"\n' >"${correct_home}/.local/bin/agy-real"
chmod +x "${correct_home}/.local/bin/agy-real"

# Drop the workspace-trust entry the real apply-antigravity-settings.sh
# wrote, leaving every scalar key correct — a class of drift the four-key
# check above cannot see on its own.
correct_settings="${correct_home}/.gemini/antigravity-cli/settings.json"
jq 'del(.trustedWorkspaces)' "$correct_settings" >"${correct_settings}.tmp"
mv "${correct_settings}.tmp" "$correct_settings"
if HOME="$correct_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" verify >/dev/null 2>&1; then
    fail "verify passed with the current workspace missing from trustedWorkspaces"
fi

echo "==> 11. Antigravity: disabled state is verified as absence, not defaulted"
disabled_home="${work_dir}/agy-disabled-home"
mkdir -p "$disabled_home"
HOME="$disabled_home" bash "$agy_module" apply >/dev/null
HOME="$disabled_home" bash "$agy_module" verify >/dev/null ||
    fail "verify failed against the correct disabled-by-option state"
[ ! -e "${disabled_home}/.local/bin/agy" ] || fail "apply created ~/.local/bin/agy while disabled-by-option"

echo "==> 11b. Antigravity: apply's disabled-branch restore fails loudly (not silently) into a missing or invalid settings.json, leaving the backup in place"
restore_fail_home="${work_dir}/agy-restore-fail-home"
mkdir -p "${restore_fail_home}/.local/bin"
printf '#!/bin/sh\necho REAL "$@"\n' >"${restore_fail_home}/.local/bin/agy-real"
chmod +x "${restore_fail_home}/.local/bin/agy-real"
HOME="$restore_fail_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
restore_fail_settings="${restore_fail_home}/.gemini/antigravity-cli/settings.json"
restore_fail_backup="${restore_fail_settings}.harmon-init-autonomy-backup"
[ -f "$restore_fail_backup" ] ||
    fail "fixture setup: expected a backup after the enabled apply"

# Missing target: the disabled branch's `apply-antigravity-settings.sh
# restore` call must abort apply (set -e propagates its exit code) rather
# than reporting success while discarding evidence of the unfinished
# restore.
rm -f "$restore_fail_settings"
if HOME="$restore_fail_home" bash "$agy_module" apply >/dev/null 2>&1; then
    fail "antigravity apply (disabled branch) reported success while restoring into a missing settings.json"
fi
[ -f "$restore_fail_backup" ] ||
    fail "antigravity apply's disabled-branch restore discarded its backup after failing against a missing settings.json"

# Invalid (non-object) target.
printf 'not valid json' >"$restore_fail_settings"
if HOME="$restore_fail_home" bash "$agy_module" apply >/dev/null 2>&1; then
    fail "antigravity apply (disabled branch) reported success while restoring into an invalid settings.json"
fi
[ -f "$restore_fail_backup" ] ||
    fail "antigravity apply's disabled-branch restore discarded its backup after failing against an invalid settings.json"

echo "==> 12. OpenCode: fresh apply, override, preserve unrelated keys, workspace override, absent-key restore"
opencode_module="${module_dir}/opencode.sh"
oc_home="${work_dir}/oc-home"
oc_workdir="${work_dir}/oc-workdir"
mkdir -p "${oc_home}/.config/opencode" "$oc_workdir"

# Fresh creation.
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
jq -e '.permission["*"] == "allow"' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode apply did not seed permission allow-all on a fresh config"

# Override an existing ask/deny value; preserve unrelated keys; verify via the
# real opencode CLI's fully-resolved config.
printf '{"theme":"dark","permission":{"*":"ask"}}\n' >"${oc_home}/.config/opencode/opencode.json"
rm -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup"
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
jq -e '.theme == "dark" and .permission["*"] == "allow"' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode apply did not override ask/deny while preserving unrelated keys"
if command -v opencode >/dev/null 2>&1; then
    HOME="$oc_home" BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" \
        BOT_AUTONOMY_OPENCODE_WORKDIR="$oc_workdir" bash "$opencode_module" verify >/dev/null ||
        fail "opencode verify failed against a correctly-applied allow-all config"

    # Workspace-level override is not silently missed.
    printf '{"permission":{"*":"deny"}}\n' >"${oc_workdir}/opencode.json"
    if HOME="$oc_home" BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" \
        BOT_AUTONOMY_OPENCODE_WORKDIR="$oc_workdir" bash "$opencode_module" verify >/dev/null 2>&1; then
        fail "opencode verify did not notice a workspace-level permission override"
    fi

    # A workspace override can ADD a specific-category denial ALONGSIDE the
    # global wildcard rather than replacing it — OpenCode resolves both keys
    # present at once ({"*":"allow","bash":"deny"}), so a wildcard-only check
    # would report allow-all while `bash` still prompts or fails.
    printf '{"permission":{"bash":"deny"}}\n' >"${oc_workdir}/opencode.json"
    if HOME="$oc_home" BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" \
        BOT_AUTONOMY_OPENCODE_WORKDIR="$oc_workdir" bash "$opencode_module" verify >/dev/null 2>&1; then
        fail "opencode verify did not notice a workspace-level category-specific denial alongside an allow-all wildcard"
    fi
    rm -f "${oc_workdir}/opencode.json"
else
    echo "    (opencode CLI not on PATH; skipping verify sub-checks)"
fi

# apply -> apply -> restore returns the value from BEFORE THE FIRST apply.
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null
jq -e '.permission["*"] == "ask"' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode restore after apply->apply did not return the pre-FIRST-apply value"
[ ! -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" ] ||
    fail "opencode restore left its backup file behind"

# Absent permission key before apply -> restore removes the key entirely.
printf '{"theme":"dark"}\n' >"${oc_home}/.config/opencode/opencode.json"
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null
jq -e 'has("permission") | not' "${oc_home}/.config/opencode/opencode.json" >/dev/null ||
    fail "opencode restore set a default permission value instead of removing an absent key"

# Restore fails loudly (not silently) when the target config is missing —
# and leaves the backup in place rather than discarding it.
BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" apply >/dev/null
rm -f "${oc_home}/.config/opencode/opencode.json"
if BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null 2>&1; then
    fail "opencode restore reported success against a missing target config"
fi
[ -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" ] ||
    fail "opencode restore discarded its backup after failing against a missing target config"

# Restore fails loudly against an invalid (non-object) target config too,
# also leaving the backup in place.
printf 'not valid json\n' >"${oc_home}/.config/opencode/opencode.json"
if BOT_AUTONOMY_OPENCODE_CONFIG_DIR="${oc_home}/.config/opencode" bash "$opencode_module" restore >/dev/null 2>&1; then
    fail "opencode restore reported success against an invalid target config"
fi
[ -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" ] ||
    fail "opencode restore discarded its backup after failing against an invalid target config"
rm -f "${oc_home}/.config/opencode/opencode.json.harmon-init-autonomy-backup" "${oc_home}/.config/opencode/opencode.json"

echo "==> 13. Claude Code module: apply/verify round-trip and failure on drift"
claude_module="${module_dir}/claude-code.sh"
claude_fixture="${work_dir}/claude-managed-settings.json"
printf '{"skipDangerousModePermissionPrompt":true}\n' >"$claude_fixture"
BOT_AUTONOMY_CLAUDE_MANAGED="$claude_fixture" bash "$claude_module" apply >/dev/null
BOT_AUTONOMY_CLAUDE_MANAGED="$claude_fixture" bash "$claude_module" verify >/dev/null ||
    fail "claude-code verify failed immediately after a correct apply"
jq '.permissions.defaultMode = "default"' "$claude_fixture" >"${claude_fixture}.tmp" && mv "${claude_fixture}.tmp" "$claude_fixture"
if BOT_AUTONOMY_CLAUDE_MANAGED="$claude_fixture" bash "$claude_module" verify >/dev/null 2>&1; then
    fail "claude-code verify did not fail on a drifted defaultMode"
fi

echo "==> 14. Codex module: checksum verify and failure on corruption"
codex_module="${module_dir}/codex-cli.sh"
codex_fixture="${work_dir}/codex-managed.toml"
cp "$codex_baseline" "$codex_fixture"
BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" apply >/dev/null
BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" verify >/dev/null ||
    fail "codex-cli verify failed immediately after a correct apply"
printf '\n# corrupted\n' >>"$codex_fixture"
if BOT_AUTONOMY_CODEX_MANAGED="$codex_fixture" bash "$codex_module" verify >/dev/null 2>&1; then
    fail "codex-cli verify did not fail on a checksum mismatch"
fi

echo "==> 15. bot-autonomy.sh dispatches Antigravity's disabled-branch restore even when agy is nowhere on PATH"
no_agy_home="${work_dir}/agy-no-executable-home"
mkdir -p "${no_agy_home}/.local/bin"
# Simulate "was previously enabled": a real apply with agy-real present
# persists always-proceed settings, matching a container that had autonomy
# on before the option was toggled off.
printf '#!/bin/sh\necho REAL "$@"\n' >"${no_agy_home}/.local/bin/agy-real"
chmod +x "${no_agy_home}/.local/bin/agy-real"
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled bash "$agy_module" apply >/dev/null
grep -q '"toolPermission": *"always-proceed"' "${no_agy_home}/.gemini/antigravity-cli/settings.json" ||
    fail "fixture setup: expected always-proceed after the enabled apply"

# Now simulate disabling the option on a compatibility image with no system
# agy: remove agy-real (as ensure-antigravity-cli.sh would) and dispatch
# through the TOP-LEVEL bot-autonomy.sh — not antigravity.sh directly — on
# SAFE_PATH, which by construction cannot resolve agy anywhere (this
# sandbox's own /usr/local/bin/agy must not leak in and mask the bug).
rm -f "${no_agy_home}/.local/bin/agy-real" "${no_agy_home}/.local/bin/agy"
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled PATH="$SAFE_PATH" \
    BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" apply >/dev/null ||
    fail "bot-autonomy.sh apply failed with agy absent from PATH (disabled option)"
if grep -q '"toolPermission"' "${no_agy_home}/.gemini/antigravity-cli/settings.json"; then
    fail "Antigravity settings still carry a managed toolPermission after disabling with agy absent from PATH — the disabled branch's restore did not run"
fi
HOME="$no_agy_home" HARMON_BOT_AUTONOMY_ANTIGRAVITY=disabled PATH="$SAFE_PATH" \
    BOT_AUTONOMY_REGISTRY="$registry" BOT_AUTONOMY_CONFIG_DIR="$module_dir" \
    bash "$bot_autonomy" verify >/dev/null ||
    fail "bot-autonomy.sh verify failed against the correctly-restored disabled state with agy absent from PATH"

echo "All bot-autonomy unit tests passed."
