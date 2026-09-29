#!/usr/bin/env bash
set -euo pipefail

# AGENT posture post-create. The agent PAT lives on the bot machine account,
# so this profile commits as the bot, like the bot profile.
export DEVCONTAINER_GIT_NAME="evanharmon1-bot"
export DEVCONTAINER_GIT_EMAIL="evanharmon1-bot@users.noreply.github.com"
# Which remedy post-create-common.sh prints when `gh` has no credential: the
# agent PAT (AGENT_GH_TOKEN), never an interactive login.
export DEVCONTAINER_GH_AUTH="agent-token"

# Ordering is load-bearing:
#   (i)   egress-allowlist.sh apply — default-deny egress FIRST, so every step
#         below (and every agent after it) already runs under the filter.
#         Fails the container on any enforcement failure.
#   (ii)  agent-autonomy.sh apply — the agent Claude/Codex managed policy and
#         the refusal of every harness without an agent-capable
#         configuration, before anything below can launch a harness.
#   (iii) the gh login from AGENT_GH_TOKEN, before post-create-common.sh
#         runs `gh auth setup-git` against it.
#   (iv)  post-create-common.sh — the shared workspace setup.
#   (v)   both verifies, last, so drift introduced by anything above fails
#         container creation.
bash .devcontainer/scripts/egress-allowlist.sh apply
bash .devcontainer/agent/agent-autonomy.sh apply

# The PAT goes to gh on stdin, never argv, and is stored as gh's own
# credential (containerEnv blanks every env token that would outrank it).
# Absent is not fatal: the container still comes up, and post-create-common.sh
# prints the provisioning remedy.
if [ -n "${AGENT_GH_TOKEN:-}" ]; then
    printf '%s\n' "$AGENT_GH_TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token
    echo "==> gh authenticated from AGENT_GH_TOKEN"
fi

bash .devcontainer/scripts/post-create-common.sh

bash .devcontainer/agent/agent-autonomy.sh verify
bash .devcontainer/scripts/egress-allowlist.sh verify
