#!/usr/bin/env bash
# Hermetic regression coverage for the composite action's pinned lint tools.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
root_action="${repo}/.github/actions/setup/action.yml"
template_action="${repo}/template/.github/actions/setup/action.yml.jinja"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d -t harmon-init-setup-versions-XXXXXX)"
# The gitleaks installer hardcodes /tmp/gitleaks.tgz (no RUNNER_TEMP-scoped
# override exists for it, unlike the lint tools below) — the fake curl below
# writes there faithfully, so clean it up alongside the test's own scratch dir.
trap 'rm -rf "$test_tmp" /tmp/gitleaks.tgz' EXIT
stale_bin="${test_tmp}/stale-bin"
helper_bin="${test_tmp}/helpers"
curl_log="${test_tmp}/curl.log"
install_log="${test_tmp}/install.log"
mkdir -p "$stale_bin" "$helper_bin"
: >"$curl_log"
: >"$install_log"

# Bind the test to the real action body and prove the complete shared installer
# segment stays identical between the root action and its template twin.
python3 - "$root_action" "$template_action" "${test_tmp}/install-lint-tools.sh" <<'PY'
import pathlib
import sys

root_path, template_path, output_path = sys.argv[1:]
root = pathlib.Path(root_path).read_text()
template = pathlib.Path(template_path).read_text()


def installer_segment(text: str) -> str:
    start = text.index(
        "        # renovate: datasource=github-releases depName=koalaman/shellcheck "
    )
    end = text.index("\n    - name: Install gitleaks", start)
    return text[start:end] + "\n"


root_segment = installer_segment(root)
template_segment = "\n".join(
    line
    for line in installer_segment(template).splitlines()
    if line not in ("[% if use_skills_sync %]", "[% endif %]")
) + "\n"
if root_segment != template_segment:
    raise SystemExit("root/template pinned lint-tool installer segments differ")
if "| grep -q" in root_segment:
    raise SystemExit("version guard reintroduced the producer | grep -q hazard")
for expected in (
    "X64|x86_64)",
    "ARM64|arm64|aarch64)",
    "Unsupported runner architecture",
    "harmon-init-lint-tools-download.XXXXXX",
    '>> "$GITHUB_PATH"',
    "fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1",
    "32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7",
    "a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7",
    "0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156",
):
    if expected not in root_segment:
        raise SystemExit(f"installer segment is missing {expected!r}")

def extract_step_body(text: str, step_name: str) -> list[str]:
    lines = text.splitlines()
    step = lines.index(f"    - name: {step_name}")
    run = next(i for i in range(step + 1, len(lines)) if lines[i] == "      run: |")
    body = []
    for line in lines[run + 1 :]:
        # A column-0 jinja directive (e.g. "[% if use_python %]" gating the
        # NEXT step) ends the body exactly like a literal next step would.
        if line.startswith("    - ") or line.startswith("[%"):
            break
        if not line.startswith("        ") and line:
            raise SystemExit(f"unexpected indentation in {step_name!r} body: {line!r}")
        body.append(line[8:] if line else "")
    if not body:
        raise SystemExit(f"{step_name!r} action body extraction was empty")
    return body


def write_script(body: list[str], out: str) -> None:
    pathlib.Path(out).write_text(
        "#!/usr/bin/env bash\nset -euo pipefail\n" + "\n".join(body) + "\n"
    )


write_script(
    extract_step_body(
        root, "Install lint tools (file, shellcheck, shfmt, actionlint, yamllint, yq)"
    ),
    output_path,
)

# gitleaks/snyk bodies are NOT jinja-conditional — byte-identical in both
# files — so extracting from root alone and cross-checking equality with the
# template's own extraction pins both against drift in one assertion.
gitleaks_root = extract_step_body(root, "Install gitleaks")
gitleaks_template = extract_step_body(template, "Install gitleaks")
if gitleaks_root != gitleaks_template:
    raise SystemExit("root/template Install-gitleaks bodies differ")
