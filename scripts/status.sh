#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
PROJECT_NAME="$(basename "${REPO_ROOT}")"

# Section filter: empty = show all, or "git", "gh", "code", "env"
SECTION="${1:-}"

# Temp directory for parallel data collection
TMPDIR_STATUS="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_STATUS}"' EXIT

NETWORK_TIMEOUT=5

# ── Tool detection ──────────────────────────────────────────────────────────

HAS_GUM=false
command -v gum &>/dev/null && HAS_GUM=true

# ── Formatting helpers ──────────────────────────────────────────────────────

section_header() {
    local title="$1"
    if $HAS_GUM; then
        gum style --bold --foreground 212 --border-foreground 240 \
            --border rounded --padding "0 1" -- "$title"
    else
        echo ""
        echo "==> ${title}"
        echo "────────────────────────────────────────"
    fi
}

section_box() {
    local content
    content="$(cat)"
    if $HAS_GUM; then
        echo "$content" | gum style --border rounded \
            --border-foreground 240 --padding "0 1" --margin "0 0"
    else
        echo "$content"
        echo ""
    fi
}

kv() {
    local key="$1" val="$2"
    if $HAS_GUM; then
        printf "  %s  %s\n" "$(gum style --bold --foreground 39 "$key:")" "$val"
    else
        printf "  %-20s %s\n" "$key:" "$val"
    fi
}

should_show() {
    [[ -z "${SECTION}" || "${SECTION}" == "$1" ]]
}

# ── Parallel data collection ────────────────────────────────────────────────

PID_PRS=""
PID_CHECKS=""
PID_TOKEI=""

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "detached")"

if should_show "gh" && gh auth status &>/dev/null 2>&1; then
    timeout "${NETWORK_TIMEOUT}" gh pr list --limit 10 \
        --json number,title,headRefName \
        >"${TMPDIR_STATUS}/prs.json" 2>/dev/null &
    PID_PRS=$!

    timeout "${NETWORK_TIMEOUT}" gh run list --branch "${CURRENT_BRANCH}" \
        --limit 5 --json status,conclusion,name,createdAt \
        >"${TMPDIR_STATUS}/checks.json" 2>/dev/null &
    PID_CHECKS=$!
fi

if should_show "code" && command -v tokei &>/dev/null; then
    tokei --output json "${REPO_ROOT}" >"${TMPDIR_STATUS}/tokei.json" 2>/dev/null &
    PID_TOKEI=$!
fi

# Wait for background jobs
for pid in $PID_PRS $PID_CHECKS $PID_TOKEI; do
    wait "$pid" 2>/dev/null || true
done

# Ensure files exist for later reads
for f in prs.json checks.json tokei.json; do
    [[ -f "${TMPDIR_STATUS}/${f}" ]] || echo "[]" >"${TMPDIR_STATUS}/${f}"
done

# ── Header ──────────────────────────────────────────────────────────────────

if [[ -z "${SECTION}" ]]; then
    if $HAS_GUM; then
        gum style --bold --foreground 212 --border double \
            --border-foreground 99 --padding "0 2" --margin "1 0" \
            -- "${PROJECT_NAME}"
    else
        echo ""
        echo "=== ${PROJECT_NAME} ==="
        echo ""
    fi
fi

# ── Git Status ──────────────────────────────────────────────────────────────

if should_show "git"; then
    section_header "Git Status"

    last_commit="$(git log -1 --format='%h %s (%cr)' 2>/dev/null || echo "no commits")"
    dirty="$(git status --porcelain 2>/dev/null)"
    if [[ -z "$dirty" ]]; then
        status_text="clean"
    else
        changed="$(echo "$dirty" | wc -l | tr -d ' ')"
        status_text="dirty (${changed} files)"
    fi

    tag="$(git describe --tags --abbrev=0 2>/dev/null || echo "none")"

    {
        kv "Branch" "$CURRENT_BRANCH"
        kv "Status" "$status_text"
        kv "Tag" "$tag"
        kv "Last commit" "$last_commit"
        echo ""
        echo "  Recent commits:"
        git log --oneline -5 --format='    %C(yellow)%h%Creset %s %C(dim)(%cr)%Creset' \
            --color=always 2>/dev/null || echo "    (no commits)"
    } | section_box
