#!/usr/bin/env bash
# Offline tests for the image manifest, publication reference, and rolling pin sync.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
cases=0

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

pass() {
    cases=$((cases + 1))
}

sha_a=1111111111111111111111111111111111111111
digest_a=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
digest_b=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
child_amd64=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
child_arm64=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

# Manifest generation is deterministic, valid JSON, and rejects unsafe values.
manifest_dir="$tmp_root/manifest"
HARMON_MANIFEST_DIR="$manifest_dir" \
    images/devcontainer/generate-manifest.sh "$sha_a" amd64 task=3.52.0 codex=0.145.0
jq -e --arg sha "$sha_a" \
    '.schemaVersion == 1 and .image.revision == $sha and .tools.task == "3.52.0"' \
    "$manifest_dir/manifest.json" >/dev/null || fail "generated manifest has the wrong contract"
if HARMON_MANIFEST_DIR="$manifest_dir" \
    images/devcontainer/generate-manifest.sh bad amd64 task=3.52.0 >/dev/null 2>&1; then
    fail "manifest generator accepted a malformed revision"
fi
pass

# The IaC producer contract puts only standalone Terraform tooling in the
# shared image. Ansible's project-owned Python environment and on-demand Checkov
# scans must not become transitive shared-image dependencies.
producer_dockerfile="images/devcontainer/Dockerfile"
for tool in terraform tflint; do
    grep -q "ARG $(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_VERSION=" "$producer_dockerfile" ||
        fail "shared image does not pin ${tool}"
    grep -q "\"${tool}=\${$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_VERSION}\"" "$producer_dockerfile" ||
        fail "shared image does not record ${tool} in its manifest"
    grep -q "run_version ${tool} ${tool}" images/devcontainer/smoke.sh ||
        fail "shared image smoke test does not execute ${tool}"
done
grep -q -- '--status-fd 1 --verify' "$producer_dockerfile" ||
    fail "Terraform checksum verification does not expose the signer identity"
grep -q '\$NF == "C874011F0AB405110D02105534365D9472D7468F"' "$producer_dockerfile" ||
    fail "Terraform checksum verification does not require HashiCorp's pinned primary fingerprint"
template_devcontainer="template/[% if devcontainer %].devcontainer[% endif %]/devcontainer.json.jinja"
if grep -q 'devcontainers/features/terraform:1' "$template_devcontainer"; then
    fail "rendered devcontainers can override the shared image's pinned Terraform tooling"
fi
if grep -Ev '^[[:space:]]*#' "$producer_dockerfile" |
    grep -Eqi '(^|[^[:alnum:]_-])(ansible|checkov)([^[:alnum:]_-]|$)'; then
    fail "shared image adds project-local Ansible or on-demand Checkov"
fi
pass

# Pure reference formatting rejects floating/malformed inputs.
want="ghcr.io/evanharmon1/harmon-devcontainer:sha-${sha_a}@${digest_a}"
got="$(scripts/publish-devcontainer-image.sh reference "$sha_a" "$digest_a")"
[ "$got" = "$want" ] || fail "publisher rendered '$got', expected '$want'"
if scripts/publish-devcontainer-image.sh reference "$sha_a" latest >/dev/null 2>&1; then
    fail "publisher accepted a floating digest"
fi
pass

# Push and scheduled reconciliation resolve the same producer-path commit even
# when a multi-commit push ends in an unrelated commit.
source_fixture="$tmp_root/source-fixture"
mkdir -p "$source_fixture/scripts" "$source_fixture/images/devcontainer" \
    "$source_fixture/.github/workflows"
cp scripts/publish-devcontainer-image.sh "$source_fixture/scripts/"
cp .github/workflows/publish-harmon-devcontainer.yml "$source_fixture/.github/workflows/"
printf 'FROM scratch\n' >"$source_fixture/images/devcontainer/Dockerfile"
git -C "$source_fixture" init -b main >/dev/null
git -C "$source_fixture" config user.name test
git -C "$source_fixture" config user.email test@example.invalid
git -C "$source_fixture" add .
git -C "$source_fixture" commit -m producer >/dev/null
producer_source="$(git -C "$source_fixture" rev-parse HEAD)"
printf 'unrelated\n' >"$source_fixture/README.md"
git -C "$source_fixture" add README.md
git -C "$source_fixture" commit -m unrelated-tail >/dev/null
push_head="$(git -C "$source_fixture" rev-parse HEAD)"
push_source="$(cd "$source_fixture" && ./scripts/publish-devcontainer-image.sh source push "$push_head")"
scheduled_source="$(cd "$source_fixture" && ./scripts/publish-devcontainer-image.sh source schedule "$push_head")"
[ "$push_source" = "$producer_source" ] || fail "push resolved unrelated tail as the image source"
[ "$scheduled_source" = "$producer_source" ] || fail "schedule disagreed with the push image source"
pass

