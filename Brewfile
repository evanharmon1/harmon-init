# Brewfile for harmon-init (template maintenance tooling)
# Install with: task install  (brew bundle --file=Brewfile)

# Template engine
brew "copier"

# Task runner + git hooks
brew "go-task"
brew "lefthook"

# Git / GitHub
brew "git"
brew "gh"
brew "git-delta"

# Lint / format
brew "shellcheck"
brew "shfmt"
brew "actionlint"
brew "yamllint"
brew "markdownlint-cli2"

# Security
brew "gitleaks"
tap "snyk/tap"
brew "snyk/tap/snyk"

# Devcontainer
brew "hadolint"
brew "devcontainer"

# Skills sync (scripts/sync-skills.sh reads .skills-sync.yaml)
brew "yq"

# Python tooling (uv; foreman lint runs pinned ruff/black via uvx)
brew "uv"

# Runtime for npx-based tools (commitlint, markdownlint-cli2)
brew "node"

# Universal scripts parse JSON/TOML and Foreman requires Python 3.11+
brew "python"

# Utilities
brew "coreutils"    # `timeout` portability (`gtimeout` on macOS)
brew "direnv"
brew "jq"
brew "fzf"
brew "fd"
brew "ripgrep"
brew "bat"
brew "tokei"
brew "gum"          # status dashboard rendering (scripts/status.sh)
brew "television"   # interactive task menu (`task` / task menu-tv → tv)
brew "act"

# macOS apps
cask "visual-studio-code"
cask "bunch"
