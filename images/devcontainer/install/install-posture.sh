#!/usr/bin/env bash
# install-posture.sh — the agent-posture extension point. A DELIBERATE NO-OP.
#
# The managed Claude Code settings (/etc/claude-code/managed-settings.json) and
# the Codex configuration that install-repo-config.sh writes in the shared
# image are NOT installed here yet: defining that posture is #1408's unit, and
# proving each remote platform honours it is #1404's. This file exists so that
# work lands as one named step at a fixed point in the sequence — last, after
# every tool the posture might reference is on PATH — instead of being
# retrofitted into the middle of a tier.
#
# Until then it asserts nothing and installs nothing. Running the bootstrap on
# a remote VM today therefore leaves the agent posture UNSET, which is stated
# in docs/architecture/remote-environments.md rather than left to be
# discovered.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

harmon_log "posture: nothing to install (extension point for #1404; see docs/architecture/remote-environments.md)"
