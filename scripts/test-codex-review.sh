#!/usr/bin/env bash
# test-codex-review.sh — offline unit tests for scripts/codex-review.sh's
# target selection and prompt assembly. A stub `codex` on PATH records its
# arguments, so no network, auth, or real review is involved. Guards the
# regression a real adversarial review caught: with no local main/master and
# origin/HEAD pointing at another default branch, the base fallback used to
# strip `origin/` into a nonexistent local ref and silently report nothing
# to review, and the one a real --base run caught: an empty scope reached
# Codex, whose "that diff is empty" reply exited 0 and read as the clean pass
# a capped review loop exits on. Also guards the scope union: a branch holding
# commits AND uncommitted work is the ordinary mid-loop state, and reviewing
# only one half is how a re-run banks a clean pass for a fraction of the
# change. And guards the review guidelines (harmon-init#1530): the table and
# the file are read from the review's BASE revision, never the working tree;
# the unconfigured prompt is held to a golden copy byte for byte; and the
# severity scale's normative statement in docs/review-guidelines.md and the
# prompt's copy are compared, so the two sites can never disagree (#964).
# Run via `task test:codex-review`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# Stub codex: print the invocation so assertions can grep it. STUB_BIG_STDERR
# and STUB_EXIT arm the payload-dump reproduction and a failing CLI; both are
# off unless set, so every other test sees the plain stub.
mkdir -p "${test_tmp}/bin"
cat >"${test_tmp}/bin/codex" <<'CODEXSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGV"
[ -z "${STUB_CWD_FILE:-}" ] || pwd -P >"$STUB_CWD_FILE"
printf 'STUB-ARGS:'
printf ' %s' "$@"
printf '\n'
if [ -n "${STUB_BIG_STDERR:-}" ]; then
    # One over-long stderr line (the models-JSON dump), ordinary narration
    # around it, and a long prose line on stdout standing in for a verdict.
    awk -v n="${STUB_BIG_STDERR}" 'BEGIN { l = ""; while (length(l) < n) l = l "PAYLOAD"; printf "ERROR codex_models_manager: simulated payload dump; body: %s\n", l }' >&2
    echo "short stderr narration" >&2
    awk 'BEGIN { p = ""; while (length(p) < 4000) p = p "verdict prose "; printf "P0 finding: %s\n", p }'
fi
last=''
for arg in "$@"; do last=$arg; done
if [ "$last" = "-" ]; then printf "STUB-PROMPT:%s\n" "$(cat)"; fi
exit "${STUB_EXIT:-0}"
CODEXSTUB
chmod +x "${test_tmp}/bin/codex"
PATH="${test_tmp}/bin:${PATH}"
export PATH
stub_argv="${test_tmp}/stub-argv"
export STUB_ARGV="$stub_argv"

git_t() {
    git -c user.email=test@test -c user.name=test "$@"
}

run_tty() {
    # Gate toggles demand a TTY on stdin; allocate a pty so fixtures can get
    # past the interactivity guard and exercise the logic behind it (macOS
    # and util-linux `script` have incompatible CLIs).
    if [ "$(uname)" = "Darwin" ]; then
        script -q /dev/null "$@" </dev/null
    else
        # printf %q keeps argv intact through script -c's shell reparse
        # (paths with spaces/metacharacters would split under a bare $*).
        script -qec "$(printf '%q ' "$@")" /dev/null </dev/null
    fi
}

# Fixture: an upstream whose default branch is `develop` (not main/master),
# and a clone with only origin/develop plus a feature branch.
git init -q -b develop "${test_tmp}/upstream"
(
    cd "${test_tmp}/upstream"
    mkdir -p scripts/lib
    cp "${repo}/scripts/codex-review.sh" scripts/
    cp "${repo}/scripts/lib/review-scope.sh" scripts/lib/
    cp -R "${repo}/scripts/lib/review-instructions" scripts/lib/
    git add -A
    git_t commit -q -m base
)
git clone -q "${test_tmp}/upstream" "${test_tmp}/clone"
cd "${test_tmp}/clone"
git checkout -q -b feature
echo change >feature.txt
git add feature.txt
git_t commit -q -m work
git branch -q -D develop

run() {
    ./scripts/codex-review.sh "$@" 2>&1
}

standardize_helper=""
for candidate in .claude/skills/standardize-repo/assets/diff-template.sh \
    .agents/skills/standardize-repo/assets/diff-template.sh; do
    if [ -f "$repo/$candidate" ]; then
        standardize_helper="$repo/$candidate"
        break
    fi
done
# Pin-independent stub helpers: whatever skills pin is vendored, prove the
# runner hands a helper its sibling verifier from the merge base only.
sibling_fixture() {
    local fixture="$1" base_verifier="$2" head_verifier="$3" assets
    assets="$fixture/.claude/skills/standardize-repo/assets"
    mkdir -p "$fixture/scripts/lib" "$assets" "$fixture/src"
    cp "${repo}/scripts/codex-review.sh" "$fixture/scripts/"
    cp "${repo}/scripts/lib/review-scope.sh" "$fixture/scripts/lib/"
    cp -R "${repo}/scripts/lib/review-instructions" "$fixture/scripts/lib/"
    cat >"$assets/diff-template.sh" <<'SIBLINGHELPER'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$dir/render-bundle.sh" ]; then
    [ "$#" -gt 1 ] || exit 2
    bash "$dir/render-bundle.sh"
    exit
fi
[ -n "${SIBLING_REQUIRED:-}" ] || { [ "$#" -gt 1 ] && printf 'src/base-excluded.txt\0'; exit; }
echo "FAIL: authenticated render-bundle.sh verifier is unavailable" >&2
exit 2
SIBLINGHELPER
    [ -z "$base_verifier" ] || printf '%s\n' "$base_verifier" >"$assets/render-bundle.sh"
    git init -q -b main "$fixture"
    printf 'old\n' >"$fixture/src/base-excluded.txt"
    printf 'old\n' >"$fixture/src/head-excluded.txt"
    git -C "$fixture" add -A
    git_t -C "$fixture" commit -qm 'test: sibling base'
    git -C "$fixture" checkout -qb update
    [ -z "$head_verifier" ] || printf '%s\n' "$head_verifier" >"$assets/render-bundle.sh"
    printf 'new\n' >"$fixture/src/base-excluded.txt"
    printf 'new\n' >"$fixture/src/head-excluded.txt"
    git -C "$fixture" add -A
    git_t -C "$fixture" commit -qm 'test: sibling head'
}
sibling_review() {
    (cd "$1" && ./scripts/codex-review.sh review --profile standardize --release v2.0.0 \
        --frozen-render "${test_tmp}/unused-bundle" --base main 2>&1)
}

echo "==> standardize materializes the helper's sibling verifier from the merge base, never the head"
sibling_fixture "${test_tmp}/sibling-merge-base" "printf 'src/base-excluded.txt\\0'" \
    "printf 'src/head-excluded.txt\\0'"
out="$(SIBLING_REQUIRED=1 sibling_review "${test_tmp}/sibling-merge-base")" ||
    fail "standardize review with a merge-base sibling verifier failed: $out"
! grep -Fq 'src/base-excluded.txt' <<<"$out" ||
    fail "the merge-base verifier's exclusion was not applied: $out"
grep -Fq 'src/head-excluded.txt' <<<"$out" ||
    fail "the head-edited verifier changed the exclusions: $out"

echo "==> a merge-base helper package without a verifier keeps working"
sibling_fixture "${test_tmp}/sibling-legacy" "" ""
out="$(sibling_review "${test_tmp}/sibling-legacy")" ||
    fail "standardize review with a verifier-less legacy helper failed: $out"
! grep -Fq 'src/base-excluded.txt' <<<"$out" ||
    fail "the legacy helper's exclusion was not applied: $out"

echo "==> a verifier added only at the reviewed head is not used"
sibling_fixture "${test_tmp}/sibling-head-only" "" "printf 'src/head-excluded.txt\\0'"
if out="$(SIBLING_REQUIRED=1 sibling_review "${test_tmp}/sibling-head-only")"; then
    fail "standardize review used a verifier added only at the head: $out"
fi
grep -Fq 'authenticated render-bundle.sh verifier is unavailable' <<<"$out" ||
    fail "head-only verifier refusal did not come from the helper: $out"

standardize_cases=0
# harmon-devkit v0.66.0+ ships render-bundle.sh beside the helper, and that
# helper only trusts a bundle its sibling verifier re-renders from tagged
# templates. Build the fixtures as real producer output there; an older
# helper reads the hand-built bundles as they are.
standardize_verifier=""
standardize_skip="standardize-repo helper is not installed"
if [ -n "$standardize_helper" ] && [ -f "${standardize_helper%/*}/render-bundle.sh" ]; then
    standardize_verifier="${standardize_helper%/*}/render-bundle.sh"
    # Producing and verifying an authenticated bundle both re-render with
    # Copier, which a generated repository's toolchain does not install.
    if ! command -v copier >/dev/null 2>&1; then
        standardize_helper=""
        standardize_skip="the authenticated standardize-repo helper needs copier, which is not installed"
    fi
