#!/usr/bin/env bash
# test-oh-my-pi-pin.sh — fail fast when OH_MY_PI_VERSION has moved past the
# hand-verified `# verified-for:` marker, instead of discovering it only after
# a ~22-minute devcontainer image build reaches `sha256sum --check`
# (harmon-init#1338).
#
# oh-my-pi ships unsigned release binaries, so OH_MY_PI_SHA256_AMD64/ARM64 in
# images/devcontainer/Dockerfile are intentionally NOT Renovate-managed: a
# person must download each release, check its release notes and provenance,
# and compute the sha256 of both architectures before the hashes (and the
# `# verified-for:` marker directly above them) can move. This guard only
# checks that the marker's version matches OH_MY_PI_VERSION — it never
# touches the hashes themselves.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

dockerfile="images/devcontainer/Dockerfile"

version="$(sed -n 's/^ARG OH_MY_PI_VERSION=\(.*\)$/\1/p' "$dockerfile")"
if [ -z "$version" ]; then
    echo "oh-my-pi-pin: could not find 'ARG OH_MY_PI_VERSION=' in ${dockerfile}" >&2
    exit 1
fi

# The marker must sit directly above the amd64 hash ARG — anywhere else is
# not proof that it was reviewed alongside that specific pin.
marker_line="$(awk '
    /^ARG OH_MY_PI_SHA256_AMD64=/ { print prev; exit }
    { prev = $0 }
' "$dockerfile")"
verified="$(printf '%s\n' "$marker_line" | sed -n 's/^# verified-for: \(.*\)$/\1/p')"

if [ -z "$verified" ]; then
    echo "oh-my-pi-pin: no '# verified-for: <version>' marker directly above 'ARG OH_MY_PI_SHA256_AMD64=' in ${dockerfile}" >&2
    exit 1
fi

if [ "$version" != "$verified" ]; then
    cat >&2 <<EOF
oh-my-pi-pin: OH_MY_PI_VERSION (${version}) has moved past the hand-verified release (${verified}) in ${dockerfile}.

oh-my-pi ships unsigned release binaries, so OH_MY_PI_SHA256_AMD64/ARM64 are
intentionally not Renovate-managed. Before merging this bump:
  1. Download the ${version} release: https://github.com/can1357/oh-my-pi/releases/tag/v${version}
  2. Check its release notes and provenance
  3. Compute the sha256 of both the amd64 and arm64 release archives
  4. Update OH_MY_PI_SHA256_AMD64 / OH_MY_PI_SHA256_ARM64 in ${dockerfile}
     and move the '# verified-for: ${verified}' marker to '# verified-for: ${version}'
EOF
    exit 1
fi

echo "oh-my-pi-pin OK: OH_MY_PI_VERSION and the verified-for marker both name ${version}"
