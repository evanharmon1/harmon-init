#!/usr/bin/env bash
# apt-core.sh — the distribution packages the core tier needs, in the shared
# image and on a stock Ubuntu 24.04 VM alike.
#
# These carry no version pin in either place: they are Ubuntu 24.04's packaged
# versions, which is deliberate for git. A devkit test that failed on Ubuntu's
# git 2.43 is fixed in the test (evanharmon1/harmon-devkit#1208), not by
# installing a git the shared image does not have — the git-core PPA
# (ppa.launchpadcontent.net) is denied on the remote VM anyway, so a newer git
# would make the two environments diverge on the one axis this file exists to
# keep identical.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Extra packages may be passed as arguments: the shared image adds its own
# interactive-terminal set that way, so both layers share ONE `apt-get update`
# and the core list stays the thing the remote path is promised.
#
# jq, shellcheck, yamllint are dev-loop gate tools; the rest are what the
# download-and-verify path itself needs (xz-utils for the Node tarball).
#
# python3 is listed even though `yamllint` already pulls it in transitively
# (verified: exactly this list on a bare ubuntu:24.04 leaves python3 3.12.3 at
# /usr/bin/python3). The gate invokes the interpreter DIRECTLY — the pin-pair
# and hygiene guards `task check` runs are python3 scripts — so it is a core
# dependency, not an implementation detail of a linter. Left undeclared, it
# would vanish the day yamllint is replaced by a Go or Rust equivalent, and
# the breakage would land on a remote VM rather than here.
packages="
ca-certificates
curl
file
git
jq
python3
shellcheck
unzip
xz-utils
yamllint
"

harmon_log "apt: the core distribution packages"
export DEBIAN_FRONTEND=noninteractive

# Ask dpkg first. `apt-get update` is a network round-trip and a rewrite of
# /var/lib/apt/lists on every run, so a second run that needs no package must
# not perform it: "a second run performs no installs and changes no versions"
# includes the package index. The status string rather than `dpkg -s`'s exit
# code: that exits 0 for a package removed but not purged. `${1+"$@"}` rather
# than a bare `"$@"`: the latter is an unbound-variable error under `set -u`
# on bash 3.2 when no extras were passed. Unquoted $packages on purpose: a
# newline-separated literal list.
missing=""
# shellcheck disable=SC2086
for pkg in $packages ${1+"$@"}; do
    case "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" in
    "install ok installed") ;;
    *) missing="${missing} ${pkg}" ;;
    esac
done
if [ -z "$missing" ]; then
    harmon_skip "apt: every requested package already present"
else
    apt-get update
    # `apt-get install` exits 0 whether or not it did anything, so read its own
    # summary line to decide whether this counted as a change: that is what
    # makes the bootstrap's second run provably a no-op rather than merely
    # green. Piped through tee (under `pipefail`) rather than captured into a
    # variable, so a failing apt still prints its diagnosis before the script
    # aborts.
    apt_log="$(mktemp)"
    trap 'rm -f "$apt_log"' EXIT
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $packages ${1+"$@"} 2>&1 | tee "$apt_log"
    apt_counts="$(sed -n 's/^\([0-9][0-9]*\) upgraded, \([0-9][0-9]*\) newly installed.*/\1+\2/p' "$apt_log" | head -1)"
    case "${apt_counts:-0+0}" in
    0+0) harmon_skip "apt: every requested package already present" ;;
    *) harmon_changed "apt: ${apt_counts} package(s) upgraded+installed" ;;
    esac
    rm -rf /var/lib/apt/lists/*
fi