fi
# Turn a hand-built bundle's previous/current snapshots into a tagged Copier
# template and replace the bundle with render-bundle.sh output over it. Test
# data setup only, mirroring harmon-devkit's own fixture; a no-op without
# the verifier.
standardize_render_bundle() {
    local bundle="$1" target="$2" base="$3" head="$4" release="$5"
    local template_source="${bundle}-template" side tag
    [ -n "$standardize_verifier" ] || return 0
    rm -rf "$template_source"
    mkdir -p "$template_source/template"
    git init -q "$template_source"
    git -C "$template_source" config user.name Fixture
    git -C "$template_source" config user.email fixture@example.invalid
    printf '_subdirectory: template\n_skip_if_exists: [src/repo-owned.txt]\n' \
        >"$template_source/copier.yml"
    for side in previous current; do
        rm -rf "$template_source/template"
        mkdir -p "$template_source/template"
        cp -R "$bundle/$side/." "$template_source/template/"
        : >"$template_source/template/.fixture"
        rm -f "$template_source/template/.copier-answers.yml"
        git -C "$template_source" add -A
        git_t -C "$template_source" commit -qm "test: $side template" --allow-empty
        if [ "$side" = previous ]; then tag=v1.0.0; else tag="$release"; fi
        git -C "$template_source" tag "$tag"
    done
    # The helper's verifier re-renders from HARMON_INIT too, so it stays
    # exported for the review runs that read this bundle.
    export HARMON_INIT="$template_source"
    cp "$bundle/conflict-resolutions.nul" "${bundle}-conflicts.nul"
    rm -rf "$bundle"
    bash "$standardize_verifier" \
        --previous-release v1.0.0 --release "$release" --base "$base" \
        --head "$head" --output "$bundle" "$target" ||
        fail "render-bundle.sh could not produce the $release fixture bundle"
    cp "${bundle}-conflicts.nul" "$bundle/conflict-resolutions.nul"
}
if [ -n "$standardize_helper" ]; then
    echo "==> standardize excludes only pristine frozen-render paths and keeps protected or customized files"
    std_repo="${test_tmp}/standardize-repo"
    std_bundle="${test_tmp}/standardize-bundle"
    mkdir -p "$std_repo/scripts/lib" "$std_repo/.claude/skills/standardize-repo/assets" \
        "$std_repo/src" "$std_bundle/previous/src" "$std_bundle/current/src"
    cp "${repo}/scripts/codex-review.sh" "$std_repo/scripts/"
    cp "${repo}/scripts/lib/review-scope.sh" "$std_repo/scripts/lib/"
    cp -R "${repo}/scripts/lib/review-instructions" "$std_repo/scripts/lib/"
    cp "${standardize_helper}" \
        "$std_repo/.claude/skills/standardize-repo/assets/"
    [ -z "$standardize_verifier" ] ||
        cp "$standardize_verifier" "$std_repo/.claude/skills/standardize-repo/assets/"
    git init -q -b main "$std_repo"
    git -C "$std_repo" config user.email test@test
    git -C "$std_repo" config user.name test
    printf 'template old\n' >"$std_repo/src/generated.txt"
    printf 'repository customization old\n' >"$std_repo/src/customized.txt"
    printf '_commit: v1.0.0\n' >"$std_repo/.copier-answers.yml"
    printf 'conflict old\n' >"$std_repo/src/conflict-resolution.txt"
    printf 'owned old\n' >"$std_repo/src/repo-owned.txt"
    printf 'mode\n' >"$std_repo/src/mode-change.sh"
    chmod 644 "$std_repo/src/mode-change.sh"
    git -C "$std_repo" add -A
    git -C "$std_repo" commit -qm 'test: standardize base'
    std_base="$(git -C "$std_repo" rev-parse HEAD)"
    git -C "$std_repo" checkout -qb update
    printf 'template new\n' >"$std_repo/src/generated.txt"
    printf 'repository customization new\n' >"$std_repo/src/customized.txt"
    printf '_commit: v2.0.0\n' >"$std_repo/.copier-answers.yml"
    printf 'conflict new\n' >"$std_repo/src/conflict-resolution.txt"
    printf 'owned new\n' >"$std_repo/src/repo-owned.txt"
    chmod +x "$std_repo/src/mode-change.sh"
    git -C "$std_repo" add -A
    git -C "$std_repo" commit -qm 'test: standardize update'
    std_head="$(git -C "$std_repo" rev-parse HEAD)"
    printf 'template old\n' >"$std_bundle/previous/src/generated.txt"
    printf 'template new\n' >"$std_bundle/current/src/generated.txt"
    printf 'template old\n' >"$std_bundle/previous/src/customized.txt"
    printf 'template new\n' >"$std_bundle/current/src/customized.txt"
    printf '_commit: v1.0.0\n' >"$std_bundle/previous/.copier-answers.yml"
    printf '_commit: v2.0.0\n' >"$std_bundle/current/.copier-answers.yml"
    printf 'conflict old\n' >"$std_bundle/previous/src/conflict-resolution.txt"
    printf 'conflict new\n' >"$std_bundle/current/src/conflict-resolution.txt"
    printf 'owned old\n' >"$std_bundle/previous/src/repo-owned.txt"
    printf 'owned new\n' >"$std_bundle/current/src/repo-owned.txt"
    printf 'mode\n' >"$std_bundle/previous/src/mode-change.sh"
    printf 'mode\n' >"$std_bundle/current/src/mode-change.sh"
    chmod 644 "$std_bundle/previous/src/mode-change.sh" "$std_bundle/current/src/mode-change.sh"
    printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.0.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
        "$std_base" "$std_head" >"$std_bundle/metadata"
    printf 'src/conflict-resolution.txt\0' >"$std_bundle/conflict-resolutions.nul"
    printf 'src/repo-owned.txt\0' >"$std_bundle/repo-owned.nul"
    standardize_render_bundle "$std_bundle" "$std_repo" "$std_base" "$std_head" v2.0.0
    printf 'src/generated.txt\0' >"${test_tmp}/standardize-expected.nul"
    bash "$std_repo/.claude/skills/standardize-repo/assets/diff-template.sh" \
        --review-exclusions --release v2.0.0 --frozen-render "$std_bundle" \
        --base "$std_base" --head "$std_head" "$std_repo" \
        >"${test_tmp}/standardize-actual.nul" || fail "frozen-render exclusion computation failed"
    cmp -s "${test_tmp}/standardize-expected.nul" "${test_tmp}/standardize-actual.nul" ||
        fail "the exclusion list must contain only the pristine rendered file"
    : >"$stub_argv"
    out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
        --release v2.0.0 --frozen-render "$std_bundle" --base "$std_base" 2>&1)" ||
        fail "standardize Codex review failed: $out"
    ! grep -Fq 'src/generated.txt' <<<"$out" || fail "pristine template path remained in the review manifest: $out"
    for kept_path in src/customized.txt .copier-answers.yml src/conflict-resolution.txt \
        src/repo-owned.txt src/mode-change.sh; do
        grep -Fq "$kept_path" <<<"$out" || fail "standardize review omitted protected/customized path $kept_path: $out"
    done
    filtered_diff="$(cd "$std_repo" && bash -c '
    . ./scripts/lib/review-scope.sh
    resolve_review_scope --profile standardize --release "$1" --frozen-render "$2" --base "$3"
    review_scope_apply_profile
    git_diff_review_scope "$3...HEAD"
' _ v2.0.0 "$std_bundle" "$std_base")" || fail "standardize diff collection failed"
    ! grep -Fq 'src/generated.txt' <<<"$filtered_diff" ||
        fail "the review diff included a pristine template-only file: $filtered_diff"
    grep -Fq 'src/customized.txt' <<<"$filtered_diff" ||
        fail "the review diff omitted the customized file: $filtered_diff"
    grep -Fq 'filed upstream' <<<"$out" || fail "standardize profile did not render the upstream filing default"
    grep -Fq 'A confirmed P0 or P1' <<<"$out" || fail "standardize profile did not preserve severity gating"
    if out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
        --frozen-render "$std_bundle" --base "$std_base" 2>&1)"; then
        fail "standardize profile accepted a missing --release"
    fi
    grep -Fq -- '--profile standardize requires --release' <<<"$out" ||
        fail "missing release refusal did not name the required input: $out"
    if out="$(cd "$std_repo" && bash .claude/skills/standardize-repo/assets/diff-template.sh \
        --review-exclusions --release v9.9.9 --frozen-render "$std_bundle" \
        --base "$std_base" --head "$std_head" "$std_repo" 2>&1)"; then
        fail "frozen-render helper accepted a bundle bound to another release"
    fi
    grep -Fq 'bundle release does not match --release' <<<"$out" ||
        fail "release mismatch refusal did not identify the binding error: $out"

    echo "==> standardize refuses a filtered scope over 200 entries before invoking codex"
    git -C "$std_repo" checkout -qb too-many-standardize "$std_base"
    i=1
    while [ "$i" -le 201 ]; do
        printf 'customized %s\n' "$i" >"$std_repo/src/custom-${i}.txt"
        i=$((i + 1))
    done
    git -C "$std_repo" add -A
    git -C "$std_repo" commit -qm 'test: add more than 200 customized paths'
    large_head="$(git -C "$std_repo" rev-parse HEAD)"
    large_bundle="${test_tmp}/large-standardize-bundle"
    mkdir -p "$large_bundle/previous" "$large_bundle/current"
    printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.0.1\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
        "$std_base" "$large_head" >"$large_bundle/metadata"
    : >"$large_bundle/conflict-resolutions.nul"
    : >"$large_bundle/repo-owned.nul"
    standardize_render_bundle "$large_bundle" "$std_repo" "$std_base" "$large_head" v2.0.1
    : >"$stub_argv"
    if out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
        --release v2.0.1 --frozen-render "$large_bundle" --base "$std_base" 2>&1)"; then
        fail "standardize accepted a filtered scope over 200 entries: $out"
    fi
    grep -Fq 'standardize profile refuses review scopes over 200 entries' <<<"$out" ||
        fail "oversized standardize refusal did not explain the limit: $out"
    [ ! -s "$stub_argv" ] || fail "codex was invoked for an oversized standardize scope: $(cat "$stub_argv")"
    git -C "$std_repo" checkout -q update

    echo "==> a head edit to the consumer-layout helper cannot change standardize exclusions"
    cat >"$std_repo/.claude/skills/standardize-repo/assets/diff-template.sh" <<'HEADHELPER'
#!/usr/bin/env bash
if [ "${1:-}" = --review-exclusions ]; then
    printf 'src/customized.txt\0'
    exit 0
fi
exit 2
HEADHELPER
    chmod +x "$std_repo/.claude/skills/standardize-repo/assets/diff-template.sh"
    git -C "$std_repo" add .claude/skills/standardize-repo/assets/diff-template.sh
    git -C "$std_repo" commit -qm 'test: head helper tries to exclude a customization'
    std_head_tampered="$(git -C "$std_repo" rev-parse HEAD)"
    if [ -n "$standardize_verifier" ]; then
        # Re-produce the bundle for the tampered head from the same tagged
        # template; the verifier still runs from the merge-base package.
        export HARMON_INIT="${std_bundle}-template"
        rm -rf "$std_bundle"
        bash "$standardize_verifier" \
            --previous-release v1.0.0 --release v2.0.0 --base "$std_base" \
            --head "$std_head_tampered" --output "$std_bundle" "$std_repo" ||
            fail "render-bundle.sh could not produce the tampered-head bundle"
        printf 'src/conflict-resolution.txt\0' >"$std_bundle/conflict-resolutions.nul"
    else
        printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.0.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
            "$std_base" "$std_head_tampered" >"$std_bundle/metadata"
    fi
    out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
        --release v2.0.0 --frozen-render "$std_bundle" --base "$std_base" 2>&1)" ||
        fail "standardize review with a head-edited helper failed: $out"
    grep -Fq 'src/generated.txt' <<<"$out" &&
        fail "the base helper's pristine generated path was not excluded: $out"
    grep -Fq 'src/customized.txt' <<<"$out" ||
        fail "the head helper changed the base helper's exclusions: $out"

    echo "==> a merge-base helper without --review-exclusions is refused"
    unsupported_repo="${test_tmp}/standardize-unsupported-helper-repo"
    mkdir -p "$unsupported_repo/scripts/lib" \
        "$unsupported_repo/.claude/skills/standardize-repo/assets" "$unsupported_repo/src"
    cp "${repo}/scripts/codex-review.sh" "$unsupported_repo/scripts/"
    cp "${repo}/scripts/lib/review-scope.sh" "$unsupported_repo/scripts/lib/"
    cp -R "${repo}/scripts/lib/review-instructions" "$unsupported_repo/scripts/lib/"
    cat >"$unsupported_repo/.claude/skills/standardize-repo/assets/diff-template.sh" <<'LEGACYHELPER'
