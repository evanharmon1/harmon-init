#!/usr/bin/env bash
set -euo pipefail

# Prevent VS Code's JS debug extension from breaking Node.js processes.
# The extension injects NODE_OPTIONS=--require .../bootloader.js, but the
# bootloader may not exist during lifecycle commands (extensions not installed
# yet or workspace storage path is stale). This is a non-interactive context,
# so the shell profile's `unset NODE_OPTIONS` doesn't apply.
unset NODE_OPTIONS
# Prevent a host-exported ANTHROPIC_API_KEY from silently winning over
# CLAUDE_CODE_OAUTH_TOKEN and billing the API account instead.
unset ANTHROPIC_API_KEY

if [ -z "${DEVCONTAINER_GIT_NAME:-}" ] || [ -z "${DEVCONTAINER_GIT_EMAIL:-}" ]; then
    echo "DEVCONTAINER_GIT_NAME and DEVCONTAINER_GIT_EMAIL must be set." >&2
    exit 1
fi

PROFILE_SNIPPET_DIR="$HOME/.config/harmon-devcontainer"
PROFILE_SNIPPET_PATH="${PROFILE_SNIPPET_DIR}/bashrc.sh"
PROFILE_SOURCE_LINE='source "$HOME/.config/harmon-devcontainer/bashrc.sh"'

# Git identity for commits
git config --global user.name "${DEVCONTAINER_GIT_NAME}"
git config --global user.email "${DEVCONTAINER_GIT_EMAIL}"

# Let VS Code's devcontainer integration manage the in-container git credential
# helper. Installing gh's URL-specific helpers here can confuse the remote
# containers bootstrap when it replaces credential.helper on attach.
if [ -n "${REMOTE_CONTAINERS_IPC:-}" ] || [ "${REMOTE_CONTAINERS:-}" = "true" ]; then
    git config --global --unset-all credential.https://github.com.helper || true
    git config --global --unset-all credential.https://gist.github.com.helper || true
    echo "VS Code devcontainer detected; skipping gh auth setup-git."
elif gh auth status >/dev/null 2>&1; then
    gh auth setup-git
else
    echo "GitHub CLI is not authenticated; skipping gh auth setup."
fi

echo "Git user: $(git config --global user.name)"
echo "GitHub auth status:"
gh auth status || true

# Automatically set upstream branch without needing --set-upstream when pushing new branches
git config --global push.autoSetupRemote true

echo "==> Fixing ownership of persistent volume dirs..."
for dir in /home/vscode/.codex /home/vscode/.claude /home/vscode/.gemini \
    /home/vscode/.agent-deck /home/vscode/.shell-history \
    /home/vscode/.local /home/vscode/.local/share /home/vscode/.local/share/zoxide; do
    sudo mkdir -p "$dir"
    sudo chown vscode:vscode "$dir"
    chmod 700 "$dir"
done

# --- Claude Code onboarding seed ---
# Pre-seed ~/.claude/.claude.json so fresh containers skip the onboarding
# wizard (upstream issue: https://github.com/anthropics/claude-code/issues/8938).
# post-start-common.sh creates ~/.claude.json → ~/.claude/.claude.json so
# Claude Code finds this file on first launch. Guard: only seed on an empty
# volume — existing session data (token, settings) must never be clobbered.
CLAUDE_SESSION_FILE="$HOME/.claude/.claude.json"
if [ -d "$HOME/.claude" ] && [ ! -f "$CLAUDE_SESSION_FILE" ]; then
    echo '{"hasCompletedOnboarding":true}' >"$CLAUDE_SESSION_FILE"
    chmod 0600 "$CLAUDE_SESSION_FILE"
    echo "==> Seeded ~/.claude/.claude.json with hasCompletedOnboarding=true"
fi

