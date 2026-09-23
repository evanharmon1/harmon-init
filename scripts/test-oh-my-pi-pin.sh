#!/usr/bin/env bash
# test-oh-my-pi-pin.sh — fail fast when OH_MY_PI_VERSION has moved past the
# hand-verified `# verified-for:` marker, OR when the version and marker were
# both bumped without either architecture's hash actually moving — instead of
# discovering it only after a ~22-minute devcontainer image build reaches
# `sha256sum --check` (harmon-init#1338).
#
# oh-my-pi ships unsigned release binaries, so OH_MY_PI_SHA256_AMD64/ARM64 in
# images/devcontainer/Dockerfile are intentionally NOT Renovate-managed: a
# person must download each release, check its release notes and provenance,
# and compute the sha256 of both architectures before the hashes (and the
# `# verified-for:` marker directly above them) can move. This guard never
# validates that the hashes are CORRECT (that stays manual, by design) — it
# only checks that the marker's version matches OH_MY_PI_VERSION, and that
# both hashes actually changed whenever the version did, so moving the marker
# by hand without re-verifying either hash cannot pass silently.
#
# Base ref for the drift check: OH_MY_PI_PIN_BASE if set; on a pull request
# exactly origin/$GITHUB_BASE_REF (never a fallback — a wrong base would hide
# an unmoved hash); otherwise the first of origin/HEAD, origin/main,
# origin/master. Mirrors scripts/test-tool-pin-pairs.sh.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

dockerfile="images/devcontainer/Dockerfile"

# extract <ARG name> <file content>
extract() {
    printf '%s\n' "$2" | sed -n "s/^ARG $1=\\(.*\\)\$/\\1/p"
}

content="$(cat "$dockerfile")"
version="$(extract OH_MY_PI_VERSION "$content")"
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

release_url="https://github.com/can1357/oh-my-pi/releases/tag/v${version}"
remediation() {
    cat >&2 <<EOF

oh-my-pi ships unsigned release binaries, so OH_MY_PI_SHA256_AMD64/ARM64 are
intentionally not Renovate-managed. Before merging this bump:
  1. Read the release notes and provenance: ${release_url}
  2. Download and sha256sum each binary asset (not the source archives):
       https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-linux-x64   (amd64)
       https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-linux-arm64 (arm64)
  3. Update OH_MY_PI_SHA256_AMD64 / OH_MY_PI_SHA256_ARM64 in ${dockerfile}
     and move the '# verified-for: ${verified}' marker to '# verified-for: ${version}'
EOF
}

if [ "$version" != "$verified" ]; then
    echo "oh-my-pi-pin: OH_MY_PI_VERSION (${version}) has moved past the hand-verified release (${verified}) in ${dockerfile}." >&2
    remediation
    exit 1
fi

# The marker matches, but a marker moved by hand without actually
# re-verifying either hash is exactly the failure mode this guard exists to
# catch: whenever the version changed since a resolvable base commit, both
# hashes must have changed too.
amd64="$(extract OH_MY_PI_SHA256_AMD64 "$content")"
arm64="$(extract OH_MY_PI_SHA256_ARM64 "$content")"

if [ -n "${OH_MY_PI_PIN_BASE:-}" ]; then
    candidates=("$OH_MY_PI_PIN_BASE")
elif [ -n "${GITHUB_BASE_REF:-}" ]; then
    candidates=("origin/${GITHUB_BASE_REF}")
else
    candidates=(origin/HEAD origin/main origin/master)
fi
base_ref=
for candidate in "${candidates[@]}"; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
        base_ref="$candidate"
        break
    fi
done
if [ -n "${OH_MY_PI_PIN_BASE:-}" ] && [ "$base_ref" != "$OH_MY_PI_PIN_BASE" ]; then
    echo "oh-my-pi-pin: OH_MY_PI_PIN_BASE=${OH_MY_PI_PIN_BASE} does not resolve to a commit" >&2
    exit 1
fi
merge_base=
if [ -n "$base_ref" ]; then
    merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
fi
if [ -z "$merge_base" ]; then
    if [ -n "${GITHUB_BASE_REF:-}" ]; then
        echo "oh-my-pi-pin: no merge-base with ${base_ref:-origin/${GITHUB_BASE_REF}} on a pull request, so a version bump that left a hash behind cannot be detected — check out with fetch-depth: 0" >&2
        exit 1
    fi
    echo "oh-my-pi-pin OK: OH_MY_PI_VERSION and the verified-for marker both name ${version} (drift check skipped: no base ref resolved)"
    exit 0
fi

base_content="$(git show "${merge_base}:${dockerfile}" 2>/dev/null || true)"
if [ -z "$base_content" ]; then
    echo "oh-my-pi-pin OK: OH_MY_PI_VERSION and the verified-for marker both name ${version} (drift check skipped: ${dockerfile} did not exist at ${merge_base})"
    exit 0
fi
base_version="$(extract OH_MY_PI_VERSION "$base_content")"

if [ "$version" = "$base_version" ]; then
    echo "oh-my-pi-pin OK: OH_MY_PI_VERSION and the verified-for marker both name ${version}; unchanged since ${base_ref}"
    exit 0
fi

base_amd64="$(extract OH_MY_PI_SHA256_AMD64 "$base_content")"
base_arm64="$(extract OH_MY_PI_SHA256_ARM64 "$base_content")"
stale=()
[ "$amd64" != "$base_amd64" ] || stale+=("OH_MY_PI_SHA256_AMD64")
[ "$arm64" != "$base_arm64" ] || stale+=("OH_MY_PI_SHA256_ARM64")

if [ "${#stale[@]}" -gt 0 ]; then
    stale_joined="$(
        IFS=,
        echo "${stale[*]}"
    )"
    echo "oh-my-pi-pin: OH_MY_PI_VERSION changed ${base_version} -> ${version} but ${stale_joined} did not move since ${base_ref} — the '# verified-for:' marker was updated without re-verifying the hash." >&2
    remediation
    exit 1
fi

echo "oh-my-pi-pin OK: OH_MY_PI_VERSION, the verified-for marker, and both hashes moved together (${base_version} -> ${version}, drift checked against ${base_ref})"