#!/usr/bin/env bash
echo "FAIL: unknown argument '$1'" >&2
exit 2
LEGACYHELPER
    chmod +x "$unsupported_repo/.claude/skills/standardize-repo/assets/diff-template.sh"
    git init -q -b main "$unsupported_repo"
    git -C "$unsupported_repo" config user.email test@test
    git -C "$unsupported_repo" config user.name test
    printf 'old\n' >"$unsupported_repo/src/app.txt"
    git -C "$unsupported_repo" add -A
    git_t -C "$unsupported_repo" commit -qm 'test: legacy helper base'
    unsupported_base="$(git -C "$unsupported_repo" rev-parse HEAD)"
    git -C "$unsupported_repo" checkout -qb update
    cp "${standardize_helper}" \
        "$unsupported_repo/.claude/skills/standardize-repo/assets/diff-template.sh"
    printf 'new\n' >"$unsupported_repo/src/app.txt"
    git -C "$unsupported_repo" add -A
    git_t -C "$unsupported_repo" commit -qm 'test: update helper only at head'
    if out="$(cd "$unsupported_repo" && ./scripts/codex-review.sh review --profile standardize \
        --release v2.0.0 --frozen-render "${test_tmp}/unused-bundle" \
        --base "$unsupported_base" 2>&1)"; then
        fail "standardize profile accepted a merge-base helper without --review-exclusions"
    fi
    grep -Fq "standardize profile unavailable at merge base $unsupported_base" <<<"$out" ||
        fail "unsupported-helper refusal did not name the merge base: $out"
    grep -Fq 'the helper does not support --review-exclusions' <<<"$out" ||
        fail "unsupported-helper refusal did not explain the missing capability: $out"

    echo "==> a standardize filter that would empty the diff falls back to the full diff"
    git -C "$std_repo" checkout -qb all-pristine "$std_base"
    printf 'template all-pristine update\n' >"$std_repo/src/generated.txt"
    git -C "$std_repo" add src/generated.txt
    git -C "$std_repo" commit -qm 'test: only pristine template update'
    fallback_head="$(git -C "$std_repo" rev-parse HEAD)"
    fallback_bundle="${test_tmp}/fallback-bundle"
    mkdir -p "$fallback_bundle/previous/src" "$fallback_bundle/current/src"
    git -C "$std_repo" show "$std_base:src/generated.txt" >"$fallback_bundle/previous/src/generated.txt"
    git -C "$std_repo" show "$fallback_head:src/generated.txt" >"$fallback_bundle/current/src/generated.txt"
    printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.1.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
        "$std_base" "$fallback_head" >"$fallback_bundle/metadata"
    : >"$fallback_bundle/conflict-resolutions.nul"
    : >"$fallback_bundle/repo-owned.nul"
    standardize_render_bundle "$fallback_bundle" "$std_repo" "$std_base" "$fallback_head" v2.1.0
    out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
        --release v2.1.0 --frozen-render "$fallback_bundle" --base "$std_base" 2>&1)" ||
        fail "all-pristine standardize review failed: $out"
    grep -Fq 'full diff is retained under the standardize profile' <<<"$out" ||
        fail "empty-scope fallback was not disclosed: $out"
    grep -Fq 'src/generated.txt' <<<"$out" ||
        fail "empty-scope fallback did not restore the full manifest: $out"

    echo "==> an oversized all-pristine scope runs on the restored full diff"
    oversized_fallback_bundle="${test_tmp}/oversized-fallback-bundle"
    git -C "$std_repo" checkout -qb oversized-pristine-base "$std_base"
    mkdir -p "$oversized_fallback_bundle/previous/src" "$oversized_fallback_bundle/current/src"
    i=1
    while [ "$i" -le 201 ]; do
        printf 'template old %s\n' "$i" >"$std_repo/src/pristine-${i}.txt"
        i=$((i + 1))
    done
    git -C "$std_repo" add -A
    git -C "$std_repo" commit -qm 'test: add pristine template paths to base'
    oversized_fallback_base="$(git -C "$std_repo" rev-parse HEAD)"
    git -C "$std_repo" checkout -qb oversized-all-pristine "$oversized_fallback_base"
    i=1
    while [ "$i" -le 201 ]; do
        printf 'template new %s\n' "$i" >"$std_repo/src/pristine-${i}.txt"
        printf 'template old %s\n' "$i" >"$oversized_fallback_bundle/previous/src/pristine-${i}.txt"
        printf 'template new %s\n' "$i" >"$oversized_fallback_bundle/current/src/pristine-${i}.txt"
        i=$((i + 1))
    done
    git -C "$std_repo" add -A
    git -C "$std_repo" commit -qm 'test: update more than 200 pristine template paths'
    oversized_fallback_head="$(git -C "$std_repo" rev-parse HEAD)"
    printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.2.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
        "$oversized_fallback_base" "$oversized_fallback_head" >"$oversized_fallback_bundle/metadata"
    : >"$oversized_fallback_bundle/conflict-resolutions.nul"
    : >"$oversized_fallback_bundle/repo-owned.nul"
    standardize_render_bundle "$oversized_fallback_bundle" "$std_repo" \
        "$oversized_fallback_base" "$oversized_fallback_head" v2.2.0
    : >"$stub_argv"
    out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
        --release v2.2.0 --frozen-render "$oversized_fallback_bundle" \
        --base "$oversized_fallback_base" 2>&1)" ||
        fail "oversized all-pristine standardize review was refused: $out"
    grep -Fq 'full diff is retained under the standardize profile' <<<"$out" ||
        fail "oversized all-pristine review did not disclose its full-diff fallback: $out"
    grep -Fq 'manifest truncated at 200 entries; re-enumerate with git for the full set' <<<"$out" ||
        fail "oversized full-diff fallback omitted the ordinary re-enumeration marker: $out"
    [ -s "$stub_argv" ] || fail "codex was not invoked for the oversized full-diff fallback"
    oversized_fallback_paths="$(git -C "$std_repo" diff --name-only \
        "$oversized_fallback_base...$oversized_fallback_head" | wc -l | tr -d '[:space:]')"
    [ "$oversized_fallback_paths" = 201 ] ||
        fail "oversized full-diff fixture contains $oversized_fallback_paths paths, expected 201"

    standardize_cases=6
    unset HARMON_INIT
else
    echo "==> skipping standardize bundle fixtures: $standardize_skip"
fi

echo "==> clean tree, no local main/master: falls back to origin/HEAD's branch"
out="$(run challenge)" || fail "challenge exited non-zero: $out"
grep -q "STUB-ARGS: exec review" <<<"$out" || fail "codex exec review not invoked: $out"
grep -q -- "--model gpt-6.1-sol" <<<"$out" || fail "review model is not pinned to gpt-6.1-sol: $out"
grep -q -- "--config model_reasoning_effort=high" <<<"$out" || fail "review reasoning is not pinned high: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "remote-qualified fallback base missing: $out"
grep -q "ADVERSARIAL" <<<"$out" || fail "challenge mode instructions missing: $out"
grep -q "feature.txt" <<<"$out" || fail "changed-file manifest missing from branch-scope prompt: $out"
# A clean tree has no second half, so the split manifest must not appear —
# otherwise the union headers would be noise the reviewer has to interpret.
grep -q "Uncommitted changes (git status" <<<"$out" && fail "clean tree emitted an uncommitted manifest section: $out"
# The gate is only meaningful if the scale it gates on is defined in the
# prompt — Codex's own priority labels are an undocumented convention.
grep -q "Only P0 and P1 decide" <<<"$out" || fail "challenge prompt missing the P0/P1 gating rule: $out"
grep -q "Still report P2s" <<<"$out" || fail "challenge prompt missing the report-P2s instruction: $out"
# An unreported P2 never reaches the PR body, so the handoff clause is what
# makes "reported but non-gating" different from "ignored".
grep -q "carried into the pull request description" <<<"$out" || fail "challenge prompt missing the P2 handoff clause: $out"
# P3 is cosmetic and the cloud reviewer emits badges this prompt never sent,
# so both the fourth level and the off-scale floor have to survive edits.
# The prompt assertions below read the RENDERED instructions, so they cannot
# see a stale claim in the script's own header comment — which is exactly how
# one survived the P3 rewording (harmon-init#923 shepherd r3). Assert against
# the SOURCE too, so a summary that contradicts the prompt fails here rather
# than in review.
if grep -q "never deferred" "${repo}/scripts/codex-review.sh"; then
    fail "codex-review.sh's header still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge"
fi

grep -q "P3 — cosmetic" <<<"$out" || fail "challenge prompt missing the P3 level: $out"
grep -q "adjudicated as at least a P2" <<<"$out" || fail "challenge prompt missing the off-scale badge floor: $out"
grep -q "hypothesis the" <<<"$out" ||
    fail "challenge prompt missing the label-is-a-hypothesis rule — an under-labelled P3 could be dropped without adjudication (harmon-init#923 shepherd r2): $out"
! grep -q "not carried into the pull request description" <<<"$out" ||
    fail "challenge prompt still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge: $out"

echo "==> an external trusted runner reviews the target root without executing target runner bytes"
external_target="${test_tmp}/external-target"
git clone -q "${test_tmp}/upstream" "$external_target"
git -C "$external_target" checkout -qb candidate
target_runner_marker="${test_tmp}/target-runner-executed"
target_library_marker="${test_tmp}/target-library-executed"
cat >"$external_target/scripts/codex-review.sh" <<'TARGETRUNNER'
#!/usr/bin/env bash
: >"$TARGET_RUNNER_MARKER"
exit 91
TARGETRUNNER
cat >"$external_target/scripts/lib/review-scope.sh" <<'TARGETLIBRARY'
: >"$TARGET_LIBRARY_MARKER"
exit 92
TARGETLIBRARY
printf 'candidate-only instructions\n' >"$external_target/scripts/lib/review-instructions/standardize.txt"
printf 'candidate change\n' >"$external_target/candidate.txt"
git -C "$external_target" add -A
git_t -C "$external_target" commit -qm 'test: change candidate finder bytes'
external_target="$(cd "$external_target" && pwd -P)"
stub_cwd="${test_tmp}/external-codex-cwd"
out="$(TARGET_RUNNER_MARKER="$target_runner_marker" TARGET_LIBRARY_MARKER="$target_library_marker" \
    STUB_CWD_FILE="$stub_cwd" "${repo}/scripts/codex-review.sh" challenge \
    --repo-root "$external_target" --base origin/develop 2>&1)" ||
    fail "trusted external runner failed: $out"
[ "$(cat "$stub_cwd")" = "$external_target" ] ||
    fail "codex ran outside the target root: $(cat "$stub_cwd")"
[ ! -e "$target_runner_marker" ] || fail "the target's codex-review.sh executed"
[ ! -e "$target_library_marker" ] || fail "the target's review-scope.sh executed"
grep -Fq 'candidate.txt' <<<"$out" || fail "trusted runner did not scope the target diff: $out"
grep -Fq 'scripts/codex-review.sh' <<<"$out" || fail "target runner change missing from the review manifest: $out"
grep -Fq 'scripts/lib/review-scope.sh' <<<"$out" || fail "target library change missing from the review manifest: $out"

echo "==> an external trusted runner accepts an empty forwarded-argument list under nounset"
out="$(TARGET_RUNNER_MARKER="$target_runner_marker" TARGET_LIBRARY_MARKER="$target_library_marker" \
    STUB_CWD_FILE="$stub_cwd" "${repo}/scripts/codex-review.sh" challenge \
    --repo-root "$external_target" 2>&1)" ||
    fail "trusted external runner failed with only --repo-root: $out"