# The offline automation suite is a required pre-merge check and runs before
# either registry credentials or the App write token exist in publishing jobs.
ci_automation_line="$(grep -n 'run: task test:devcontainer:image:automation' \
    .github/workflows/build.yml | cut -d: -f1)"
publish_automation_line="$(grep -n 'run: ./scripts/test-devcontainer-image-automation.sh' \
    .github/workflows/publish-harmon-devcontainer.yml | cut -d: -f1)"
registry_token_line="$(grep -n 'docker/login-action@' \
    .github/workflows/publish-harmon-devcontainer.yml | cut -d: -f1)"
prepare_line="$(grep -n 'sync-devcontainer-image.sh prepare' \
    .github/workflows/publish-harmon-devcontainer.yml | cut -d: -f1)"
token_line="$(grep -n 'actions/create-github-app-token@' \
    .github/workflows/publish-harmon-devcontainer.yml | tail -1 | cut -d: -f1)"
publish_line="$(grep -n 'sync-devcontainer-image.sh publish' \
    .github/workflows/publish-harmon-devcontainer.yml | cut -d: -f1)"
if [ -z "$ci_automation_line" ] || [ -z "$publish_automation_line" ] ||
    [ "$publish_automation_line" -ge "$registry_token_line" ]; then
    fail "automation tests are not enforced before image publication"
fi
if [ "$prepare_line" -ge "$token_line" ] || [ "$token_line" -ge "$publish_line" ]; then
    fail "write token is not isolated between prepare and publish steps"
fi
pass

# The sync-pin bundle must be staged OUTSIDE the checkout: an artifact
# downloaded into the worktree survives as an untracked file, and the
# token-bearing publish phase fails closed on any dirty tree — which killed
# the first ready=true sync-pin (run 30722269327).
grep -q 'path: ${{ runner.temp }}/prepared-pin' \
    .github/workflows/publish-harmon-devcontainer.yml ||
    fail "sync-pin downloads the prepared bundle into the repository checkout"
grep -qF 'git fetch "${RUNNER_TEMP}/prepared-pin/prepared-pin.bundle"' \
    .github/workflows/publish-harmon-devcontainer.yml ||
    fail "bundle import does not read from the runner temp staging path"
pass

# Fixture: real git state and helper, stubbed registry/GitHub/task boundaries.
fixture="$tmp_root/fixture"
origin="$tmp_root/origin.git"
bin_dir="$tmp_root/bin"
mkdir -p "$fixture/scripts" "$fixture/.devcontainer" \
    "$fixture/template/[% if devcontainer %].devcontainer[% endif %]" "$bin_dir"
cp scripts/sync-devcontainer-image.sh scripts/publish-devcontainer-image.sh "$fixture/scripts/"

cat >"$bin_dir/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${DOCKER_STUB_LOG:-}" ]; then
    printf '%s\n' "\$*" >>"\$DOCKER_STUB_LOG"
fi
if [ "\${1:-} \${2:-} \${3:-}" = "buildx imagetools inspect" ]; then
    if [ "\${DOCKER_STUB_MODE:-}" = transient ]; then
        echo "ERROR: registry request timed out" >&2
        exit 1
    fi
    if [ "\${DOCKER_STUB_MODE:-}" = missing-once ] && \
        [ ! -e "\${DOCKER_STUB_STATE:?}" ]; then
        touch "\$DOCKER_STUB_STATE"
        echo "ERROR: manifest unknown" >&2
        exit 1
    fi
    if [ "\${DOCKER_STUB_MODE:-}" = missing-arm ]; then
cat <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"${digest_a}","manifests":[{"digest":"${child_amd64}","platform":{"os":"linux","architecture":"amd64"}}]}
JSON
        exit 0
    fi
    if [ "\${DOCKER_STUB_MODE:-}" = duplicate-child ]; then
cat <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"${digest_a}","manifests":[{"digest":"${child_amd64}","platform":{"os":"linux","architecture":"amd64"}},{"digest":"${child_amd64}","platform":{"os":"linux","architecture":"arm64"}}]}
JSON
        exit 0
    fi
