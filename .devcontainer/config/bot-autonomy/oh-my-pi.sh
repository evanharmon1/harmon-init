#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: oh-my-pi (binary `omp`). Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. NOT Copier-gated:
# oh-my-pi is a broker-style, model-agnostic harness with no account or paid
# tier of its own for AGENTS.md's Hard Rule to apply to.
#
# Forces tools.approvalMode to "yolo" in ~/.omp/agent/config.yml on every
# apply, overriding any prior value for that key while preserving every other
# key — the same managed-key/backup-and-restore shape opencode.sh uses. The
# value is written EXPLICITLY rather than left to oh-my-pi's own schema
# default (which happens to be "yolo" today) for three reasons: a
# project-level <cwd>/.omp/config.yml sits ABOVE global config in oh-my-pi's
# precedence chain; a future release could change its own default without
# notice; and a bot container's ~/.omp volume starts empty, so there is no
# durable state at all until this module creates it.
#
# verify reads oh-my-pi's own FULLY RESOLVED value (`omp config get
# tools.approvalMode --json`, run from the working directory being verified)
# rather than the global file alone — same reason opencode.sh asks
# `opencode debug config` instead of reading its global JSON: a
# workspace-level override would otherwise be missed entirely.
#
# Mechanism confirmed at implementation time against the actually-installed
# omp v18.1.2 in the shared image (not documentation alone): `omp config
# path` reports ~/.omp/agent; `omp config get tools.approvalMode --json`
# returns {"key","value","type":"enum","description"} and resolves a
# <cwd>/.omp/config.yml override over the global file; the enum is
# always-ask | write | yolo with schema default yolo. See
# openspec/changes/bot-autonomy-new-harnesses/design.md - Decisions.

OMP_AGENT_DIR="${BOT_AUTONOMY_OMP_AGENT_DIR:-$HOME/.omp/agent}"
CONFIG="${OMP_AGENT_DIR}/config.yml"
BACKUP="${CONFIG}.harmon-init-autonomy-backup"
WORKDIR="${BOT_AUTONOMY_OMP_WORKDIR:-$PWD}"

# An absent document (empty file) is as valid a starting point as a mapping;
# anything else means somebody's real configuration is in a shape this
# module must not rewrite blindly.
valid_document() {
    yq -e '. == null or (type == "!!map")' "$1" >/dev/null 2>&1
}

need_yq() {
    command -v yq >/dev/null 2>&1 || {
        echo "oh-my-pi: yq not found" >&2
        exit 1
    }
}

cmd_apply() {
    need_yq
    command -v jq >/dev/null 2>&1 || {
        echo "oh-my-pi: jq not found" >&2
        exit 1
    }
    mkdir -p "$OMP_AGENT_DIR"
    if [ ! -f "$CONFIG" ]; then
        : >"$CONFIG"
        chmod 0600 "$CONFIG"
    elif ! valid_document "$CONFIG"; then
        echo "oh-my-pi: ${CONFIG} is not a valid YAML mapping; leaving it unchanged" >&2
        exit 1
    fi

    # Gated on no backup existing yet, so apply -> apply -> restore returns
    # the value from before the FIRST apply, not from before the last one.
    if [ ! -f "$BACKUP" ]; then
        local prior tools_present present values backup_tmp
        prior="$(yq -r '.tools.approvalMode // ""' "$CONFIG")"
        tools_present="$(yq -r 'has("tools")' "$CONFIG")"
        if [ -n "$prior" ]; then
            present='["tools.approvalMode"]'
            values="$(jq -n --arg v "$prior" '{"tools.approvalMode": $v}')"
        else
            present='[]'
            values='{}'
        fi
        backup_tmp="$(mktemp "${OMP_AGENT_DIR}/config.backup.tmp.XXXXXX")"
        jq -n \
            --argjson present "$present" \
            --argjson values "$values" \
            --argjson tools_present "${tools_present:-false}" \
            '{present: $present, values: $values, tools_present: $tools_present}' >"$backup_tmp"
        chmod 0600 "$backup_tmp"
        mv -f "$backup_tmp" "$BACKUP"
    fi

    if [ "$(yq -r '.tools.approvalMode // ""' "$CONFIG")" != "yolo" ]; then
        yq -i '.tools.approvalMode = "yolo"' "$CONFIG"
        echo "==> oh-my-pi: tools.approvalMode=yolo applied"
    fi
}