# --- Coder persistent volume symlinks ---
# Coder's envbuilder does not support devcontainer volume mounts, so on Coder
# the template provides a single persistent volume at ~/.persistent/ and we
# symlink the individual directories there.
if [ "${CODER:-}" = "true" ] && [ -d "/home/vscode/.persistent" ]; then
    echo "==> Coder detected — setting up persistent volume symlinks..."
    for dir in .claude .codex .gemini .agent-deck .shell-history; do
        mkdir -p "/home/vscode/.persistent/$dir"
        if [ -d "$HOME/$dir" ] && [ ! -L "$HOME/$dir" ]; then
            cp -a "$HOME/$dir/." "/home/vscode/.persistent/$dir/" 2>/dev/null || true
            rm -rf "${HOME:?}/$dir"
        fi
        ln -sfn "/home/vscode/.persistent/$dir" "$HOME/$dir"
    done
    mkdir -p "/home/vscode/.persistent/zoxide" "$HOME/.local/share"
    if [ -d "$HOME/.local/share/zoxide" ] && [ ! -L "$HOME/.local/share/zoxide" ]; then
        cp -a "$HOME/.local/share/zoxide/." "/home/vscode/.persistent/zoxide/" 2>/dev/null || true
        rm -rf "${HOME:?}/.local/share/zoxide"
    fi
    ln -sfn "/home/vscode/.persistent/zoxide" "$HOME/.local/share/zoxide"
fi

# --- Agent-Deck config seeding ---
# When a fresh volume mount shadows ~/.agent-deck, seed it from the image-baked
# config. Source lives at /usr/local/share/ rather than /tmp/ because /tmp is a
# tmpfs at runtime on Coder hosts and would shadow build-time content.
if [ -d "$HOME/.agent-deck" ] && [ ! -f "$HOME/.agent-deck/config.toml" ]; then
    echo "==> Seeding agent-deck config into persistent volume..."
    cp /usr/local/share/devcontainer-config/agent-deck.toml "$HOME/.agent-deck/config.toml"
fi

# --- Claude Code settings ---
# Two layers, both owned by the dev container (never the volume):
#
#   1. /etc/claude-code/managed-settings.json — baked by the Dockerfile.
#      Highest precedence (policySettings); enforces skipDangerousModePermissionPrompt,
#      defaultMode, and the baseline Bash(...) allow list. Users CANNOT override
#      these. Source of truth: .devcontainer/config/claude-settings.json.
#
#   2. ~/.claude/settings.json (user level) — seed-merged below from
#      claude-user-defaults.json. Provides defaults the user CAN override
#      (currently: model). Existing values in ~/.claude/settings.json always
#      win on conflict, so /model and other in-app changes stick across
#      post-create runs. On a fresh volume the defaults are populated; on a
#      volume wipe + rebuild they come back automatically.
CLAUDE_DEFAULTS_SRC=/usr/local/share/devcontainer-config/claude-user-defaults.json
CLAUDE_USER_SETTINGS="$HOME/.claude/settings.json"
if [ -d "$HOME/.claude" ] && [ -f "$CLAUDE_DEFAULTS_SRC" ]; then
    if [ ! -f "$CLAUDE_USER_SETTINGS" ]; then
        echo "==> Seeding ~/.claude/settings.json from dev container defaults..."
        install -m 0600 "$CLAUDE_DEFAULTS_SRC" "$CLAUDE_USER_SETTINGS"
    elif command -v jq >/dev/null 2>&1; then
        # Deep-merge: defaults fill in missing fields, existing user values win.
        # `.[0] * .[1]` puts existing on the right so it overrides defaults.
        tmp=$(mktemp)
        if jq -s '.[0] * .[1]' "$CLAUDE_DEFAULTS_SRC" "$CLAUDE_USER_SETTINGS" >"$tmp"; then
            if ! cmp -s "$tmp" "$CLAUDE_USER_SETTINGS"; then
                echo "==> Merging dev container defaults into ~/.claude/settings.json..."
                install -m 0600 "$tmp" "$CLAUDE_USER_SETTINGS"
            fi
            rm -f "$tmp"
        else
            echo "WARNING: jq merge of Claude user defaults failed; leaving settings.json unchanged" >&2
            rm -f "$tmp"
        fi
    fi
fi

# --- Agent-Deck conductor setup ---
# Inject Telegram bot token from env var into agent-deck config
if [ -n "${AGENT_DECK_TELEGRAM_KEY:-}" ]; then
    echo "==> Injecting Telegram bot token into agent-deck config..."
    sd 'token = ".*"' "token = \"${AGENT_DECK_TELEGRAM_KEY}\"" "$HOME/.agent-deck/config.toml"
fi