grep -Fq 'candidate.txt' <<<"$out" || fail "empty forwarded arguments did not reach default scope resolution: $out"
grep -Fq 'if [ "${#review_args[@]}" -eq 0 ]; then' "${repo}/scripts/codex-review.sh" ||
    fail "runner lost the explicit Bash 3.2/4.3 empty-array guard"

echo "==> --repo-root refuses a target subdirectory"
if out="$("${repo}/scripts/codex-review.sh" review --repo-root "$external_target/scripts" \
    --base origin/develop 2>&1)"; then
    fail "--repo-root accepted a target subdirectory: $out"
fi
grep -Fq -- '--repo-root must name the Git worktree root' <<<"$out" ||
    fail "target-subdirectory refusal did not name the root requirement: $out"

echo "==> an external trusted runner preserves the finder exit status"
status=0
STUB_EXIT=7 "${repo}/scripts/codex-review.sh" review --repo-root "$external_target" \
    --base origin/develop >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "external runner lost the finder exit status (got ${status}, want 7)"

echo "==> origin/HEAD outranks a stray local main"
git branch -q main "$(git rev-list --max-parents=0 HEAD)"
out="$(run challenge)" || fail "challenge with stray local main exited non-zero: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "stray local main hijacked base detection: $out"
git branch -q -D main

echo "==> --base with no merge base fails fast"
unrelated="$(git_t commit-tree "$(git mktree </dev/null)" -m orphan)"
if out="$(run review --base "$unrelated" 2>&1)"; then
    fail "--base with unrelated history accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite no merge base: $out"
grep -q "no merge base" <<<"$out" || fail "missing no-merge-base message: $out"

echo "==> explicit --base and focus text reach the prompt"
out="$(run review --base origin/develop watch the hooks)" || fail "review --base exited non-zero: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "--base not honored: $out"
grep -q "VERIFICATION-CHECKPOINT" <<<"$out" || fail "review mode instructions missing: $out"
grep -q "watch the hooks" <<<"$out" || fail "focus text missing from prompt: $out"
grep -q "Only P0 and P1 decide" <<<"$out" || fail "review prompt missing the P0/P1 gating rule: $out"
grep -q "carried into the pull request description" <<<"$out" || fail "review prompt missing the P2 handoff clause: $out"
grep -q "P3 — cosmetic" <<<"$out" || fail "review prompt missing the P3 level: $out"
grep -q "adjudicated as at least a P2" <<<"$out" || fail "review prompt missing the off-scale badge floor: $out"
grep -q "hypothesis the" <<<"$out" ||
    fail "review prompt missing the label-is-a-hypothesis rule — an under-labelled P3 could be dropped without adjudication (harmon-init#923 shepherd r2): $out"
! grep -q "not carried into the pull request description" <<<"$out" ||
    fail "review prompt still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge: $out"

# ── Review guidelines (harmon-init#1530) ─────────────────────────────────────
# Everything after STUB-PROMPT: is the prompt codex received, byte for byte.
prompt_of() {
    sed -n '/^STUB-PROMPT:/,$p' <<<"$1" | sed '1s/^STUB-PROMPT://'
}
# A fresh repository carrying the runner, on main. Callers add the files each
# case needs and commit; the runner's own bytes are the ones under test.
guidelines_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/scripts/lib" "$fixture/docs"
    cp "${repo}/scripts/codex-review.sh" "$fixture/scripts/"
    cp "${repo}/scripts/lib/review-scope.sh" "$fixture/scripts/lib/"
    cp -R "${repo}/scripts/lib/review-instructions" "$fixture/scripts/lib/"
    git init -q -b main "$fixture"
}
# A stand-in policy reader at a fixture's base revision: prints the JSON its
# body carries, after proving it was handed the BASE copy of .devflow.toml (a
# branch copy carries a different marker). Deterministic whatever reader the
# repository running this test vendors, so every projection path is covered
# without depending on the pin.
stub_reader() {
    local fixture="$1" json="$2"
    mkdir -p "$fixture/scripts/lib"
    printf 'export const stub = true\n' >"$fixture/scripts/lib/toml-lite.mjs"
    cat >"$fixture/scripts/devflow-policy.mjs" <<STUBREADER
import { readFileSync } from 'node:fs'
import './lib/toml-lite.mjs'
const args = process.argv.slice(2)
if (args[0] !== 'resolve' || !args.includes('--json')) { console.error('stub reader: unexpected arguments', args); process.exit(2) }
const policy = readFileSync(args[args.indexOf('--policy') + 1], 'utf8')
if (!policy.includes('BASE-POLICY-MARKER')) { console.error('stub reader: not the base revision policy'); process.exit(1) }
console.log(JSON.stringify(${json}))
STUBREADER
}

echo "==> unconfigured: the prompt is the built-in text, byte for byte (golden)"
# The clone fixture has no docs/review-guidelines.md and no .devflow.toml at
# its base, so this is the prompt the runner sent before guidelines existed.
# A change to this text is a change to every review; it is made here on
# purpose, never by accident.
golden_file="${test_tmp}/golden-review-prompt"
cat >"$golden_file" <<'GOLDEN'
Review the changes on the current branch relative to base branch 'origin/develop' (the merge-base diff origin/develop...HEAD).

Run a VERIFICATION-CHECKPOINT review of this change: double-check that the
implementation actually does what it claims, is internally consistent and
consistent with this repository's existing conventions and docs, handles
errors and edge cases, and has adequate test coverage (including regression
tests for anything it fixes). Flag docs the change should have updated.
Report only material, defensible findings tied to concrete files and lines —
no style nits. If the change holds up, say so directly.

Label EVERY finding with a priority, as the first token of the finding:

  P0 — a defect that breaks correctness, security, or data integrity in
       ordinary use, or that breaks an existing contract. Merge-blocking.
  P1 — a real defect or materially wrong design decision with a plausible
       trigger. Merge-blocking unless argued down with evidence.
  P2 — worth knowing, but not merge-blocking: hardening, edge cases behind
       unlikely preconditions, maintainability, non-critical test gaps.
  P3 — cosmetic or purely informational: a naming or wording choice that
       will mislead a reader, an observation with no defect behind it.
       Never gating. The no-style-nits rule above still binds — P3 is the
       floor for findings worth stating, not a licence to report nits.

Only P0 and P1 decide whether this review passes. Still report P2s in full —
they are triaged later, once the pull request is open — but do not let them
hold the stage open. Do not inflate a P2 to P1 to make it heard, and do not
withhold or soften a P2 because it is non-gating: a P2 reported here is
carried into the pull request description, so an unreported one is lost
outright. The same holds one level down: report a P3 as a P3 rather than
inflating it to P2 or dropping it for being small. Use these four labels and
no others — a finding that arrives off this scale, or with no label at all,
is adjudicated as at least a P2. Every label you apply is a hypothesis the
reader adjudicates on evidence, P3 included; none of them decides its own
disposition. If there are no P0 or P1 findings, say so
explicitly and in those terms.

Authoritative changed-file manifest from git for this scope (status + path;
cover EVERY entry, including untracked files, collecting the diffs yourself
with git):

GOLDEN
printf 'A\tfeature.txt' >>"$golden_file"
golden="$(cat "$golden_file")"
out="$(run review --base origin/develop)" || fail "unconfigured review exited non-zero: $out"
grep -Fq 'Review guidelines: none at' <<<"$out" || fail "unconfigured run did not say no guidelines govern: $out"
if [ "$(prompt_of "$out")" != "$golden" ]; then
    diff <(printf '%s\n' "$golden") <(prompt_of "$out") >&2 || true
    fail "the unconfigured prompt drifted from its golden copy (above); change both deliberately or neither"
fi

echo "==> the severity scale in docs/review-guidelines.md and in the prompt are the same lines"
# The file holds the scale's single normative statement (#964); the prompt
# carries a copy because it is what the reviewer actually reads. Two copies
# are one too many unless a gate holds them together — this is that gate.
scale_prompt="$(sed -n '/^  P0 — /,/^$/p' <<<"$golden" | sed '$d')"
[ "$(wc -l <<<"$scale_prompt")" -eq 10 ] || fail "could not extract the prompt's scale block: $scale_prompt"
if [ -f "${repo}/docs/review-guidelines.md" ]; then
    scale_doc="$(awk '/^## Severity scale$/ { s = 1 } s && /^```text$/ { f = 1; next } f && /^```$/ { exit } f' "${repo}/docs/review-guidelines.md")"
    [ -n "$scale_doc" ] || fail "docs/review-guidelines.md has no fenced text block under '## Severity scale'"
    if [ "$scale_doc" != "$scale_prompt" ]; then
        diff <(printf '%s\n' "$scale_doc") <(printf '%s\n' "$scale_prompt") >&2 || true
        fail "docs/review-guidelines.md's severity scale differs from the prompt's (above): edit both in the same commit"
    fi
else
    echo "    (docs/review-guidelines.md is absent here; nothing to compare the prompt's scale against)"
fi

echo "==> guidelines come from the base revision: worktree and branch edits do not reach a --base review"
conv="${test_tmp}/guidelines-conventional"
guidelines_fixture "$conv"
printf 'BASE-GUIDELINES-MARKER\n' >"$conv/docs/review-guidelines.md"
printf 'old\n' >"$conv/src.txt"
git -C "$conv" add -A
git_t -C "$conv" commit -qm 'test: base with guidelines'
conv_base="$(git -C "$conv" rev-parse HEAD)"
git -C "$conv" checkout -qb feature
printf 'HEAD-GUIDELINES-MARKER\n' >"$conv/docs/review-guidelines.md"
printf 'new\n' >"$conv/src.txt"
git -C "$conv" add -A
git_t -C "$conv" commit -qm 'test: branch rewrites the guidelines'
conv_head="$(git -C "$conv" rev-parse HEAD)"
printf 'WORKTREE-GUIDELINES-MARKER\n' >"$conv/docs/review-guidelines.md"
out="$(cd "$conv" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "--base review with guidelines failed: $out"
grep -Fq "Review guidelines: docs/review-guidelines.md at $(git -C "$conv" rev-parse --short main)" <<<"$out" ||
    fail "the run did not name the base revision's guidelines: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'BASE-GUIDELINES-MARKER' <<<"$prompt" || fail "base-revision guidelines missing from the --base prompt: $prompt"
! grep -Fq 'HEAD-GUIDELINES-MARKER' <<<"$prompt" || fail "the branch's rewritten guidelines reached the --base prompt: $prompt"
! grep -Fq 'WORKTREE-GUIDELINES-MARKER' <<<"$prompt" || fail "a working-tree edit to the guidelines reached the --base prompt: $prompt"
grep -Fq "Repository review guidelines (docs/review-guidelines.md, read at $(git -C "$conv" rev-parse --short main)). Apply them throughout this review:" <<<"$prompt" ||
    fail "the guidelines block does not state its provenance: $prompt"