snyk_root = extract_step_body(root, "Install Snyk CLI")
snyk_template = extract_step_body(template, "Install Snyk CLI")
if snyk_root != snyk_template:
    raise SystemExit("root/template Install-Snyk-CLI bodies differ")
for expected in (
    "X64|x86_64) gitleaks_arch=x64 ;;",
    "ARM64|arm64|aarch64) gitleaks_arch=arm64 ;;",
    "Unsupported runner architecture for pinned gitleaks",
    "linux_${gitleaks_arch}.tar.gz",
):
    if expected not in "\n".join(gitleaks_root):
        raise SystemExit(f"Install-gitleaks body is missing {expected!r}")
write_script(gitleaks_root, f"{output_path}.gitleaks")
write_script(snyk_root, f"{output_path}.snyk")
PY
chmod +x "${test_tmp}/install-lint-tools.sh" "${test_tmp}/install-lint-tools.sh.gitleaks" \
    "${test_tmp}/install-lint-tools.sh.snyk"

cat >"${stale_bin}/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.9.0'
EOF
cat >"${stale_bin}/shfmt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'v3.12.0'
EOF
cat >"${stale_bin}/actionlint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '1.7.11' 'installed by building from source' 'built with go1.24.0 compiler for linux/amd64'
EOF
cat >"${stale_bin}/yq" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
cat >"${stale_bin}/yamllint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'yamllint 1.37.1'
EOF
cat >"${helper_bin}/file" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${helper_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
    -o)
        output="$2"
        shift 2
        ;;
    http*)
        url="$1"
        shift
        ;;
    *) shift ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ]
mkdir -p "$(dirname "$output")"
printf '%s|%s\n' "$output" "$url" >>"$TEST_CURL_LOG"
case "${output##*/}" in
shfmt)
    cat >"$output" <<'SHFMT'
#!/usr/bin/env bash
printf '%s\n' 'v3.13.1'
SHFMT
    chmod +x "$output"
    ;;
yq)
    cat >"$output" <<'YQ'
#!/usr/bin/env bash
printf '%s\n' 'yq (https://github.com/mikefarah/yq/) version v4.44.3'
YQ
    chmod +x "$output"
    ;;
*) printf '%s\n' archive >"$output" ;;
esac
EOF
cat >"${helper_bin}/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
archive=
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
    -xJf|-xzf)
        archive="$2"
        shift 2
        ;;
    -C)
        destination="$2"
        shift 2
        ;;
    *) shift ;;
    esac
done
[ -n "$archive" ] && [ -n "$destination" ]
case "${archive##*/}" in
shellcheck.tar.xz)
    mkdir -p "${destination}/shellcheck-v0.11.0"
    cat >"${destination}/shellcheck-v0.11.0/shellcheck" <<'SHELLCHECK'
#!/usr/bin/env bash
printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.11.0'
SHELLCHECK
    chmod +x "${destination}/shellcheck-v0.11.0/shellcheck"
    ;;
actionlint.tar.gz)
    cat >"${destination}/actionlint" <<'ACTIONLINT'
#!/usr/bin/env bash
printf '%s\n' '1.7.12' 'installed by building from source' 'built with go1.24.0 compiler for linux/amd64'
ACTIONLINT
    chmod +x "${destination}/actionlint"
    ;;
*) exit 1 ;;
esac
EOF
cat >"${helper_bin}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=' ' read -r expected_digest downloaded_path
[ -n "$expected_digest" ] && [ -n "$downloaded_path" ]
asset_url=
while IFS='|' read -r logged_path logged_url; do
    if [ "$logged_path" = "$downloaded_path" ]; then
        asset_url="$logged_url"
    fi
done <"$TEST_CURL_LOG"
case "${asset_url}|${expected_digest}" in
*/shfmt_v3.13.1_linux_amd64\|fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1 | \
    */shfmt_v3.13.1_linux_arm64\|32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7 | \
    */yq_linux_amd64\|a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7 | \
    */yq_linux_arm64\|0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156)
        ;;