cmd_restore() {
    need_yq
    command -v jq >/dev/null 2>&1 || {
        echo "oh-my-pi: jq not found" >&2
        exit 1
    }
    [ -f "$BACKUP" ] || return 0
    if [ ! -f "$CONFIG" ] || ! valid_document "$CONFIG"; then
        echo "oh-my-pi: restore failed — ${CONFIG} is missing or not a valid YAML mapping; leaving ${BACKUP} in place" >&2
        return 1
    fi
    local prior tools_present
    prior="$(jq -r '.values["tools.approvalMode"] // ""' "$BACKUP")" || {
        echo "oh-my-pi: restore failed — could not read ${BACKUP}; leaving it in place" >&2
        return 1
    }
    tools_present="$(jq -r '.tools_present // false' "$BACKUP")"
    if [ -n "$prior" ]; then
        # strenv, never string interpolation: the captured value comes off
        # disk, and splicing it into the expression would let a hand-edited
        # backup run arbitrary yq against the operator's config.
        BOT_AUTONOMY_OMP_PRIOR="$prior" yq -i '.tools.approvalMode = strenv(BOT_AUTONOMY_OMP_PRIOR)' "$CONFIG"
    else
        yq -i 'del(.tools.approvalMode)' "$CONFIG"
        # apply may have created the `tools` mapping itself; do not leave an
        # empty one behind that was never in the operator's file.
        if [ "$tools_present" != "true" ] && [ "$(yq -r '(.tools // {}) | length' "$CONFIG")" = "0" ]; then
            yq -i 'del(.tools)' "$CONFIG"
        fi
    fi
    rm -f "$BACKUP"
    echo "==> oh-my-pi: approval-mode policy restored"
}

cmd_verify() {
    command -v omp >/dev/null 2>&1 || {
        echo "oh-my-pi: omp CLI not found" >&2
        exit 1
    }
    command -v jq >/dev/null 2>&1 || {
        echo "oh-my-pi: jq not found" >&2
        exit 1
    }
    [ -d "$WORKDIR" ] || {
        echo "oh-my-pi: verify failed — working directory ${WORKDIR} does not exist" >&2
        exit 1
    }

    local resolved mode
    resolved="$(cd "$WORKDIR" && omp config get tools.approvalMode --json 2>/dev/null)" || {
        echo "oh-my-pi: verify failed — 'omp config get tools.approvalMode --json' did not run in ${WORKDIR}" >&2
        exit 1
    }
    mode="$(printf '%s' "$resolved" | jq -r '.value // empty')" || {
        echo "oh-my-pi: verify failed — could not evaluate the resolved approval mode" >&2
        exit 1
    }
    if [ "$mode" != "yolo" ]; then
        local cause="$CONFIG" candidate
        candidate="${WORKDIR}/.omp/config.yml"
        if [ -f "$candidate" ] && command -v yq >/dev/null 2>&1 &&
            yq -e '.tools.approvalMode != null' "$candidate" >/dev/null 2>&1; then
            cause="$candidate"
        fi
        echo "oh-my-pi: verify failed — resolved tools.approvalMode is '${mode:-<unset>}', expected 'yolo' (check ${cause})" >&2
        exit 1
    fi
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
restore) cmd_restore ;;
executable) echo "omp" ;;
*)
    echo "Usage: $0 <apply|verify|restore|executable>" >&2
    exit 2
    ;;
esac