# Ensure bridge dependencies are installed for the runtime Python.
# The Dockerfile installs toml/aiogram for the base system Python, but the
# devcontainer Python feature (3.14) replaces python3 on the PATH.
pip install --quiet toml aiogram 2>/dev/null || true

# Set up conductor if not already present (named after this repo)
REPO_NAME="$(basename "$PWD")"
if [ ! -d "$HOME/.agent-deck/conductor/$REPO_NAME" ]; then
    echo "==> Setting up agent-deck conductor '$REPO_NAME'..."
    echo "n" | agent-deck conductor setup "$REPO_NAME" \
        --description "$REPO_NAME devcontainer conductor" \
        --no-heartbeat || true
fi

if [ -f pyproject.toml ]; then
    echo "==> Setting up Python virtualenv and dependencies..."
    uv sync
else
    echo "==> No pyproject.toml found; skipping Python setup."
fi

if [ -f ansible/requirements.yml ]; then
    echo "==> Installing Ansible Galaxy collections..."
    uv run ansible-galaxy collection install -r ansible/requirements.yml
else
    echo "==> No ansible/requirements.yml found; skipping Ansible setup."
fi

if [ -d services/harmon-lab-proxy/homepage ]; then
    echo "==> Installing Node.js dependencies for homepage..."
    (cd services/harmon-lab-proxy/homepage && npm ci)
fi

if command -v uv &>/dev/null; then
    echo "==> Installing checkov..."
    uv tool install checkov || true
fi

if [ -f lefthook.yml ] && command -v lefthook &>/dev/null; then
    echo "==> Setting up git hooks via lefthook..."
    lefthook install
fi

echo "==> Writing shell profile snippet..."
mkdir -p "${PROFILE_SNIPPET_DIR}"
cat >"${PROFILE_SNIPPET_PATH}" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"

# Prevent VS Code JS debug bootloader from breaking lefthook Node hooks.
unset NODE_OPTIONS

# Prevent VS Code's BROWSER helper script from confusing Playwright.
unset BROWSER

# Prevent a host-exported ANTHROPIC_API_KEY from silently winning over
# CLAUDE_CODE_OAUTH_TOKEN and billing the API account instead.
unset ANTHROPIC_API_KEY

# Zellij: auto-create/attach to "main" session.
alias zj='zellij attach --create main'

# Tailscale: only available in the dev profile (DEVCONTAINER_TAILSCALE=true).
if [ "${DEVCONTAINER_TAILSCALE:-}" = "true" ]; then
  alias ts-up='bash .devcontainer/scripts/tailscale-connect.sh'
fi

# workmux: short alias and zsh completions.
alias wm=workmux
command -v workmux &>/dev/null && eval "$(workmux completions zsh)"

# ── pnpm ────────────────────────────────────────────────────
alias p='pnpm'
alias pi='pnpm install'
alias pif='pnpm install --frozen-lockfile'
alias pa='pnpm add'
alias pad='pnpm add --save-dev'
alias prm='pnpm remove'
alias pu='pnpm update'
alias pui='pnpm update --interactive --latest'

# Script runners
alias pd='pnpm run dev'
alias pb='pnpm run build'
alias pt='pnpm test'
alias pst='pnpm start'
alias pln='pnpm run lint'
alias pfmt='pnpm run format'

# Execute (npx equivalent)
alias px='pnpm dlx'
alias pex='pnpm exec'

# Monorepo workspace filter
alias pf='pnpm --filter'

# Nuclear cleanup
alias rnm='rm -rf node_modules'
alias fresh='rm -rf node_modules pnpm-lock.yaml && pnpm install'

# ── Git (beyond oh-my-zsh) ──────────────────────────────────
# Soft undo: reset last commit, keep changes staged
alias gundo='git reset --soft HEAD~1'

# Amend everything into last commit, no message edit
alias gamend='git add -A && git commit --amend --no-edit'

# Add-commit-push (use function for message argument)
gacp() { git add -A && git commit -m "$*" && git push; }

# Empty commit to retrigger CI
alias gcempty='git commit --allow-empty -m "chore: trigger CI"'

# Diff vs main (essential for PR review)
alias gdm='git diff main...HEAD'
alias gchanged='git diff --name-only main...HEAD'
alias gdstat='git diff --stat'