*)
    printf 'unexpected asset/checksum pair: %s|%s\n' "$asset_url" "$expected_digest" >&2
    exit 1
    ;;
esac
EOF
cat >"${helper_bin}/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = -m ] && [ "$2" = venv ]
venv_path="$3"
mkdir -p "${venv_path}/bin"
cat >"${venv_path}/bin/python" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 5 ] && [ "$1" = -m ] && [ "$2" = pip ] && [ "$3" = install ]
[ "$4" = --disable-pip-version-check ] && [ "$5" = yamllint==1.38.0 ]
venv_bin="$(dirname "$0")"
cat >"${venv_bin}/yamllint" <<'YAMLLINT'
#!/usr/bin/env bash
printf '%s\n' 'yamllint 1.38.0'
YAMLLINT
chmod +x "${venv_bin}/yamllint"
printf '%s|%s\n' yamllint "${venv_bin}/yamllint" >>"$TEST_INSTALL_LOG"
PYTHON
chmod +x "${venv_path}/bin/python"
EOF
cat >"${helper_bin}/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -m ] && [ "$2" = 0755 ] && [ "$#" -eq 4 ]
source_path="$3"
destination="$4"
mkdir -p "$(dirname "$destination")"
cp "$source_path" "$destination"
chmod +x "$destination"
printf '%s|%s\n' "${destination##*/}" "$destination" >>"$TEST_INSTALL_LOG"
EOF
chmod +x "${stale_bin}"/* "${helper_bin}"/*

run_action() {
    arch="$1"
    runner_temp="$2"
    github_path="$3"
    effective_path="${stale_bin}:${helper_bin}:${PATH}"
    if [ -s "$github_path" ]; then
        published_bin="$(tail -n 1 "$github_path")"
        effective_path="${published_bin}:${effective_path}"
    fi
    PATH="$effective_path" \
        RUNNER_ARCH="$arch" \
        RUNNER_TEMP="$runner_temp" \
        GITHUB_PATH="$github_path" \
        TEST_CURL_LOG="$curl_log" \
        TEST_INSTALL_LOG="$install_log" \
        "${test_tmp}/install-lint-tools.sh"
}

assert_pins() {
    published_bin="$1"
    tool_path="${published_bin}:${stale_bin}:${helper_bin}:${PATH}"
    shellcheck_output="$(PATH="$tool_path" shellcheck --version)"
    case "$shellcheck_output" in
    *"version: 0.11.0"*) : ;;
    *) fail "wrong-version shellcheck remained authoritative: ${shellcheck_output}" ;;
    esac
    [ "$(PATH="$tool_path" shfmt --version)" = v3.13.1 ] ||
        fail "wrong-version shfmt remained authoritative"
    actionlint_output="$(PATH="$tool_path" actionlint --version)"
    case "$actionlint_output" in
    1.7.12$'\n'*) : ;;
    *) fail "wrong-version actionlint remained authoritative: ${actionlint_output}" ;;
    esac
    [ "$(PATH="$tool_path" yq --version)" = 'yq (https://github.com/mikefarah/yq/) version v4.44.3' ] ||
        fail "missing yq was not replaced with the architecture-correct pin"
    [ "$(PATH="$tool_path" yamllint --version)" = 'yamllint 1.38.0' ] ||
        fail "wrong-version yamllint remained authoritative"
}

run_arch_case() {
    arch="$1"
    shellcheck_asset="$2"
    shfmt_asset="$3"
    actionlint_asset="$4"
    yq_asset="$5"
    runner_temp="${test_tmp}/runner-${arch}"
    github_path="${test_tmp}/github-path-${arch}"
    mkdir -p "$runner_temp"
    : >"$github_path"

    installs_before="$(wc -l <"$install_log" | tr -d ' ')"
    run_action "$arch" "$runner_temp" "$github_path"
    published_bin="$(tail -n 1 "$github_path")"
    case "$published_bin" in
    "${runner_temp}/harmon-init-lint-tools/0.11.0-3.13.1-1.7.12-1.38.0/${arch}") : ;;
    *) fail "${arch}: GITHUB_PATH did not receive the job-private versioned bin first" ;;
    esac
    assert_pins "$published_bin"

    grep -Fq "/${shellcheck_asset}" "$curl_log" || fail "${arch}: wrong shellcheck asset"
    grep -Fq "/${shfmt_asset}" "$curl_log" || fail "${arch}: wrong shfmt asset"
    grep -Fq "/${actionlint_asset}" "$curl_log" || fail "${arch}: wrong actionlint asset"
    grep -Fq "/${yq_asset}" "$curl_log" || fail "${arch}: wrong yq asset"
    if grep -Fq '/usr/local/bin' "$install_log"; then
        fail "${arch}: installer still wrote to the host-global bin directory"
    fi

    installs_after="$(wc -l <"$install_log" | tr -d ' ')"
    [ "$((installs_after - installs_before))" -eq 5 ] ||
        fail "${arch}: mismatched or missing tools were not each installed exactly once"

    # A second invocation in the same job sees the published versioned bin at
    # the front of PATH and must not install again.
    run_action "$arch" "$runner_temp" "$github_path"
    [ "$(wc -l <"$install_log" | tr -d ' ')" -eq "$installs_after" ] ||
        fail "${arch}: matching pinned tools were reinstalled"
}

run_arch_case X64 \
    shellcheck-v0.11.0.linux.x86_64.tar.xz \
    shfmt_v3.13.1_linux_amd64 \
    actionlint_1.7.12_linux_amd64.tar.gz \
    yq_linux_amd64
run_arch_case ARM64 \
    shellcheck-v0.11.0.linux.aarch64.tar.xz \
    shfmt_v3.13.1_linux_arm64 \
    actionlint_1.7.12_linux_arm64.tar.gz \
    yq_linux_arm64

# The stale PATH entries remain untouched; precedence comes only from the
# job-private directory published by the action.
[ "$(PATH="${stale_bin}:${PATH}" shfmt --version)" = v3.12.0 ] ||
    fail "fixture did not keep the stale PATH tool ahead of /usr/local/bin"

x64_download="$(sed -n '1p' "$curl_log")"
arm64_download="$(sed -n '5p' "$curl_log")"
x64_download_dir="$(dirname "${x64_download%%|*}")"
arm64_download_dir="$(dirname "${arm64_download%%|*}")"
[ "$x64_download_dir" != "$arm64_download_dir" ] ||
    fail "architecture runs reused one download directory"
case "$x64_download_dir" in
"${test_tmp}/runner-X64"/harmon-init-lint-tools-download.*) : ;;
*) fail "X64 downloads escaped RUNNER_TEMP" ;;
esac
case "$arm64_download_dir" in
"${test_tmp}/runner-ARM64"/harmon-init-lint-tools-download.*) : ;;
*) fail "ARM64 downloads escaped RUNNER_TEMP" ;;
esac

unsupported_temp="${test_tmp}/runner-unsupported"
unsupported_path="${test_tmp}/github-path-unsupported"
mkdir -p "$unsupported_temp"
: >"$unsupported_path"
curl_count="$(wc -l <"$curl_log" | tr -d ' ')"
if unsupported_output="$(run_action RISCV64 "$unsupported_temp" "$unsupported_path" 2>&1)"; then
    fail "unsupported architecture was accepted"
fi
case "$unsupported_output" in
*"Unsupported runner architecture"*) : ;;
*) fail "unsupported architecture failure did not explain the refusal" ;;
esac
[ "$(wc -l <"$curl_log" | tr -d ' ')" -eq "$curl_count" ] ||
    fail "unsupported architecture downloaded an asset before failing"

## ── gitleaks: version-check reuse + architecture selection (#1241 item 2) ──

gitleaks_bin="${test_tmp}/gitleaks-bin"
fake_usr_local_bin="${test_tmp}/fake-usr-local-bin"
gitleaks_curl_log="${test_tmp}/gitleaks-curl.log"
gitleaks_mv_log="${test_tmp}/gitleaks-mv.log"
mkdir -p "$gitleaks_bin" "$fake_usr_local_bin"

cat >"${gitleaks_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
    -o)
        output="$2"
        shift 2
        ;;
    http*)
        url="$1"
        shift
        ;;
    *) shift ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ]
printf '%s|%s\n' "$output" "$url" >>"$GITLEAKS_CURL_LOG"
printf 'fake archive\n' >"$output"
EOF
cat >"${gitleaks_bin}/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
    -C)
        destination="$2"
        shift 2
        ;;
    *) shift ;;
    esac
done
[ -n "$destination" ]
printf '#!/usr/bin/env bash\nprintf "%s\\n" "%s"\n' "$FAKE_GITLEAKS_DOWNLOADED_VERSION" >"${destination}/gitleaks"
chmod +x "${destination}/gitleaks"
EOF
# The real script hardcodes /tmp and /usr/local/bin (no RUNNER_TEMP-scoped
# override exists for gitleaks, unlike the lint tools above), so the fake
# mv redirects only the one destination this test must not actually write —
# every other invocation passes through to the real mv unchanged.
cat >"${gitleaks_bin}/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"\$GITLEAKS_MV_LOG"
if [ "\$#" -eq 2 ] && [ "\$2" = /usr/local/bin/gitleaks ]; then
    exec $(command -v mv) "\$1" "${fake_usr_local_bin}/gitleaks"
fi
exec $(command -v mv) "\$@"
EOF
cat >"${gitleaks_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
chmod +x "${gitleaks_bin}"/*

run_gitleaks_install() {
    local arch="$1" pre_installed_path="$2"
    rm -f "${fake_usr_local_bin}/gitleaks"
    : >"$gitleaks_curl_log"
    : >"$gitleaks_mv_log"
    PATH="${pre_installed_path}:${gitleaks_bin}:${PATH}" \
        RUNNER_ARCH="$arch" \
        GITLEAKS_CURL_LOG="$gitleaks_curl_log" \
        GITLEAKS_MV_LOG="$gitleaks_mv_log" \
        FAKE_GITLEAKS_DOWNLOADED_VERSION="8.24.3" \
        bash "${test_tmp}/install-lint-tools.sh.gitleaks"
}

echo "==> a pre-installed gitleaks matching the pin is reused, not redownloaded"
gitleaks_match_bin="${test_tmp}/gitleaks-match-bin"
mkdir -p "$gitleaks_match_bin"
cat >"${gitleaks_match_bin}/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf '8.24.3\n'
EOF
chmod +x "${gitleaks_match_bin}/gitleaks"
run_gitleaks_install X64 "$gitleaks_match_bin"
[ ! -s "$gitleaks_curl_log" ] ||
    fail "a version-matching pre-installed gitleaks was redownloaded"
[ ! -e "${fake_usr_local_bin}/gitleaks" ] ||
    fail "a version-matching pre-installed gitleaks was reinstalled to /usr/local/bin"

echo "==> a pre-installed gitleaks at the WRONG version is replaced (#1241 item 2)"
gitleaks_stale_bin="${test_tmp}/gitleaks-stale-bin"
mkdir -p "$gitleaks_stale_bin"
cat >"${gitleaks_stale_bin}/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf '8.18.0\n'
EOF
chmod +x "${gitleaks_stale_bin}/gitleaks"
run_gitleaks_install X64 "$gitleaks_stale_bin"
grep -Fq '/gitleaks_8.24.3_linux_x64.tar.gz' "$gitleaks_curl_log" ||
    fail "a version-mismatched pre-installed gitleaks was not replaced with the pin"
[ "$(bash "${fake_usr_local_bin}/gitleaks")" = "8.24.3" ] ||
    fail "the replacement gitleaks binary is not the pinned version"

echo "==> gitleaks architecture selection: X64 and ARM64 fetch the matching asset, an unsupported arch fails loudly"
run_gitleaks_install X64 "$test_tmp/nonexistent"
grep -Fq '/gitleaks_8.24.3_linux_x64.tar.gz' "$gitleaks_curl_log" ||
    fail "X64 did not fetch the x64 gitleaks asset"
run_gitleaks_install ARM64 "$test_tmp/nonexistent"
grep -Fq '/gitleaks_8.24.3_linux_arm64.tar.gz' "$gitleaks_curl_log" ||
    fail "ARM64 did not fetch the arm64 gitleaks asset"
: >"$gitleaks_curl_log"
if gitleaks_unsupported_output="$(PATH="${test_tmp}/nonexistent:${gitleaks_bin}:${PATH}" \
    RUNNER_ARCH=RISCV64 GITLEAKS_CURL_LOG="$gitleaks_curl_log" GITLEAKS_MV_LOG="$gitleaks_mv_log" \
    bash "${test_tmp}/install-lint-tools.sh.gitleaks" 2>&1)"; then
    fail "an unsupported runner architecture was accepted for gitleaks"
fi
case "$gitleaks_unsupported_output" in
*"Unsupported runner architecture for pinned gitleaks"*) : ;;
*) fail "unsupported gitleaks architecture failure did not explain the refusal" ;;
esac
[ ! -s "$gitleaks_curl_log" ] ||
    fail "unsupported gitleaks architecture downloaded an asset before failing"

## ── Snyk: version-check reuse (#1241 item 2) ───────────────────────────────

snyk_bin="${test_tmp}/snyk-bin"
npm_log="${test_tmp}/npm.log"
mkdir -p "$snyk_bin"
cat >"${snyk_bin}/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$NPM_LOG"
EOF
chmod +x "${snyk_bin}/npm"

run_snyk_install() {
    local pre_installed_path="$1"
    : >"$npm_log"
    PATH="${pre_installed_path}:${snyk_bin}:${PATH}" NPM_LOG="$npm_log" \
        bash "${test_tmp}/install-lint-tools.sh.snyk"
}

echo "==> a pre-installed Snyk CLI matching the pin is reused, not reinstalled"
snyk_match_bin="${test_tmp}/snyk-match-bin"
mkdir -p "$snyk_match_bin"
cat >"${snyk_match_bin}/snyk" <<'EOF'
#!/usr/bin/env bash
printf '1.1305.2\n'
EOF
chmod +x "${snyk_match_bin}/snyk"
run_snyk_install "$snyk_match_bin"
[ ! -s "$npm_log" ] ||
    fail "a version-matching pre-installed Snyk CLI was reinstalled"

echo "==> a pre-installed Snyk CLI at the WRONG version is replaced (#1241 item 2)"
snyk_stale_bin="${test_tmp}/snyk-stale-bin"
mkdir -p "$snyk_stale_bin"
cat >"${snyk_stale_bin}/snyk" <<'EOF'
#!/usr/bin/env bash
printf '1.1200.0\n'
EOF
chmod +x "${snyk_stale_bin}/snyk"
run_snyk_install "$snyk_stale_bin"
grep -Fq 'snyk@1.1305.2' "$npm_log" ||
    fail "a version-mismatched pre-installed Snyk CLI was not replaced with the pin"

echo "==> a missing Snyk CLI is installed"
run_snyk_install "$test_tmp/nonexistent"
grep -Fq 'snyk@1.1305.2' "$npm_log" ||
    fail "a missing Snyk CLI was not installed"

echo "setup action tool-version checks: PASS"