cat <<'JSON'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"${digest_a}","manifests":[{"digest":"${child_amd64}","platform":{"os":"linux","architecture":"amd64"}},{"digest":"${child_arm64}","platform":{"os":"linux","architecture":"arm64"}}]}
JSON
    exit 0
fi
if [ "\${1:-}" = "pull" ]; then
    if [ -z "\${DOCKER_CONFIG:-}" ] || [ -s "\${DOCKER_CONFIG}/config.json" ]; then
        echo "ERROR: stub pull ran with ambient registry credentials" >&2
        exit 1
    fi
fi
if [ "\${1:-} \${2:-}" = "image inspect" ]; then
    printf '%s\n' "\${DOCKER_STUB_REVISION:-}"
fi
EOF
cat >"$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"pr list") [ -z "${GH_STUB_PR_NUMBER:-}" ] || printf '%s\n' "$GH_STUB_PR_NUMBER" ;;
"pr create" | "pr edit") printf '%s\n' "$*" >>"${GH_STUB_LOG:?}" ;;
*) exit 0 ;;
esac
EOF
cat >"$bin_dir/task" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TASK_STUB_LOG:?}"
EOF
chmod +x "$bin_dir/docker" "$bin_dir/gh" "$bin_dir/task" "$fixture/scripts/"*.sh

cat >"$tmp_root/fixture_dockerfile" <<'EOF'
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04
USER vscode
EOF
cp "$tmp_root/fixture_dockerfile" "$fixture/.devcontainer/Dockerfile"
cp "$tmp_root/fixture_dockerfile" "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile"

git init --bare "$origin" >/dev/null
git -C "$fixture" init -b main >/dev/null
git -C "$fixture" config user.name test
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" remote add origin "$origin"
git -C "$fixture" add .
git -C "$fixture" commit -m initial >/dev/null
old_source="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" push -u origin main >/dev/null

run_fixture() {
    (
        cd "$fixture"
        # Sanitize inherited env: the sync-harmon-devkit workflow exports
        # GH_APP_SLUG job-wide, which would leak into the fixture and drive
        # sync-devcontainer-image.sh's App-identity path against the gh stub
        # (die "unexpected App bot id ''") — exactly as it failed in CI.
        env -u GH_TOKEN -u GITHUB_TOKEN -u GH_APP_SLUG \
            PATH="$bin_dir:$PATH" GH_STUB_LOG="$tmp_root/gh.log" TASK_STUB_LOG="$tmp_root/task.log" \
            "$@"
    )
}

sync_fixture() {
    run_fixture ./scripts/sync-devcontainer-image.sh prepare "$1" "$2"
    run_fixture ./scripts/sync-devcontainer-image.sh publish "$1" "$2"
}

# Bootstrap is destructive by design, so it refuses even parity-preserving
# uncommitted edits rather than replacing them with the thin-consumer skeleton.
printf '\nRUN echo unsaved\n' >>"$fixture/.devcontainer/Dockerfile"
printf '\nRUN echo unsaved\n' \
    >>"$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile"
if run_fixture ./scripts/sync-devcontainer-image.sh bootstrap \
    "$old_source" "$digest_a" >/dev/null 2>&1; then
    fail "bootstrap overwrote uncommitted consumer edits"
fi
grep -q '^RUN echo unsaved$' "$fixture/.devcontainer/Dockerfile" ||
    fail "failed bootstrap did not preserve the root edit"
cp "$tmp_root/fixture_dockerfile" "$fixture/.devcontainer/Dockerfile"
cp "$tmp_root/fixture_dockerfile" \
    "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile"
pass

# Bootstrap is explicit, writes byte-identical twins, and then becomes idempotent.
run_fixture ./scripts/sync-devcontainer-image.sh bootstrap "$old_source" "$digest_a" >/dev/null
cmp -s "$fixture/.devcontainer/Dockerfile" \
    "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile" ||
    fail "bootstrap did not write identical consumer twins"
pinned="$(run_fixture ./scripts/sync-devcontainer-image.sh pinned)"
[ "$pinned" = "$old_source $digest_a" ] || fail "unexpected bootstrap pin '$pinned'"
before="$(git -C "$fixture" diff)"
run_fixture ./scripts/sync-devcontainer-image.sh apply "$old_source" "$digest_a" >/dev/null
[ "$(git -C "$fixture" diff)" = "$before" ] || fail "idempotent apply changed the consumer"

