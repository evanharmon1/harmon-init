#!/usr/bin/env bash
set -euo pipefail

config_dir=/usr/local/share/devcontainer-config

fail() {
    echo "install-harmon-repo-config: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "must run as root"
id vscode >/dev/null 2>&1 || fail "the shared image has no vscode user"
[ -d "$config_dir" ] || fail "repository config was not copied to $config_dir"

required_files="
agent-deck.toml
claude-settings.json
claude-statusline.sh
claude-user-defaults.json
codex-managed-config.toml
codex-managed-config.toml
ghostty.terminfo
gitconfig
micro-bindings.json
shell-aliases.sh
starship.toml
tmux.conf.local
zshrc
zellij.kdl
television/cable/gh-issues.toml
claude-hooks/block-no-verify.sh
claude-hooks/enforce-conventional-commits.sh
claude-hooks/post-edit-format.sh
claude-hooks/protect-files.sh
claude-hooks/session-start-context.sh
codex-hooks/claude-compat.sh
codex-hooks/file-payload.sh
codex-hooks/claude-compat.sh
codex-hooks/file-payload.sh
"
while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "${config_dir}/${file}" ] || fail "required repository config is missing: $file"
done <<EOF
$required_files
EOF

tic -x "${config_dir}/ghostty.terminfo"

install -d -m 0755 \
    /etc/antigravity \
    /etc/claude-code/hooks \
    /etc/codex/hooks \
    /home/vscode/.agent-deck \
    /home/vscode/.config/git \
    /home/vscode/.config/micro \
    /home/vscode/.config/television/cable \
    /home/vscode/.config/zellij \
    /home/vscode/.shell-history

install -m 0644 "${config_dir}/tmux.conf.local" /home/vscode/.tmux.conf.local
install -m 0644 "${config_dir}/zellij.kdl" /home/vscode/.config/zellij/config.kdl
install -m 0644 "${config_dir}/micro-bindings.json" /home/vscode/.config/micro/bindings.json
install -m 0644 "${config_dir}/agent-deck.toml" /home/vscode/.agent-deck/config.toml
install -m 0644 "${config_dir}/starship.toml" /home/vscode/.config/starship.toml
install -m 0644 "${config_dir}/gitconfig" /home/vscode/.config/git/config
install -m 0644 "${config_dir}/television/cable/gh-issues.toml" \
    /home/vscode/.config/television/cable/gh-issues.toml
install -m 0644 "${config_dir}/zshrc" /home/vscode/.zshrc

install -m 0644 "${config_dir}/claude-settings.json" /etc/claude-code/managed-settings.json
install -m 0755 "${config_dir}/claude-statusline.sh" /etc/claude-code/statusline.sh
install -m 0755 "${config_dir}/claude-statusline.sh" /etc/antigravity/statusline.sh
install -m 0644 "${config_dir}/codex-managed-config.toml" /etc/codex/managed_config.toml
install -m 0644 "${config_dir}/codex-managed-config.toml" /etc/codex/managed_config.toml
for hook in \
    block-no-verify.sh \
    enforce-conventional-commits.sh \
    post-edit-format.sh \
    protect-files.sh \
    session-start-context.sh; do
    install -m 0755 "${config_dir}/claude-hooks/${hook}" "/etc/claude-code/hooks/${hook}"
done

# OPTIONAL Claude hooks — installed when the consuming repository ships them,
# skipped silently when it does not.
#
# Deliberately absent from required_files above, and the reason is the whole
# point of the guard: this image is consumed by repositories generated from
# older templates, which have no such file under claude-hooks/. Listing one in
# required_files, or installing it unguarded under `set -e`, would fail the
# devcontainer build of every repository that has not adopted it yet — a new
# image must never break an old consumer. Promote an entry into required_files
# only once the fleet has taken the update, at which point a missing file
# becomes a genuine error worth failing on rather than an expected state.
for hook in \
    session-end-archive.sh; do
    [ -f "${config_dir}/claude-hooks/${hook}" ] || continue
    install -m 0755 "${config_dir}/claude-hooks/${hook}" "/etc/claude-code/hooks/${hook}"
done
for hook in claude-compat.sh file-payload.sh; do
    install -m 0755 "${config_dir}/codex-hooks/${hook}" "/etc/codex/hooks/${hook}"
done
for hook in claude-compat.sh file-payload.sh; do
    install -m 0755 "${config_dir}/codex-hooks/${hook}" "/etc/codex/hooks/${hook}"
done

chown -R vscode:vscode \
    /home/vscode/.agent-deck \
    /home/vscode/.config \
    /home/vscode/.shell-history \
    /home/vscode/.tmux.conf.local \
    /home/vscode/.zshrc