# Assembly order: preamble, guidelines, scale, manifest.
awk '/VERIFICATION-CHECKPOINT/ { a = NR } /BASE-GUIDELINES-MARKER/ { b = NR } /^Label EVERY finding/ { c = NR } /^Authoritative changed-file manifest/ { d = NR }
    END { exit !(a && b && c && d && a < b && b < c && c < d) }' <<<"$prompt" ||
    fail "prompt is not assembled as preamble, guidelines, scale, manifest: $prompt"

echo "==> --uncommitted reads HEAD's guidelines, --commit the parent's, the default union the merge base's"
out="$(cd "$conv" && ./scripts/codex-review.sh review --uncommitted 2>&1)" || fail "--uncommitted review failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'HEAD-GUIDELINES-MARKER' <<<"$prompt" || fail "--uncommitted did not read HEAD's guidelines: $prompt"
! grep -Fq 'WORKTREE-GUIDELINES-MARKER' <<<"$prompt" || fail "--uncommitted read the working tree's guidelines: $prompt"
out="$(cd "$conv" && ./scripts/codex-review.sh review --commit "$conv_head" 2>&1)" || fail "--commit review failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'BASE-GUIDELINES-MARKER' <<<"$prompt" || fail "--commit did not read the parent's guidelines: $prompt"
! grep -Fq 'HEAD-GUIDELINES-MARKER' <<<"$prompt" || fail "--commit read the reviewed commit's own guidelines: $prompt"
out="$(cd "$conv" && ./scripts/codex-review.sh challenge 2>&1)" || fail "default-scope challenge failed: $out"
grep -q "Reviewing branch changes against main AND uncommitted work" <<<"$out" || fail "default scope did not take both halves: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'BASE-GUIDELINES-MARKER' <<<"$prompt" || fail "the default union did not read the merge base's guidelines: $prompt"
! grep -Fq 'WORKTREE-GUIDELINES-MARKER' <<<"$prompt" || fail "the default union read the working tree's guidelines: $prompt"
: >"$stub_argv"
out="$(cd "$conv" && ./scripts/codex-review.sh review --commit "$conv_base" 2>&1)" || fail "--commit on the root commit failed: $out"
grep -Fq 'no base revision for this scope; built-in instructions only' <<<"$out" || fail "a parentless commit did not fall back to the built-in instructions: $out"
! grep -Fq 'Repository review guidelines' <<<"$(prompt_of "$out")" || fail "a parentless commit still carried guidelines: $out"
[ -s "$stub_argv" ] || fail "codex was not invoked for a genuine root commit"

echo "==> --commit refuses a shallow boundary with unavailable parent history before codex"
shallow="${test_tmp}/guidelines-shallow"
git clone -q --depth 1 --branch feature "file://$conv" "$shallow"
[ "$(git -C "$shallow" rev-parse --is-shallow-repository)" = true ] || fail "the shallow fixture is not shallow"
if git -C "$shallow" cat-file -e "${conv_base}^{commit}" 2>/dev/null; then
    fail "the shallow fixture still has its parent commit"
fi
: >"$stub_argv"
status=0
out="$(cd "$shallow" && ./scripts/codex-review.sh review --commit HEAD 2>&1)" || status=$?
[ "$status" -eq 2 ] || fail "unavailable parent history exited $status instead of 2: $out"
grep -Fq "parent history unavailable at $conv_base" <<<"$out" || fail "the shallow refusal did not identify the unavailable parent: $out"
[ ! -s "$stub_argv" ] || fail "codex was invoked despite unavailable parent history"

echo "==> [review_guidelines].file at the base revision governs: not the branch's table, not the conventional path"
pol="${test_tmp}/guidelines-policied"
guidelines_fixture "$pol"
printf '# BASE-POLICY-MARKER\n' >"$pol/.devflow.toml"
stub_reader "$pol" '{ rigor: { level: "standard" }, review_guidelines: { file: "docs/custom-guidelines.md", text: null, challenge_focus: "CONFIGURED-CHALLENGE-FOCUS", review_focus: "CONFIGURED-REVIEW-FOCUS" } }'
printf 'CUSTOM-GUIDELINES-MARKER\n' >"$pol/docs/custom-guidelines.md"
printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$pol/docs/review-guidelines.md"
git -C "$pol" add -A
git_t -C "$pol" commit -qm 'test: base policy names custom guidelines'
git -C "$pol" checkout -qb feature
printf '# BRANCH-POLICY-MARKER\n' >"$pol/.devflow.toml"
stub_reader "$pol" '{ rigor: { level: "standard" }, review_guidelines: { file: "docs/branch-guidelines.md", text: null, challenge_focus: "BRANCH-FOCUS", review_focus: "BRANCH-FOCUS" } }'
printf 'BRANCH-GUIDELINES-MARKER\n' >"$pol/docs/branch-guidelines.md"
git -C "$pol" add -A
git_t -C "$pol" commit -qm 'test: branch points the table at its own file'
out="$(cd "$pol" && ./scripts/codex-review.sh challenge --base main 2>&1)" || fail "challenge with a configured table failed: $out"
grep -Fq "Review guidelines: docs/custom-guidelines.md at $(git -C "$pol" rev-parse --short main)" <<<"$out" ||
    fail "the run did not name the configured file at the base revision: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'CUSTOM-GUIDELINES-MARKER' <<<"$prompt" || fail "the configured guidelines file is missing from the prompt: $prompt"
! grep -Fq 'CONVENTIONAL-GUIDELINES-MARKER' <<<"$prompt" || fail "the conventional path was used although the table names another file: $prompt"
! grep -Fq 'BRANCH-GUIDELINES-MARKER' <<<"$prompt" || fail "the branch's own table chose the guidelines: $prompt"
grep -Fq 'Default focus from the repository'"'"'s review policy (.devflow.toml [review_guidelines].challenge_focus; weight it heavily): CONFIGURED-CHALLENGE-FOCUS' <<<"$prompt" ||
    fail "the configured challenge focus is missing from a focus-less challenge: $prompt"
! grep -Fq 'CONFIGURED-REVIEW-FOCUS' <<<"$prompt" || fail "the review focus leaked into a challenge: $prompt"
! grep -Fq 'BRANCH-FOCUS' <<<"$prompt" || fail "the branch's focus reached the prompt: $prompt"
out="$(cd "$pol" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with a configured table failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq '[review_guidelines].review_focus; weight it heavily): CONFIGURED-REVIEW-FOCUS' <<<"$prompt" ||
    fail "the configured review focus is missing from a focus-less review: $prompt"
! grep -Fq 'CONFIGURED-CHALLENGE-FOCUS' <<<"$prompt" || fail "the challenge focus leaked into a review: $prompt"

echo "==> CLI focus text outranks the configured default focus"
out="$(cd "$pol" && ./scripts/codex-review.sh review --base main watch the hooks 2>&1)" || fail "review with CLI focus failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'Additional focus from the invoker (weight it heavily): watch the hooks' <<<"$prompt" || fail "CLI focus missing: $prompt"
! grep -Fq 'Default focus from the repository' <<<"$prompt" || fail "the configured focus was appended beside the CLI focus: $prompt"
! grep -Fq 'CONFIGURED-REVIEW-FOCUS' <<<"$prompt" || fail "the configured focus text leaked beside the CLI focus: $prompt"

echo "==> [review_guidelines].text is used inline, over the conventional file"
inl="${test_tmp}/guidelines-inline"
guidelines_fixture "$inl"
printf '# BASE-POLICY-MARKER\n' >"$inl/.devflow.toml"
stub_reader "$inl" '{ rigor: { level: "standard" }, review_guidelines: { file: null, text: "INLINE-GUIDELINES-MARKER\nsecond inline line", challenge_focus: null, review_focus: null } }'
printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$inl/docs/review-guidelines.md"
git -C "$inl" add -A
git_t -C "$inl" commit -qm 'test: inline guidelines'
git -C "$inl" checkout -qb feature
printf 'change\n' >"$inl/src.txt"
git -C "$inl" add -A
git_t -C "$inl" commit -qm 'test: work'
out="$(cd "$inl" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with inline guidelines failed: $out"
grep -Fq 'Review guidelines: .devflow.toml [review_guidelines].text at' <<<"$out" || fail "the run did not name the inline source: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'Repository review guidelines (.devflow.toml [review_guidelines].text, read at' <<<"$prompt" || fail "inline guidelines block missing its provenance: $prompt"
grep -Fq 'INLINE-GUIDELINES-MARKER' <<<"$prompt" && grep -Fq 'second inline line' <<<"$prompt" || fail "inline guidelines text missing or truncated: $prompt"
! grep -Fq 'CONVENTIONAL-GUIDELINES-MARKER' <<<"$prompt" || fail "the conventional file was used although text is configured: $prompt"
! grep -Fq 'Default focus' <<<"$prompt" || fail "a null focus produced a default-focus block: $prompt"

echo "==> an absent, incomplete, old, or refusing reader falls back to the conventional path"
for variant in absent incomplete unsupported refusing; do
    fb="${test_tmp}/guidelines-${variant}"
    guidelines_fixture "$fb"
    printf '# BASE-POLICY-MARKER\n' >"$fb/.devflow.toml"
    if [ "$variant" = unsupported ]; then
        stub_reader "$fb" '{ rigor: { level: "standard" } }'
    elif [ "$variant" = incomplete ]; then
        stub_reader "$fb" '{}'
        rm "$fb/scripts/lib/toml-lite.mjs"
    elif [ "$variant" = refusing ]; then
        stub_reader "$fb" '{}'
        printf '# BRANCH-POLICY-MARKER (not the base copy, so the stub refuses with exit 1)\n' >"$fb/.devflow.toml"
    fi
    printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$fb/docs/review-guidelines.md"
    git -C "$fb" add -A
    git_t -C "$fb" commit -qm 'test: base'
    git -C "$fb" checkout -qb feature
    printf 'change\n' >"$fb/src.txt"
    git -C "$fb" add -A
    git_t -C "$fb" commit -qm 'test: work'
    out="$(cd "$fb" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with a ${variant} reader failed: $out"
    if [ "$variant" = refusing ]; then
        grep -Fq 'refused .devflow.toml (exit 1); using the conventional path' <<<"$out" || fail "a refusing reader was not reported: $out"
        grep -Fq 'stub reader: not the base revision policy' <<<"$out" || fail "the stderr of the refusing reader was not surfaced: $out"
    fi
    grep -Fq 'Review guidelines: docs/review-guidelines.md at' <<<"$out" || fail "the ${variant} reader did not fall back to the conventional path: $out"
    grep -Fq 'CONVENTIONAL-GUIDELINES-MARKER' <<<"$(prompt_of "$out")" || fail "conventional guidelines missing after the ${variant} reader: $out"
done