# Pin changes replace only FROM and preserve identical repository extensions.
printf '\nRUN echo repository-extension\n' >>"$fixture/.devcontainer/Dockerfile"
printf '\nRUN echo repository-extension\n' \
    >>"$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile"
run_fixture ./scripts/sync-devcontainer-image.sh apply "$old_source" "$digest_a" >/dev/null
grep -q '^RUN echo repository-extension$' "$fixture/.devcontainer/Dockerfile" ||
    fail "pin update erased a repository-specific extension"
pass

# A malformed/twin-mismatched consumer fails closed.
printf '# drift\n' >>"$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile"
if run_fixture ./scripts/sync-devcontainer-image.sh pinned >/dev/null 2>&1; then
    fail "pinned accepted divergent consumer twins"
fi
cp "$fixture/.devcontainer/Dockerfile" \
    "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile"
pass

# Registry validation requires exact digest agreement and both architectures.
if (
    cd "$fixture"
    PATH="$bin_dir:$PATH" DOCKER_STUB_MODE=missing-arm \
        ./scripts/publish-devcontainer-image.sh validate-index "$old_source" "$digest_a"
) >/dev/null 2>&1; then
    fail "manifest validation accepted an index without arm64"
fi
if run_fixture ./scripts/publish-devcontainer-image.sh validate-index \
    "$old_source" "$digest_b" >/dev/null 2>&1; then
    fail "manifest validation accepted a digest mismatch"
fi
pass

# A transient inspect failure is not evidence that an immutable tag is absent;
# publication must fail closed without attempting a build/push.
docker_log="$tmp_root/docker.log"
: >"$docker_log"
if run_fixture env DOCKER_STUB_MODE=transient DOCKER_STUB_LOG="$docker_log" \
    ./scripts/publish-devcontainer-image.sh publish "$old_source" >/dev/null 2>&1; then
    fail "publisher treated a transient inspect failure as an absent tag"
fi
if grep -q '^buildx build' "$docker_log"; then
    fail "publisher attempted a build after a transient inspect failure"
fi
pass

# An explicit manifest-unknown response is the only probe failure allowed to
# enter the initial publication path.
docker_state="$tmp_root/docker-state"
: >"$docker_log"
run_fixture env DOCKER_STUB_MODE=missing-once DOCKER_STUB_STATE="$docker_state" \
    DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_REVISION="$old_source" \
    ./scripts/publish-devcontainer-image.sh publish "$old_source" >/dev/null
grep -q '^buildx build' "$docker_log" || fail "absent immutable tag did not trigger publication"
pass

# An existing-tag reconciliation rerun validates without any push and pulls
# each platform anonymously by its distinct child-manifest digest — never
# through the shared top-level index reference, whose second platform pull
# fails locally with "cannot overwrite digest".
: >"$docker_log"
run_fixture env DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_REVISION="$old_source" \
    ./scripts/publish-devcontainer-image.sh publish "$old_source" >/dev/null
if grep -q '^buildx build' "$docker_log"; then
    fail "existing-tag rerun attempted a build/push"
fi
grep -q "^pull --platform linux/amd64 ghcr.io/evanharmon1/harmon-devcontainer@${child_amd64}\$" \
    "$docker_log" || fail "amd64 validation did not pull its own child digest"
grep -q "^pull --platform linux/arm64 ghcr.io/evanharmon1/harmon-devcontainer@${child_arm64}\$" \
    "$docker_log" || fail "arm64 validation did not pull its own child digest"
if grep '^pull ' "$docker_log" | grep -q "@${digest_a}"; then
    fail "validation pulled through the top-level index digest"
fi
pass

# An index that resolves both platforms to one child digest fails closed.
if run_fixture env DOCKER_STUB_MODE=duplicate-child DOCKER_STUB_REVISION="$old_source" \
    ./scripts/publish-devcontainer-image.sh validate "$old_source" "$digest_a" >/dev/null 2>&1; then
    fail "validation accepted duplicate per-platform child digests"
fi
pass

# The credential-bearing publish phase must not invoke registry validation;
# that check belongs to the earlier unprivileged jobs.
publish_body="$(sed -n '/^cmd_publish_prepared()/,/^}/p' scripts/sync-devcontainer-image.sh)"
if printf '%s\n' "$publish_body" | grep -q 'validate_remote'; then
    fail "token-bearing publish phase still invokes registry validation"
fi
pass