# Branches sorted by most recent commit
alias gbrecent='git branch --sort=-committerdate --format="%(refname:short) %(committerdate:relative)"'

# Fixup commit (pairs with autosquash rebase)
gfixup() { git commit --fixup="$1"; }
alias grbia='git rebase -i --autosquash'

# Fetch + prune stale remote-tracking branches
alias gfp='git fetch --prune'

# Switch to main, pull latest, create new branch
gnew() { git checkout main && git pull && git checkout -b "$1"; }

# Cleanup: delete branches whose remote is gone
alias gcleanup='git fetch -p && git branch -vv | grep ": gone]" | awk "{print \$1}" | xargs -r git branch -D'

# Interactive stash (stash specific hunks)
alias gstap='git stash push -p'

# Quick branch switch with fzf
alias gswf='git branch --sort=-committerdate | fzf --height=20% | xargs git switch'

# ── Conventional commits ────────────────────────────────────
# gc* = commit only | gca* = add all + commit
gcfeat()   { git commit -m "feat: $*"; }
gcafix()   { git add -A && git commit -m "fix: $*"; }
gcfix()    { git commit -m "fix: $*"; }
gcafeat()  { git add -A && git commit -m "feat: $*"; }
gcdocs()   { git commit -m "docs: $*"; }
gcadocs()  { git add -A && git commit -m "docs: $*"; }
gcstyle()  { git commit -m "style: $*"; }
gcastyle() { git add -A && git commit -m "style: $*"; }
gcref()    { git commit -m "refactor: $*"; }
gcaref()   { git add -A && git commit -m "refactor: $*"; }
gcperf()   { git commit -m "perf: $*"; }
gcaperf()  { git add -A && git commit -m "perf: $*"; }
gctest()   { git commit -m "test: $*"; }
gcatest()  { git add -A && git commit -m "test: $*"; }
gcbuild()  { git commit -m "build: $*"; }
gcabuild() { git add -A && git commit -m "build: $*"; }
gcci()     { git commit -m "ci: $*"; }
gcaci()    { git add -A && git commit -m "ci: $*"; }
gcchore()  { git commit -m "chore: $*"; }
gcachore() { git add -A && git commit -m "chore: $*"; }

# ── TypeScript ──────────────────────────────────────────────
alias tsc='pnpm exec tsc'
alias tscw='pnpm exec tsc --watch'
alias tscn='pnpm exec tsc --noEmit'    # type-check only, no output

# ── Vitest ──────────────────────────────────────────────────
alias vt='pnpm exec vitest'
alias vtr='pnpm exec vitest run'        # single run (CI-like)
alias vtc='pnpm exec vitest run --coverage'
alias vtu='pnpm exec vitest --ui'

# ── Playwright ──────────────────────────────────────────────
alias pw='pnpm exec playwright'
alias pwt='pnpm exec playwright test'
alias pwth='pnpm exec playwright test --headed'
alias pwtu='pnpm exec playwright test --ui'
alias pwtd='pnpm exec playwright test --debug'
alias pwshow='pnpm exec playwright show-report'

# ── Taskfile (go-task) ──────────────────────────────────────
alias t='task'
alias tl='task --list'

# ── Linting / Formatting ───────────────────────────────────
alias lint='pnpm run lint'
alias lintf='pnpm run lint -- --fix'
alias fmt='pnpm run format'

# ── Ports & networking ──────────────────────────────────────
alias ports='ss -tlnp'
killport() { lsof -ti:"$1" | xargs kill -9 2>/dev/null && echo "Killed port $1" || echo "Nothing on port $1"; }
listening() { lsof -i -P -n | grep ":${1:-}.*LISTEN"; }
alias myip='curl -s https://icanhazip.com'
alias localip='hostname -I | awk "{print \$1}"'

# ── Navigation ──────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cd..='cd ..'
alias -- -='cd -'

# Zoxide auto-creates `z` (jump) and `zi` (interactive via fzf).
# No manual aliases needed — just ensure it's initialized.

# Project workspace root
alias ws='cd /workspaces'

# ── Shell management ────────────────────────────────────────
alias reload='exec zsh'                # full shell reload
alias zshrc='${EDITOR:-code} ~/.zshrc' # quick config edit
alias path='echo -e ${PATH//:/\\n}'    # PATH one-per-line
alias aliases='alias | sort'           # list all aliases
alias ag='alias | rg'                  # search aliases by keyword

