#!/usr/bin/env bash
# gh-scopes.sh — the single source of truth for the GitHub token scopes this
# repository's tooling needs.
#
# SOURCED, never executed. Three consumers read it so the required list is
# stated once instead of drifting into three near-copies:
#
#   * scripts/status.sh          — warns at session start when a scope is missing
#   * scripts/setup-gh-scopes.sh — mints/refreshes a credential that has them all
#   * .devcontainer/scripts/post-create-common.sh — the gh_auth_help banner's
#     `gh auth login --scopes` line
#
# A consumer repo extends the list WITHOUT editing this file by exporting
# GH_REQUIRED_SCOPES before invoking any of the above (e.g. in .envrc):
#
#     export GH_REQUIRED_SCOPES="repo workflow project|read:project admin:org"
#
# Syntax: whitespace-separated requirements. A requirement is one scope name,
# or several joined by `|` meaning "any one of these satisfies it". The
# alternation exists because `project` and `read:project` are separate grants
# that GitHub reports separately, and either one proves the token was minted
# with Projects access in mind — while `gh auth refresh` is asked for BOTH, so
# that the credential this repo mints can also write the board.
#
# Why these four:
#   repo      — the PR/issue surface the Dev Loop runs on
#   workflow  — pushing branches that touch .github/workflows/
#   project   — the claim lifecycle's board writes (read:project alone is
#               read-only; status.sh reports that distinction separately)
#
# Deliberately NOT a check of what the token can do — scopes are a server-side
# property of the credential and this file only names what to compare against.

# shellcheck shell=bash

GH_REQUIRED_SCOPES="${GH_REQUIRED_SCOPES:-repo workflow project|read:project}"

# gh_scopes_request_list — the comma-separated list to hand
# `gh auth login --scopes` / `gh auth refresh -s`.
#
# Every alternative of every requirement is requested, not just one: asking for
# `project` alone would satisfy the check while leaving the vendored track-work
# skill's `read:project` hint unmet, and the two remedy strings that used to
# disagree (issue #596) are exactly what one derived list removes.
gh_scopes_request_list() {
    local req alt out=""
    for req in $(gh_scopes__words "${GH_REQUIRED_SCOPES}"); do
        for alt in $(gh_scopes__alternatives "${req}"); do
            case ",${out}," in *",${alt},"*) continue ;; esac
            out="${out:+${out},}${alt}"
        done
    done
    printf '%s' "${out}"
}

# gh_scopes_missing SCOPE_LINE — print the requirements SCOPE_LINE does not
# satisfy, whitespace-separated; print nothing when it satisfies them all.
#
# SCOPE_LINE is the `Token scopes:` line of `gh auth status`, whose scopes are
# quoted (`… 'gist', 'project', 'repo'`). Matching on the quotes is what keeps
# `project` from also matching `read:project` and vice versa — they are
# different grants, and the alternation above is how a caller says either will
# do.
#
# A line with no quoted scopes at all is a fine-grained PAT or an App
# installation token, which carries permissions rather than OAuth scopes. That
# is NOT a missing-scope condition and callers must classify it as unknown —
# this function reports every requirement as missing for such a line, so guard
# the call, as status.sh does.
gh_scopes_missing() {
    local line="$1" req alt satisfied out=""
    for req in $(gh_scopes__words "${GH_REQUIRED_SCOPES}"); do
        satisfied=false
        for alt in $(gh_scopes__alternatives "${req}"); do
            case "${line}" in
            *"'${alt}'"*)
                satisfied=true
                break
                ;;
            esac
        done
        [ "${satisfied}" = true ] || out="${out:+${out} }${req}"
    done
    printf '%s' "${out}"
}

# gh_scopes_human "req req…" — render requirements for a human: the `|`
# alternation becomes " or ", and requirements are comma-separated.
gh_scopes_human() {
    local req out=""
    for req in $(gh_scopes__words "$1"); do
        out="${out:+${out}, }$(printf '%s' "${req}" | sed 's/|/ or /g')"
    done
    printf '%s' "${out}"
}

# Internal splitters. Word-splitting is the intent here, so it happens in one
# named place with the shellcheck waiver attached to it rather than at four
# call sites.
gh_scopes__words() {
    # shellcheck disable=SC2086 # deliberate: the list is whitespace-separated
    printf '%s\n' $1
}

gh_scopes__alternatives() {
    printf '%s' "$1" | tr '|' ' '
}
