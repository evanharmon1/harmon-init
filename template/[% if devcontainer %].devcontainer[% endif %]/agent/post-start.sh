#!/usr/bin/env bash
set -euo pipefail

# Redirect all output to a log file to avoid SIGPIPE when VS Code
# disconnects the pipe before the script finishes.
exec &>/tmp/devcontainer-post-start.log

# Egress FIRST, on every start: the filter lives in the container's network
# namespace, which a restart recreates empty. It applies from the root-owned
# snapshot post-create wrote, never from the writable checkout, so an edit to
# the checkout's lists or applier changes nothing here. The applier leaves
# OUTPUT/FORWARD at DROP on any failure it reaches; the fallback below covers
# the ones it cannot — the snapshot missing or unreadable, or a failure before
# it runs as root — without relying on it. Either way the start fails, and a
# container whose start failed must not be used.
if ! bash /usr/local/share/harmon-egress/scripts/egress-allowlist.sh apply; then
    closed=1
    sudo -n iptables -P OUTPUT DROP || closed=0
    sudo -n iptables -P FORWARD DROP || closed=0
    sudo -n ip6tables -P OUTPUT DROP 2>/dev/null || true
    sudo -n ip6tables -P FORWARD DROP 2>/dev/null || true
    [ "$closed" -eq 1 ] ||
        echo "post-start: CRITICAL: could not close egress (no iptables, or no root) — do not use this container" >&2
    echo "post-start: egress filter not installed — failing the start" >&2
    exit 1
fi

# The gh-identity tripwire: the agent PAT is on the bot account, so the same
# '-bot' relationship holds. Warn-only, as in bot.
bash .devcontainer/scripts/check-bot-gh-identity.sh || true

# Same reason as the bot post-start: verify before the shared startup work,
# with NODE_OPTIONS cleared so a harness CLI it may touch is not broken by an
# inherited VS Code debug value.
unset NODE_OPTIONS
bash .devcontainer/agent/agent-autonomy.sh verify

bash .devcontainer/scripts/post-start-common.sh