echo "==> a configured file missing at the base revision refuses before codex is invoked"
mis="${test_tmp}/guidelines-missing"
guidelines_fixture "$mis"
printf '# BASE-POLICY-MARKER\n' >"$mis/.devflow.toml"
stub_reader "$mis" '{ rigor: { level: "standard" }, review_guidelines: { file: "docs/nowhere.md", text: null, challenge_focus: null, review_focus: null } }'
git -C "$mis" add -A
git_t -C "$mis" commit -qm 'test: base names a missing file'
git -C "$mis" checkout -qb feature
printf 'change\n' >"$mis/src.txt"
git -C "$mis" add -A
git_t -C "$mis" commit -qm 'test: work'
: >"$stub_argv"
if out="$(cd "$mis" && ./scripts/codex-review.sh review --base main 2>&1)"; then
    fail "a configured guidelines file missing at the base revision was accepted: $out"
fi
grep -Fq "[review_guidelines].file names 'docs/nowhere.md', which does not exist at" <<<"$out" || fail "missing-file refusal did not name the file and revision: $out"
[ ! -s "$stub_argv" ] || fail "codex was invoked despite the missing guidelines file: $(cat "$stub_argv")"

echo "==> symlinks in policy, reader, and guidelines paths refuse before codex"
for path in .devflow.toml scripts/devflow-policy.mjs scripts/lib/toml-lite.mjs \
    docs/custom-guidelines.md docs/review-guidelines.md; do
    fixture="$pol"
    [ "$path" != docs/review-guidelines.md ] || fixture="$conv"
    symlink_repo="${test_tmp}/guidelines-symlink-${path//\//-}"
    git clone -q --branch main "$fixture" "$symlink_repo"
    mv "$symlink_repo/$path" "$symlink_repo/$path.regular"
    ln -s "${path##*/}.regular" "$symlink_repo/$path"
    git -C "$symlink_repo" add -A
    git_t -C "$symlink_repo" commit -qm 'test: base has a symlink instead of a regular file'
    revision="$(git -C "$symlink_repo" rev-parse HEAD)"
    git -C "$symlink_repo" checkout -qb symlink-change
    printf 'candidate change\n' >"$symlink_repo/symlink-change.txt"
    git -C "$symlink_repo" add symlink-change.txt
    git_t -C "$symlink_repo" commit -qm 'test: work after the symlink base'
    : >"$stub_argv"
    status=0
    out="$(cd "$symlink_repo" && ./scripts/codex-review.sh review --base main 2>&1)" || status=$?
    [ "$status" -eq 2 ] || fail "symlink at $path exited $status instead of 2: $out"
    grep -Fq "'$path' at $revision is not a regular file" <<<"$out" ||
        fail "the symlink refusal did not identify $path at $revision: $out"
    [ ! -s "$stub_argv" ] || fail "codex was invoked despite the symlink at $path"
done

echo "==> failed Git tree or existing-blob reads refuse before codex is invoked"
# Keep real repositories and inject only the failed Git operation: a missing
# path has a successful, empty tree lookup, whereas an unavailable object or
# failed lookup must never downgrade the configured instructions to fallback.
mkdir -p "${test_tmp}/object-read-bin"
export OBJECT_READ_REAL_GIT="$(command -v git)"
cat >"${test_tmp}/object-read-bin/git" <<'GITSTUB'
#!/usr/bin/env bash
if [ "$OBJECT_READ_OPERATION" = tree ] && [ "$1" = --literal-pathspecs ] &&
    [ "$2" = ls-tree ] && [ "${@: -1}" = "$OBJECT_READ_PATH" ]; then
    echo "simulated Git tree lookup failure" >&2
    exit 128
fi
if [ "$OBJECT_READ_OPERATION" = blob ] && [ "$1" = show ] &&
    [ "$2" = "$OBJECT_READ_REV:$OBJECT_READ_PATH" ]; then
    echo "simulated Git blob read failure" >&2
    exit 128
fi
exec "$OBJECT_READ_REAL_GIT" "$@"
GITSTUB
chmod +x "${test_tmp}/object-read-bin/git"
for operation in tree blob; do
    for path in .devflow.toml scripts/devflow-policy.mjs scripts/lib/toml-lite.mjs \
        docs/custom-guidelines.md docs/review-guidelines.md; do
        fixture="$pol"
        [ "$path" != docs/review-guidelines.md ] || fixture="$conv"
        revision="$(git -C "$fixture" rev-parse main)"
        : >"$stub_argv"
        status=0
        out="$(cd "$fixture" && PATH="${test_tmp}/object-read-bin:$PATH" \
            OBJECT_READ_OPERATION="$operation" OBJECT_READ_PATH="$path" OBJECT_READ_REV="$revision" \
            ./scripts/codex-review.sh review --base main 2>&1)" || status=$?
        [ "$status" -eq 2 ] || fail "${operation} failure for $path exited $status instead of 2: $out"
        if [ "$operation" = tree ]; then diagnostic=inspect; else diagnostic=read; fi
        grep -Fq "could not $diagnostic '$path' at $revision" <<<"$out" ||
            fail "${operation} refusal did not identify $path at $revision: $out"
        [ ! -s "$stub_argv" ] || fail "codex was invoked despite the ${operation} failure for $path"
    done
done

# The repository's REAL reader, where one is vendored: prove the runner can
# drive it from a base revision. A reader that projects the table must select
# the configured file; one that predates it (an older harmon-devkit pin) must
# leave the conventional path in force. Either is the documented behaviour.
real_reader=""
for candidate in scripts/devflow-policy.mjs \
    .claude/skills/dev-flow-support/assets/devflow-policy.mjs \
    .agents/skills/dev-flow-support/assets/devflow-policy.mjs; do
    if [ -f "${repo}/${candidate}" ] && [ -f "${repo}/${candidate%/*}/lib/toml-lite.mjs" ]; then
        real_reader="$candidate"
        break
    fi
done
if [ -n "$real_reader" ] && [ -f "${repo}/.devflow.toml" ] &&
    grep -q '^file  *= "docs/review-guidelines.md"' "${repo}/.devflow.toml"; then
    echo "==> the vendored policy reader (${real_reader}) is driven from the base revision"
    rr="${test_tmp}/guidelines-real-reader"
    guidelines_fixture "$rr"
    mkdir -p "$rr/${real_reader%/*}/lib"
    cp "${repo}/${real_reader}" "$rr/${real_reader}"
    cp "${repo}/${real_reader%/*}/lib/toml-lite.mjs" "$rr/${real_reader%/*}/lib/"
    sed 's|^file  *= "docs/review-guidelines.md"|file = "docs/custom-guidelines.md"|' "${repo}/.devflow.toml" >"$rr/.devflow.toml"
    printf 'CUSTOM-GUIDELINES-MARKER\n' >"$rr/docs/custom-guidelines.md"
    printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$rr/docs/review-guidelines.md"
    git -C "$rr" add -A
    git_t -C "$rr" commit -qm 'test: base with the real reader'
    git -C "$rr" checkout -qb feature
    printf 'change\n' >"$rr/src.txt"
    git -C "$rr" add -A
    git_t -C "$rr" commit -qm 'test: work'
    # Exit 3 (no registry offered, so cross-validation is indeterminate) still
    # prints the projection; capture first so pipefail does not read it as
    # "no projection".
    projection="$(node "${repo}/${real_reader}" resolve --policy "$rr/.devflow.toml" --json 2>/dev/null || true)"
    if grep -q '"review_guidelines"' <<<"$projection"; then
        expect=CUSTOM-GUIDELINES-MARKER
        reject=CONVENTIONAL-GUIDELINES-MARKER
    else
        echo "    (this reader predates [review_guidelines]; expecting the conventional-path fallback)"
        expect=CONVENTIONAL-GUIDELINES-MARKER
        reject=CUSTOM-GUIDELINES-MARKER
    fi
    out="$(cd "$rr" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with the real reader failed: $out"
    prompt="$(prompt_of "$out")"
    grep -Fq "$expect" <<<"$prompt" || fail "real reader: expected ${expect} in the prompt: $out"
    ! grep -Fq "$reject" <<<"$prompt" || fail "real reader: ${reject} should not be in the prompt: $out"
else
    echo "    (no vendored policy reader beside a shipped [review_guidelines] table; real-reader case skipped)"
fi

echo "==> --base warns when the ref lags an upstream HEAD already contains"
# The reported bug: `--base main` on a checkout whose local main trails
# origin/main reviews the already-merged commits as if this branch introduced
# them, drawing findings against files the branch never touched.
# basestale is pinned at the CURRENT origin/develop and tracks it, so advancing
# the upstream afterwards leaves it behind by exactly the new commits.
git branch -q --track basestale origin/develop
(
    cd "${test_tmp}/upstream"
    echo one >merged-one.txt
    echo two >merged-two.txt
    git add merged-one.txt merged-two.txt
    git_t commit -q -m "upstream work 1" -- merged-one.txt
    git_t commit -q -m "upstream work 2" -- merged-two.txt
)
git fetch -q origin
pre_merge="$(git rev-parse HEAD)"
git_t merge -q --no-edit origin/develop
out="$(run review --base basestale)" || fail "stale-base run exited non-zero (must stay advisory): $out"
# Advisory, not fatal: the review still has to happen, or the warning has
# turned a nudge into a refusal.
grep -q "STUB-ARGS: exec review" <<<"$out" || fail "stale-base warning suppressed the review: $out"
grep -q "lags its upstream 'origin/develop'" <<<"$out" || fail "stale-base warning missing: $out"
grep -q "contains 2 commits that already merged upstream" <<<"$out" || fail "stale-base warning miscounted the carried commits: $out"
grep -q -- "--base origin/develop" <<<"$out" || fail "stale-base warning does not name the remote-qualified ref: $out"

echo "==> --base warns on a HALF-updated branch, where the upstream tip is not in HEAD"
# Base at A, upstream since advanced A->B->C, HEAD carrying B but not C. The
# upstream tip is NOT an ancestor of HEAD, yet B's already-merged changes sit
# inside basestale...HEAD — so an is-ancestor(upstream, HEAD) trigger goes
# silent on exactly the contamination it exists to catch. The merge bases are
# what differ (A vs B), which is why the check compares those.
git checkout -q -b halfway "$pre_merge"
git_t merge -q --no-edit origin/develop~1
out="$(run review --base basestale)" || fail "half-updated stale-base run exited non-zero: $out"
grep -q "lags its upstream 'origin/develop'" <<<"$out" || fail "no warning on a half-updated branch: $out"
grep -q "contains 1 commit that already merged upstream" <<<"$out" || fail "half-updated warning miscounted (or mis-pluralized) the carried commits: $out"
git checkout -q feature

echo "==> a stale base whose upstream commits are NOT in HEAD stays silent"
# The other side of the merge-base comparison: with nothing of the upstream in
# HEAD both diffs start at the same commit, base...HEAD is already correct, and
# a warning here would be a false positive on a healthy run.
git checkout -q -b prestale "$pre_merge"
out="$(run review --base basestale)" || fail "pre-merge stale-base run exited non-zero: $out"
grep -q "lags its upstream" <<<"$out" && fail "warned on a base whose upstream commits HEAD does not contain: $out"
git checkout -q feature

