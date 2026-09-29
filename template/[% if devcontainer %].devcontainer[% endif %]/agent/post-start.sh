#!/usr/bin/env bash
set -euo pipefail

# Redirect all output to a log file to avoid SIGPIPE when VS Code
# disconnects the pipe before the script finishes.
exec &>/tmp/devcontainer-post-start.log

# Egress FIRST, on every start: the filter lives in the container's network
# namespace, which a restart recreates empty. It applies from the root-owned
# snapshot post-create wrote, never from the writable checkout, so an edit to
# the checkout's lists or applier changes nothing here. Fails the start if
# enforcement cannot be installed (a missing snapshot included).
bash /usr/local/share/harmon-egress/scripts/egress-allowlist.sh apply

# The gh-identity tripwire: the agent PAT is on the bot account, so the same
# '-bot' relationship holds. Warn-only, as in bot.
bash .devcontainer/scripts/check-bot-gh-identity.sh || true

# Same reason as the bot post-start: verify before the shared startup work,
# with NODE_OPTIONS cleared so a harness CLI it may touch is not broken by an
# inherited VS Code debug value.
unset NODE_OPTIONS
bash .devcontainer/agent/agent-autonomy.sh verify

bash .devcontainer/scripts/post-start-common.sh