# ── Quick utilities ─────────────────────────────────────────
alias c='clear'
mkcd() { mkdir -p "$1" && cd "$1"; }
alias sizeof='du -sh'
alias now='date +"%Y-%m-%d %H:%M:%S"'
alias timestamp='date +%s'
alias weather='curl -s wttr.in/?format=3'
alias help='tldr'
alias md='glow'                        # render markdown in terminal
alias lg='lazygit'

# ── Docker ──────────────────────────────────────────────────
alias dk='docker'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias dex='docker exec -it'
alias dlog='docker logs -f'
alias drun='docker run --rm -it'

# Docker Compose (modern subcommand syntax)
alias dco='docker compose'
alias dcup='docker compose up -d'
alias dcupb='docker compose up --build -d'
alias dcdn='docker compose down'
alias dcl='docker compose logs -f'
alias dcps='docker compose ps'
alias dcr='docker compose run --rm'

# Cleanup
alias docker-clean='docker system prune -f'
alias docker-nuke='docker system prune -af --volumes'

# ── fzf-powered workflows ──────────────────────────────────
# Fuzzy-find and open file
fe() {
  local file
  file=$(fd --type f | fzf --preview 'bat --color=always --line-range=:500 {}')
  [[ -n "$file" ]] && ${EDITOR:-code} "$file"
}

# Fuzzy grep: search content, preview match, open file
fg() {
  local result
  result=$(rg --line-number --no-heading --color=always "${1:-}" |
    fzf --ansi --delimiter : \
      --preview 'bat --color=always --highlight-line {2} {1}' \
      --preview-window '+{2}-5')
  [[ -n "$result" ]] && ${EDITOR:-code} "$(echo "$result" | cut -d: -f1)"
}

alias preview='fzf --preview "bat --color=always --style=numbers --line-range=:500 {}"'

# ── GitHub CLI ──────────────────────────────────────────────
alias ghpr='gh pr create'
alias ghprl='gh pr list'
alias ghprv='gh pr view --web'
alias ghprc='gh pr checkout'
alias ghis='gh issue list'
alias ghrv='gh repo view --web'
alias ghb='gh browse'
alias ghppr='git push && gh pr create --fill'
alias ghpprd='git push && gh pr create --fill --draft'
alias ghpprm='git push && gh pr create --fill && gh pr merge --auto --squash --delete-branch'
alias ghil='gh issue list'
alias ghic='gh issue create'

# ── Clipboard (OSC 52 — works in VS Code terminal) ─────────
# Usage: echo "text" | clip
#        clip < file.txt
#        git diff --stat | clip
clip() {
  local data
  data=$(cat "$@" | base64 | tr -d '\n')
  printf '\033]52;c;%s\007' "$data" > /dev/tty
}

# Extract any archive
extract() {
  case $1 in
    *.tar.bz2) tar xjf "$1" ;; *.tar.gz) tar xzf "$1" ;;
    *.tar.xz)  tar xJf "$1" ;; *.bz2)    bunzip2 "$1" ;;
    *.gz)      gunzip "$1"  ;; *.tar)    tar xf "$1"  ;;
    *.zip)     unzip "$1"   ;; *.7z)     7z x "$1"    ;;
    *)         echo "'$1' — unknown format" ;;
  esac
}
EOF

# Source the profile snippet from both .bashrc and .zshrc so it works
# regardless of which shell is active (scripts still use bash).
for rcfile in ~/.bashrc ~/.zshrc; do
    touch "$rcfile"
    if ! grep -Fqx "${PROFILE_SOURCE_LINE}" "$rcfile"; then
        {
            echo ""
            echo "# Added by devcontainer post-create"
            echo "${PROFILE_SOURCE_LINE}"
        } >>"$rcfile"
    fi
done

if [ -d terraform ]; then
    echo "==> Initializing Terraform providers..."
    (cd terraform && terraform init -backend=false) || true
fi

if command -v direnv &>/dev/null && [ -f .envrc ]; then
    echo "==> Allowing direnv .envrc..."
    direnv allow
fi

echo "==> Setup complete! Run 'task verify' to validate your environment."