echo "==> --base refs with no upstream never warn"
# A tag, a raw sha, and a remote-qualified ref have no @{upstream}; each must
# reach the review silently instead of erroring out of the resolution attempt.
git tag basetag basestale
for ref in basetag "$(git rev-parse basestale)" origin/develop; do
    out="$(run review --base "$ref")" || fail "--base '$ref' exited non-zero: $out"
    grep -q "STUB-ARGS: exec review" <<<"$out" || fail "--base '$ref' did not reach codex: $out"
    grep -q "lags its upstream" <<<"$out" && fail "--base '$ref' has no upstream but warned: $out"
done

echo "==> a tree-neutral upstream gap does not warn"
# The gap is real in commits and empty in content — a file added upstream and
# reverted upstream. base...HEAD and origin/develop...HEAD are then identical,
# so Codex reads the same diff either way and there is nothing to warn about.
# neutralbase is pinned BEFORE the pair lands, so it is genuinely behind.
git branch -q --track neutralbase origin/develop
(
    cd "${test_tmp}/upstream"
    echo scratch >revertme.txt
    git add revertme.txt
    git_t commit -q -m "add revertme"
    git rm -q revertme.txt
    git_t commit -q -m "revert revertme"
)
git fetch -q origin
git checkout -q -b neutral origin/develop
echo n >neutral.txt
git add neutral.txt
git_t commit -q -m "work on top of the tree-neutral gap"
out="$(run review --base neutralbase)" || fail "tree-neutral run exited non-zero: $out"
grep -q "lags its upstream" <<<"$out" && fail "warned on an upstream gap that changes no files: $out"
git checkout -q feature

echo "==> the full-ref spelling of a local branch still warns"
# --base accepts refs/heads/<branch> (rev-parse resolves it), but
# `refs/heads/main@{upstream}` is not an upstream query and simply fails, so
# without normalization this spelling would skip the check silently.
for ref in refs/heads/basestale heads/basestale; do
    out="$(run review --base "$ref")" || fail "--base '$ref' exited non-zero: $out"
    grep -q "lags its upstream 'origin/develop'" <<<"$out" || fail "--base '$ref' skipped the stale-base check: $out"
done

echo "==> commits plus a dirty tree review BOTH halves, in labelled sections"
# The reported bug: the two scopes are disjoint and the dirty tree used to win
# outright, so a re-run after an uncommitted fix reviewed that fix alone and
# banked a clean pass for a fraction of the change. Both halves must be in one
# manifest, and each must land in its own section — a file listed under the
# wrong heading tells the reviewer to collect the wrong diff for it.
echo x >dirty.txt
mkdir newdir
echo y >newdir/inner.txt
out="$(run review)" || fail "commits-plus-dirty review exited non-zero: $out"
grep -q "BOTH parts are in scope" <<<"$out" || fail "commits plus a dirty tree did not select the union scope: $out"
grep -q "uncommitted work in the working tree" <<<"$out" || fail "union scope does not name the worktree half: $out"
grep -q "origin/develop...HEAD" <<<"$out" || fail "union scope does not name the committed half: $out"
committed_half="$(printf '%s\n' "$out" | sed -n '/^Committed changes (git diff/,/^Uncommitted changes (git status/p')"
uncommitted_half="$(printf '%s\n' "$out" | sed -n '/^Uncommitted changes (git status/,$p')"
[ -n "$committed_half" ] || fail "union manifest missing its committed section: $out"
[ -n "$uncommitted_half" ] || fail "union manifest missing its uncommitted section: $out"
grep -q "feature.txt" <<<"$committed_half" || fail "committed half missing the branch's own commit: $out"
grep -q "dirty.txt" <<<"$committed_half" && fail "worktree file filed under the committed heading: $out"
grep -q "dirty.txt" <<<"$uncommitted_half" || fail "untracked file missing from the uncommitted half: $out"
grep -q "newdir/inner.txt" <<<"$uncommitted_half" || fail "file inside untracked dir missing from manifest (collapsed to dir entry): $out"
rm -rf dirty.txt newdir

echo "==> a >200-entry dirty tree still reviews (no SIGPIPE abort) and marks truncation"
# Top-level files: git status collapses an untracked directory into a single
# "?? dir/" entry, which would defeat the >200-entry premise.
i=1
while [ "$i" -le 250 ]; do
    : >"bulk_f${i}.txt"
    i=$((i + 1))
done
out="$(run review)" || fail "large dirty tree aborted the review (pipefail/SIGPIPE regression): $out"
grep -q "STUB-ARGS: exec review" <<<"$out" || fail "codex not invoked on large dirty tree: $out"
grep -q "manifest truncated at 200 entries" <<<"$out" || fail "truncation marker missing on >200-entry manifest: $out"
rm -f bulk_f*.txt

echo "==> clean tree at the base tip refuses, non-zero, without invoking codex"
git checkout -q -b tipcheck origin/develop
# Non-zero is the point: a capped review loop reads exit status, so a zero
# here would be banked as the clean pass the stage exits on.
if out="$(run review)"; then
    fail "nothing-to-review case exited zero (reads as a clean pass): $out"
fi
grep -q "Nothing to review" <<<"$out" || fail "expected nothing-to-review message: $out"
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite nothing to review: $out"

echo "==> at the base tip, a dirty tree reviews the worktree alone"
# The other side of the union: with no commits beyond the base there is no
# second half, so the split manifest and its headings must not appear.
echo tipwork >tipwork.txt
out="$(run review)" || fail "dirty tree at the base tip exited non-zero: $out"
grep -q "Review the uncommitted work" <<<"$out" || fail "base-tip dirty tree did not select the uncommitted scope: $out"
grep -q "BOTH parts are in scope" <<<"$out" && fail "union scope selected with no commits beyond the base: $out"
grep -q "Committed changes (git diff" <<<"$out" && fail "empty committed half still emitted a manifest section: $out"
grep -q "tipwork.txt" <<<"$out" || fail "worktree file missing from manifest: $out"
rm -f tipwork.txt

echo "==> --base level with its base refuses, non-zero, without invoking codex"
# The reported bug: an explicit --base built an empty manifest and shipped a
# scope string anyway, and Codex's "that diff is empty" reply exited 0 and
# consumed a round of a capped loop.
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite an empty --base diff: $out"
grep -q "Nothing to review" <<<"$out" || fail "missing empty--base refusal message: $out"
grep -q -- "--uncommitted" <<<"$out" || fail "empty --base refusal does not name the fix: $out"

echo "==> --base on a dirty tree says the uncommitted work is out of scope"
echo scratch >scratch.txt
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted on a dirty tree: $out"
fi
grep -q "working tree is dirty" <<<"$out" || fail "no dirty-tree note on --base: $out"
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite an empty --base diff: $out"

echo "==> --uncommitted on a clean tree refuses, non-zero, without invoking codex"
rm -f scratch.txt
if out="$(run review --uncommitted)"; then
    fail "--uncommitted on a clean tree was accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite a clean tree: $out"
grep -q "Nothing to review" <<<"$out" || fail "missing empty--uncommitted refusal message: $out"

echo "==> status.showUntrackedFiles=no cannot hide an untracked-only tree"
# Both the auto dirty-tree test and the --base warning read `git status`; with
# the default untracked mode, this config makes a tree holding only untracked
# work look clean, so the auto path would review the branch instead of the
# work, and --base would skip its warning.
git_t config status.showUntrackedFiles no
echo hidden >hidden.txt
out="$(run review)" || fail "untracked-only tree with showUntrackedFiles=no exited non-zero: $out"
grep -q "uncommitted work" <<<"$out" || fail "untracked-only tree was not seen as dirty: $out"
grep -q "hidden.txt" <<<"$out" || fail "untracked file missing from manifest: $out"
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted: $out"
fi
grep -q "working tree is dirty" <<<"$out" || fail "dirty-tree note suppressed by showUntrackedFiles=no: $out"
rm -f hidden.txt
git_t config --unset status.showUntrackedFiles

echo "==> --commit on an empty commit refuses, non-zero, without invoking codex"
git_t commit -q --allow-empty -m "empty commit"
if out="$(run review --commit HEAD)"; then
    fail "--commit on an empty commit was accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite an empty commit diff: $out"
grep -q "Nothing to review" <<<"$out" || fail "missing empty--commit refusal message: $out"
git_t reset -q --hard HEAD~1

echo "==> bad mode is rejected"
if out="$(run bogus 2>&1)"; then
    fail "bogus mode accepted: $out"
fi

echo "==> invalid explicit targets fail fast without invoking codex"
if out="$(run review --base no-such-ref 2>&1)"; then
    fail "--base with an unresolvable ref was accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite bad --base ref: $out"
grep -q "does not resolve" <<<"$out" || fail "missing fail-fast message for bad --base: $out"
if out="$(run challenge --commit 0000000000000000000000000000000000000000 2>&1)"; then
    fail "--commit with an unresolvable sha was accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite bad --commit sha: $out"

echo "==> conflicting target flags are rejected"
if out="$(run review --base origin/develop --uncommitted 2>&1)"; then
    fail "conflicting target flags accepted (last-wins regression): $out"
fi
grep -q "mutually exclusive" <<<"$out" || fail "missing conflicting-flags message: $out"
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite conflicting flags: $out"

echo "==> --commit manifests cover root and merge commits"
root_sha="$(git rev-list --max-parents=0 HEAD | tail -1)"
out="$(run review --commit "$root_sha")" || fail "root-commit review exited non-zero: $out"
grep -q "codex-review.sh" <<<"$out" || fail "root commit manifest empty (missing --root): $out"
git checkout -q -b mergetest feature
git branch -q sidebr "$root_sha"
git checkout -q sidebr
echo s >side.txt
git add side.txt
git_t commit -q -m side
git checkout -q mergetest
git_t merge -q --no-ff -m merge sidebr >/dev/null 2>&1 || fail "fixture merge failed"
merge_sha="$(git rev-parse HEAD)"
out="$(run review --commit "$merge_sha")" || fail "merge-commit review exited non-zero: $out"
grep -q "side.txt" <<<"$out" || fail "merge commit manifest missing first-parent change: $out"
grep -q "feature.txt" <<<"$out" && fail "merge manifest includes pre-merge mainline files (diff-tree -m regression): $out"

echo "==> a submodule-only change is not misread as empty under diff.ignoreSubmodules=all"
# The empty-scope guard turns "no files changed" into a hard refusal, so a
# config that hides a real change from `git diff` would block a legitimate
# review. Both helpers pass git's defaults explicitly to prevent that.
git init -q "${test_tmp}/submod"
(
    cd "${test_tmp}/submod"
    git_t commit -q --allow-empty -m one
    git_t commit -q --allow-empty -m two
)
git checkout -q -b submodtest feature
# protocol.file.allow: git >=2.38 refuses file:// submodules by default.
git -c protocol.file.allow=always submodule add -q "${test_tmp}/submod" vendored
git_t commit -q -m "add submodule"
submod_base="$(git rev-parse HEAD)"
(cd vendored && git checkout -q HEAD~1)
git add vendored
git_t commit -q -m "bump submodule pointer only"
git_t config diff.ignoreSubmodules all
out="$(run review --base "$submod_base")" || fail "submodule-only diff refused as empty: $out"
grep -q "vendored" <<<"$out" || fail "submodule gitlink missing from manifest: $out"
git_t config --unset diff.ignoreSubmodules