# A failure between the two writes restores both original consumers.
root_before="$(git hash-object "$fixture/.devcontainer/Dockerfile")"
template_before="$(git hash-object "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile")"
if run_fixture env SYNC_DEVCONTAINER_TEST_FAIL_AFTER_ROOT_WRITE=true \
    ./scripts/sync-devcontainer-image.sh apply "$old_source" "$digest_a" >/dev/null 2>&1; then
    fail "fault-injected twin update unexpectedly succeeded"
fi
[ "$(git hash-object "$fixture/.devcontainer/Dockerfile")" = "$root_before" ] ||
    fail "root consumer was not restored after a partial update"
[ "$(git hash-object "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile")" = "$template_before" ] ||
    fail "template consumer was not restored after a partial update"
pass

# A termination signal between twin moves restores both consumers and exits
# nonzero rather than resuming after the signal handler.
if run_fixture env SYNC_DEVCONTAINER_TEST_SIGNAL_AFTER_ROOT_WRITE=true \
    ./scripts/sync-devcontainer-image.sh apply "$old_source" "$digest_a" >/dev/null 2>&1; then
    fail "signal-injected twin update unexpectedly succeeded"
fi
[ "$(git hash-object "$fixture/.devcontainer/Dockerfile")" = "$root_before" ] ||
    fail "root consumer was not restored after termination"
[ "$(git hash-object "$fixture/template/[% if devcontainer %].devcontainer[% endif %]/Dockerfile")" = "$template_before" ] ||
    fail "template consumer was not restored after termination"
pass

# Commit the bootstrapped floor, advance main, and test one rolling PR update.
git -C "$fixture" add .
git -C "$fixture" commit -m bootstrap >/dev/null
git -C "$fixture" commit --allow-empty -m producer-update >/dev/null
new_source="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" push origin main >/dev/null

# The Docker stub returns digest_a; use that digest for registry agreement.
sync_fixture "$new_source" "$digest_a" >/dev/null
git --git-dir="$origin" show "refs/heads/bot/sync-harmon-devcontainer:.devcontainer/Dockerfile" |
    grep -q "sha-${new_source}@${digest_a}" || fail "rolling branch did not advance to the new source"
[ -s "$tmp_root/gh.log" ] || fail "rolling update did not create/update a PR"
[ -s "$tmp_root/task.log" ] || fail "rolling update skipped verification"
pass

# An exact-tree retry repairs stale PR metadata instead of returning early.
git -C "$fixture" switch main >/dev/null
: >"$tmp_root/gh.log"
run_fixture ./scripts/sync-devcontainer-image.sh prepare "$new_source" "$digest_a" >/dev/null
run_fixture env GH_STUB_PR_NUMBER=7 \
    ./scripts/sync-devcontainer-image.sh publish "$new_source" "$digest_a" >/dev/null
grep -q '^pr edit 7 ' "$tmp_root/gh.log" ||
    fail "exact-tree retry did not repair open PR metadata"
pass

# A delayed event cannot roll the open branch back to its older source commit.
git -C "$fixture" switch main >/dev/null
if run_fixture ./scripts/sync-devcontainer-image.sh prepare "$old_source" "$digest_a" >/dev/null 2>&1; then
    fail "rolling sync accepted a stale source commit"
fi
pass

# A merged pin is a clean no-op even while the old rolling branch still exists.
git -C "$fixture" merge --ff-only origin/bot/sync-harmon-devcontainer >/dev/null
git -C "$fixture" push origin main >/dev/null
sync_fixture "$new_source" "$digest_a" >/dev/null
pass

# A concurrent writer that advances the remote branch makes the lease reject
# this stale publisher instead of overwriting the intervening update.
git -C "$fixture" commit --allow-empty -m newer-producer-update >/dev/null
newest_source="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" push origin main >/dev/null
mkdir -p "$fixture/.git/hooks"
cat >"$fixture/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
set -euo pipefail
git --git-dir="$origin" update-ref refs/heads/bot/sync-harmon-devcontainer "$newest_source"
EOF
chmod +x "$fixture/.git/hooks/pre-push"
run_fixture ./scripts/sync-devcontainer-image.sh prepare "$newest_source" "$digest_a" >/dev/null
if run_fixture ./scripts/sync-devcontainer-image.sh publish "$newest_source" "$digest_a" >/dev/null 2>&1; then
    fail "stale publisher overwrote a concurrent rolling-branch update"
fi
pass

echo "devcontainer image automation: ${cases} offline cases passed"
