#!/usr/bin/env bash
# Set a GitHub repository secret from stdin without passing the secret in shell
# history, environment variables, or process arguments.
set -euo pipefail

fail() {
    echo "secret:set:gh: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
Usage:
  secret-producing-command | task secret:set:gh NAME=<secret-name> REPO=<owner/repo>

The secret value is read from stdin. NAME and REPO identify the GitHub
repository secret to create or update.
USAGE
}

name="${NAME:-}"
repo="${REPO:-}"

if [ -z "$name" ] || [ -z "$repo" ]; then
    usage
    fail "NAME and REPO are required"
fi

if [ -t 0 ]; then
    usage
    fail "secret must be piped on stdin"
fi

command -v gh >/dev/null 2>&1 || fail "gh CLI is required"
command -v perl >/dev/null 2>&1 || fail "perl is required"

perl -0777 -e '
    my $secret = <STDIN>;
    $secret =~ s/\r?\n\z//;
    die "stdin secret is empty\n" if $secret eq "";
    print $secret;
' | gh secret set "$name" --repo "$repo" >/dev/null

echo "Updated GitHub secret '$name' in '$repo'."
