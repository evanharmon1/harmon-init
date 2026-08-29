#!/usr/bin/env bash
set -euo pipefail

manifest=/usr/local/share/harmon-devcontainer/manifest.json

fail() {
    echo "harmon-devcontainer smoke: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "image default user is not root"
id vscode >/dev/null 2>&1 || fail "vscode user is missing"
[ -x /usr/local/sbin/install-harmon-repo-config ] || fail "repository overlay installer is missing"
[ -f "$manifest" ] || fail "tool manifest is missing"
jq -e '.schemaVersion == 1' "$manifest" >/dev/null || fail "unexpected manifest schema"
jq -e '.image.name == "ghcr.io/evanharmon1/harmon-devcontainer"' "$manifest" >/dev/null ||
    fail "manifest names the wrong image"

if [ -n "${EXPECTED_REVISION:-}" ]; then
    [ "$(jq -r '.image.revision' "$manifest")" = "$EXPECTED_REVISION" ] ||
        fail "manifest revision does not match $EXPECTED_REVISION"
fi
if [ -n "${EXPECTED_ARCHITECTURE:-}" ]; then
    [ "$(jq -r '.image.architecture' "$manifest")" = "$EXPECTED_ARCHITECTURE" ] ||
        fail "manifest architecture does not match $EXPECTED_ARCHITECTURE"
fi

for tool in task shfmt hadolint actionlint terraform-docs terraform tflint yq lefthook gitleaks sops act uv semgrep copier \
    claude codex gemini opencode agy agent-deck playwright playwright-cli zellij workmux aoe sesh herdr dmux starship \
    dive fx glow lazygit tokei xh gum gh-dash wtfutil lychee tv; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done

run_version() {
    _rv_tool="$1"
    shift
    "$@" >/dev/null 2>&1 || fail "$_rv_tool cannot execute its version/help command"
}

# These invocations execute every architecture-specific binary instead of only
# proving that an appropriately named path exists. workmux and dmux require a
# live multiplexer session for a zero exit, so their safe help probes only need
# to reject loader/command-not-found failures (126/127).
run_version task task --version
run_version shfmt shfmt --version
run_version hadolint hadolint --version
run_version actionlint actionlint -version
run_version terraform-docs terraform-docs --version
run_version terraform terraform version
run_version tflint tflint --version
run_version yq yq --version
run_version lefthook lefthook version
run_version gitleaks gitleaks version
run_version sops sops --version
run_version act act --version
run_version uv uv --version
run_version semgrep semgrep --help
run_version copier copier --version
run_version claude claude --version
run_version codex codex --version
run_version gemini gemini --version
run_version opencode opencode --version
run_version agy agy --version
run_version agent-deck agent-deck --version
run_version playwright playwright --version
run_version playwright-cli playwright-cli --help
run_version zellij zellij --version
run_version aoe aoe --version
run_version sesh sesh --version
run_version herdr herdr --version
run_version starship starship --version
run_version dive dive --version
run_version fx fx --version
run_version glow glow --version
run_version lazygit lazygit --version
run_version tokei tokei --version
run_version xh xh --version
run_version gum gum --version
run_version gh-dash gh-dash --version
run_version wtfutil wtfutil --version
run_version lychee lychee --version
run_version tv tv --version

for tool in workmux dmux; do
    _loader_rc=0
    "$tool" --help >/dev/null 2>&1 || _loader_rc=$?
    case "$_loader_rc" in
    126 | 127) fail "$tool is not executable on this architecture" ;;
    esac
done

# Claude Code's global install is root-owned while containers run as vscode, so
# its auto-updater can only ever fail; the Dockerfile disables it. Assert the
# env var survives, otherwise the warning silently returns to every consumer.
[ "${DISABLE_AUTOUPDATER:-}" = "1" ] ||
    fail "DISABLE_AUTOUPDATER is not set to 1 in the image environment"
[ "${OPENCODE_DISABLE_AUTOUPDATE:-}" = "true" ] ||
    fail "OPENCODE_DISABLE_AUTOUPDATE is not set to true in the image environment"
[ "${AGY_CLI_DISABLE_AUTO_UPDATE:-}" = "true" ] ||
    fail "AGY_CLI_DISABLE_AUTO_UPDATE is not set to true in the image environment"

task_version="$(task --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$task_version" = "$(jq -r '.tools.task' "$manifest")" ] ||
    fail "task $task_version does not match the manifest"
terraform_version="$(terraform version -json | jq -r '.terraform_version')"
[ "$terraform_version" = "$(jq -r '.tools.terraform' "$manifest")" ] ||
    fail "Terraform $terraform_version does not match the manifest"
tflint_version="$(tflint --version | awk 'NR == 1 { print $3 }')"
[ "$tflint_version" = "$(jq -r '.tools.tflint' "$manifest")" ] ||
    fail "TFLint $tflint_version does not match the manifest"
agy_version="$(agy --version | head -1)"
[ "$agy_version" = "$(jq -r '.tools["antigravity-cli"]' "$manifest")" ] ||
    fail "Antigravity CLI $agy_version does not match the manifest"

echo "harmon-devcontainer smoke: passed"