fi

# ── GitHub Status ───────────────────────────────────────────────────────────

if should_show "gh"; then
    section_header "GitHub Status"

    if ! gh auth status &>/dev/null 2>&1; then
        echo "  (gh not authenticated -- skipping)" | section_box
    else
        {
            pr_file="${TMPDIR_STATUS}/prs.json"
            pr_count="$(jq 'length' "$pr_file" 2>/dev/null || echo "0")"
            if [[ "$pr_count" -gt 0 ]]; then
                echo "  Open PRs:"
                jq -r '.[] | "    #\(.number) \(.title) (\(.headRefName))"' "$pr_file"
            else
                echo "  Open PRs: none"
            fi

            echo ""

            checks_file="${TMPDIR_STATUS}/checks.json"
            checks_count="$(jq 'length' "$checks_file" 2>/dev/null || echo "0")"
            if [[ "$checks_count" -gt 0 ]]; then
                echo "  Recent CI runs (${CURRENT_BRANCH}):"
                jq -r '.[] |
                    (if .conclusion == "success" then "pass"
                     elif .conclusion == "failure" then "FAIL"
                     elif .status == "in_progress" then " run"
                     else " -- " end) as $icon |
                    "    \($icon)  \(.name)  (\(.createdAt | split("T")[0]))"' \
                    "$checks_file"
            else
                echo "  Recent CI runs: none"
            fi
        } | section_box
    fi
fi

# ── Codebase Stats ──────────────────────────────────────────────────────────

if should_show "code"; then
    section_header "Codebase Stats"

    tokei_file="${TMPDIR_STATUS}/tokei.json"
    if [[ -s "$tokei_file" ]] && jq -e 'keys | length > 1' "$tokei_file" &>/dev/null; then
        {
            echo "  Languages (by lines of code):"
            jq -r '
                to_entries
                | map(select(.key != "Total"))
                | sort_by(-.value.code)
                | .[:10]
                | .[]
                | "    \(.key): \(.value.code) code, \(.value.comments) comments"
            ' "$tokei_file" 2>/dev/null || echo "    (parse error)"

            echo ""

            total_code="$(jq '[to_entries[] | select(.key != "Total") | .value.code] | add // 0' "$tokei_file" 2>/dev/null || echo "?")"
            total_files="$(jq '[to_entries[] | select(.key != "Total") | .value.reports | length] | add // 0' "$tokei_file" 2>/dev/null || echo "?")"
            kv "Total code lines" "$total_code"
            kv "Total files" "$total_files"
        } | section_box
    elif command -v tokei &>/dev/null; then
        tokei "${REPO_ROOT}" --compact 2>/dev/null | section_box
    else
        echo "  (tokei not installed)" | section_box
    fi
fi

# ── Environment ─────────────────────────────────────────────────────────────

if should_show "env"; then
    section_header "Environment"

    {
        python_ver="$(python3 --version 2>/dev/null | awk '{print $2}' || echo "not installed")"
        node_ver="$(node --version 2>/dev/null || echo "not installed")"
        docker_ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "not installed")"
        task_ver="$(task --version 2>/dev/null | awk '{print $NF}' || echo "not installed")"

        kv "Python" "$python_ver"
        kv "Node.js" "$node_ver"
        kv "Docker" "$docker_ver"
        kv "Task" "$task_ver"

        echo ""

        if [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${CODESPACES:-}" ]] || [[ -n "${REMOTE_CONTAINERS_IPC:-}" ]]; then
            kv "Devcontainer" "active (VS Code)"
        elif [[ "${CODER:-}" == "true" ]]; then
            kv "Devcontainer" "active (Coder)"
        else
            kv "Devcontainer" "not detected"
        fi
    } | section_box
fi