echo "==> an unresolvable base refuses, on a dirty tree as much as a clean one"
# Degrading to the worktree half would be the original bug in a new place: a
# fraction of the change reviewed, exit 0, and a stage that reads the status
# rather than the warning banks it as a clean pass. Which commits are missing
# is precisely what cannot be determined here, so there is no honest partial
# scope — the refusal names --uncommitted as the deliberate way to ask for one.
norem="${test_tmp}/norem"
mkdir -p "${norem}/scripts"
cp "${repo}/scripts/codex-review.sh" "${norem}/scripts/"
cp -R "${repo}/scripts/lib" "${norem}/scripts/"
git init -q -b feature "$norem"
(
    cd "$norem"
    git add -A
    git_t commit -q -m base
    if out="$(./scripts/codex-review.sh review 2>&1)"; then
        fail "clean tree with no detectable base was accepted: $out"
    fi
    grep -q "Could not resolve a base" <<<"$out" || fail "missing unresolvable-base message: $out"
    grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked with no resolvable base: $out"
    echo loose >loose.txt
    if out="$(./scripts/codex-review.sh review 2>&1)"; then
        fail "dirty tree with no detectable base reviewed the worktree alone and exited 0: $out"
    fi
    grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked on a partial scope: $out"
    grep -q -- "--uncommitted" <<<"$out" || fail "refusal does not name the deliberate narrow target: $out"
    # ...and that named escape must actually work, or the refusal is a dead end.
    out="$(./scripts/codex-review.sh review --uncommitted 2>&1)" || fail "--uncommitted refused with no base: $out"
    grep -q "loose.txt" <<<"$out" || fail "worktree file missing from --uncommitted manifest: $out"
)

echo "==> a git failure in either half is refused, not read as an empty half"
# Neither half may fail into "". A failed `git diff` with a dirty tree would
# leave the worktree half non-empty, satisfy the non-empty manifest backstop,
# and ship a one-sided review that exits 0 (a partial clone missing objects is
# the realistic trigger); a failed `git status` would read as a clean tree and
# do the same in reverse. The stub fails one subcommand, only when armed, so
# every other git call in the fixture behaves normally.
real_git="$(command -v git)"
cat >"${test_tmp}/bin/git" <<GITSTUB
#!/usr/bin/env bash
if [ -n "\${FAIL_GIT_DIFF:-}" ] && [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--no-ext-diff" ] && [ "\${3:-}" = "--name-status" ]; then
    echo "fatal: simulated missing object" >&2
    exit 128
fi
if [ -n "\${FAIL_GIT_STATUS:-}" ] && [ "\${1:-}" = "status" ]; then
    echo "fatal: simulated unreadable index" >&2
    exit 128
fi
exec "${real_git}" "\$@"
GITSTUB
chmod +x "${test_tmp}/bin/git"
git checkout -q feature
echo halfwork >halfwork.txt
if out="$(FAIL_GIT_DIFF=1 run review)"; then
    fail "an unreadable branch diff was reviewed as an empty half and exited 0: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked with a committed half that could not be read: $out"
grep -q "refusing rather than reading an unreadable" <<<"$out" || fail "missing unreadable-diff refusal message: $out"
if out="$(FAIL_GIT_STATUS=1 run review)"; then
    fail "an unreadable worktree was reviewed as clean and exited 0: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked with a worktree half that could not be read: $out"
grep -q "refusing rather than reading an unreadable worktree" <<<"$out" || fail "missing unreadable-worktree refusal message: $out"
rm -f halfwork.txt "${test_tmp}/bin/git"

# The reported bug: one codex_models_manager decode error inlines the entire
# models JSON as a single ~195 KiB stderr line, and the CLI retries, so eleven
# lines carried 2.1 MB of a 2.2 MB captured log — the verdict a plain `tail`
# should have shown was buried, and `cat`-ing the log to read the findings
# overran an agent's tool-output limit. The bound is on line LENGTH rather than
# on that message, so these guard the class: any future payload dump is covered.
echo bound >bound.txt
big_out="${test_tmp}/bound.out"
big_err="${test_tmp}/bound.err"
longest() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$1"; }

echo "==> an over-long CLI stderr line is bounded, and stdout is left alone"
STUB_BIG_STDERR=40000 ./scripts/codex-review.sh review --uncommitted >"$big_out" 2>"$big_err" ||
    fail "review with a payload-dumping stub exited non-zero: $(cat "$big_err")"
[ "$(longest "$big_err")" -lt 2000 ] ||
    fail "over-long stderr line was not bounded (longest $(longest "$big_err") bytes)"
grep -q "truncated by codex-review.sh" "$big_err" ||
    fail "no truncation marker, so a reader cannot tell output was dropped"
grep -q "short stderr narration" "$big_err" ||
    fail "bounding the long line also dropped the ordinary narration around it"
# stdout carries the verdict, where a long prose line is legitimate; filtering
# it would corrupt the very output the bound exists to keep readable.
[ "$(longest "$big_out")" -gt 4000 ] ||
    fail "a long stdout line was truncated; only stderr may be bounded"
grep -q "truncated by codex-review.sh" "$big_out" &&
    fail "truncation marker reached stdout; only stderr may be bounded"

echo "==> the stderr filter preserves the CLI's exit status"
# pipefail must surface codex's own status, not the filter's — otherwise a
# failed review reads as the clean pass a capped loop exits on.
status=0
STUB_EXIT=7 STUB_BIG_STDERR=40000 ./scripts/codex-review.sh review --uncommitted >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "codex exit status lost through the filter (got ${status}, want 7)"

echo "==> CODEX_REVIEW_MAX_STDERR_BYTES=0 restores the unbounded output"
CODEX_REVIEW_MAX_STDERR_BYTES=0 STUB_BIG_STDERR=40000 \
    ./scripts/codex-review.sh review --uncommitted >/dev/null 2>"$big_err" ||
    fail "review with the bound disabled exited non-zero: $(cat "$big_err")"
[ "$(longest "$big_err")" -gt 40000 ] ||
    fail "escape hatch did not restore the full line (longest $(longest "$big_err") bytes)"

echo "==> a non-numeric bound is refused before the CLI is invoked"
if out="$(CODEX_REVIEW_MAX_STDERR_BYTES=abc ./scripts/codex-review.sh review --uncommitted 2>&1)"; then
    fail "non-numeric bound accepted: $out"
fi
grep -q "STUB-ARGS" <<<"$out" && fail "codex invoked despite an invalid bound: $out"
grep -q "must be a non-negative integer" <<<"$out" || fail "missing validation message: $out"

echo "==> a bound past INT64_MAX is refused rather than leaking a shell error"
# All-digit but too wide for `test -eq`, which fails with "integer expression
# expected" ON STDERR and then runs effectively unbounded — a shell error in
# the very stream this change exists to keep clean.
if out="$(CODEX_REVIEW_MAX_STDERR_BYTES=999999999999999999999 ./scripts/codex-review.sh review --uncommitted 2>&1)"; then
    fail "an INT64_MAX-exceeding bound was accepted: $out"
fi
grep -q "integer expression expected" <<<"$out" && fail "shell arithmetic error leaked to the caller: $out"
grep -q "implausibly large" <<<"$out" || fail "missing implausible-bound message: $out"
# The widest value that still compares cleanly must keep working.
CODEX_REVIEW_MAX_STDERR_BYTES=999999999999999999 STUB_BIG_STDERR=40000 \
    ./scripts/codex-review.sh review --uncommitted >/dev/null 2>"$big_err" ||
    fail "the widest safe bound was rejected: $(cat "$big_err")"
grep -q "integer expression expected" "$big_err" && fail "shell arithmetic error at the 18-digit boundary: $(cat "$big_err")"
rm -f bound.txt

echo "==> gate: another repo's project-scoped plugin install is not accepted"
fake_claude="${test_tmp}/claude-config"
mkdir -p "${fake_claude}/plugins"
cat >"${fake_claude}/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "codex@openai-codex": [
      {
        "scope": "project",
        "projectPath": "/some/other/repo",
        "installPath": "/nonexistent/plugin/root",
        "version": "1.0.6"
      }
    ]
  }
}
JSON
if out="$( (
    export CLAUDE_CONFIG_DIR="$fake_claude"
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate enable accepted an install scoped to another repo: $out"
fi
grep -q "not installed" <<<"$out" || fail "missing not-installed message for foreign-scoped install: $out"

echo "==> gate: refuses to arm when the companion reports not ready"
fake_plugin="${test_tmp}/fake-plugin"
mkdir -p "${fake_plugin}/scripts" "${fake_claude}2/plugins"
cat >"${fake_plugin}/scripts/codex-companion.mjs" <<'MJS'
const args = process.argv.slice(2);
if (args.includes("--json")) {
  console.log(JSON.stringify({ ready: process.env.FAKE_READY === "true" }));
} else {
  console.log(`companion invoked: ${args.join(" ")}`);
}
MJS
cat >"${fake_claude}2/plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "codex@openai-codex": [
      { "scope": "user", "installPath": "${fake_plugin}", "version": "1.0.6" }
    ]
  }
}
JSON
if out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=false
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate armed despite companion ready:false: $out"
fi
grep -q "not ready" <<<"$out" || fail "missing not-ready refusal message: $out"

echo "==> gate: arms when the companion reports ready"
out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)" ||
    fail "gate enable failed with companion ready:true: $out"
grep -q "companion invoked: setup --enable-review-gate" <<<"$out" || fail "companion toggle not invoked after readiness pass: $out"

echo "==> gate: refuses when the plugin is explicitly disabled in settings"
ws="${test_tmp}/ws"
mkdir -p "${ws}/scripts" "${ws}/.claude"
cp "${repo}/scripts/codex-gate.sh" "${ws}/scripts/"
printf '%s\n' '{ "enabledPlugins": { "codex@openai-codex": false } }' >"${ws}/.claude/settings.local.json"
if out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${ws}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate armed despite plugin disabled in settings: $out"
fi
grep -q "explicitly disabled" <<<"$out" || fail "missing disabled-plugin refusal message: $out"

echo "==> gate: status warns that an armed flag is inert when the plugin is disabled"
out="$(
    (
        export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data"
        "${ws}/scripts/codex-gate.sh" status
    ) 2>&1
)" || fail "status exited non-zero in disabled-plugin workspace: $out"
grep -q "INERT" <<<"$out" || fail "status did not flag the inert gate flag: $out"

echo "==> gate: enable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true "${repo}/scripts/codex-gate.sh" enable </dev/null 2>&1)"; then
    fail "non-interactive enable was accepted (silent arming bypass): $out"
fi
grep -q "non-interactive" <<<"$out" || fail "missing non-interactive enable refusal message: $out"

echo "==> gate: disable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" "${repo}/scripts/codex-gate.sh" disable </dev/null 2>&1)"; then
    fail "non-interactive disable was accepted (agent could disarm its own gate): $out"
fi
grep -q "non-interactive" <<<"$out" || fail "missing non-interactive disable refusal message: $out"

echo "codex-review + codex-gate guards OK ($((74 + standardize_cases)) cases)"
