# hadolint global ignore=DL3002,DL3008,DL3059
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:d94c97dd9cacf183d0a6fd12a8e87b526e9e928307674ae9c94139139c0c6eae

ARG TARGETARCH
ARG IMAGE_REVISION

# ---------- version pins ----------
# The producer is the one canonical owner of shared devcontainer tool pins.
# renovate: datasource=github-releases depName=go-task/task extractVersion=^v?(?<version>.+)$
ARG TASK_VERSION=3.53.1
# renovate: datasource=github-releases depName=mvdan/sh extractVersion=^v?(?<version>.+)$
ARG SHFMT_VERSION=3.13.1
# renovate: datasource=github-releases depName=hadolint/hadolint extractVersion=^v?(?<version>.+)$
ARG HADOLINT_VERSION=2.15.1
# renovate: datasource=github-releases depName=rhysd/actionlint extractVersion=^v?(?<version>.+)$
ARG ACTIONLINT_VERSION=1.7.12
# renovate: datasource=github-releases depName=terraform-docs/terraform-docs extractVersion=^v?(?<version>.+)$
ARG TERRAFORM_DOCS_VERSION=0.24.0
# renovate: datasource=github-releases depName=hashicorp/terraform extractVersion=^v?(?<version>.+)$
ARG TERRAFORM_VERSION=1.16.0
# renovate: datasource=github-releases depName=terraform-linters/tflint extractVersion=^v?(?<version>.+)$
ARG TFLINT_VERSION=0.64.0
# TFLint release-archive SHA-256 values. The version pin is Renovate-managed;
# update these reviewed, architecture-specific digests with each release.
ARG TFLINT_SHA256_AMD64=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537
ARG TFLINT_SHA256_ARM64=560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v?(?<version>.+)$
ARG YQ_VERSION=4.53.6
# renovate: datasource=github-releases depName=zellij-org/zellij extractVersion=^v?(?<version>.+)$
ARG ZELLIJ_VERSION=0.45.1
# renovate: datasource=github-releases depName=raine/workmux extractVersion=^v?(?<version>.+)$
ARG WORKMUX_VERSION=0.1.248
# renovate: datasource=github-releases depName=njbrake/agent-of-empires extractVersion=^v?(?<version>.+)$
ARG AOE_VERSION=1.15.1
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.250
# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.150.1
# renovate: datasource=npm depName=@github/copilot
ARG COPILOT_VERSION=1.0.82
# renovate: datasource=npm depName=@earendil-works/pi-coding-agent
ARG PI_VERSION=0.84.4
# renovate: datasource=github-releases depName=can1357/oh-my-pi extractVersion=^v?(?<version>.+)$
ARG OH_MY_PI_VERSION=18.1.2
# oh-my-pi release-archive SHA-256 values. The version pin is Renovate-managed;
# update these reviewed, architecture-specific digests with each release.
ARG OH_MY_PI_SHA256_AMD64=c6a306347a57c872bf38587e81132db50490228867e3e179a363a4cf874da1a0
ARG OH_MY_PI_SHA256_ARM64=2865c21a73ae8b893fd5553bf302afc5be8a0bcafa015af99732349d518830da
# renovate: datasource=npm depName=opencode-ai
ARG OPENCODE_VERSION=1.18.25
# Pinned from Google's per-platform release manifests. Keep the version, build,
# URLs, and SHA-512 values here and in ensure-antigravity-cli.sh in one update.
ARG ANTIGRAVITY_CLI_VERSION=1.1.11
ARG ANTIGRAVITY_CLI_BUILD=4956531888881664
# renovate: datasource=github-releases depName=asheshgoplani/agent-deck extractVersion=^v?(?<version>.+)$
ARG AGENT_DECK_VERSION=1.15.0
# renovate: datasource=github-releases depName=joshmedeski/sesh extractVersion=^v?(?<version>.+)$
ARG SESH_VERSION=2.28.0
# renovate: datasource=github-releases depName=herdrdev/herdr extractVersion=^v?(?<version>.+)$
# Apache-2.0 as of v0.8.0 (AGPL-3.0 before) — never pin below 0.8.0
ARG HERDR_VERSION=0.8.2
# renovate: datasource=npm depName=dmux
ARG DMUX_VERSION=5.11.1
# renovate: datasource=pypi depName=semgrep
ARG SEMGREP_VERSION=1.175.0
# renovate: datasource=pypi depName=copier
ARG COPIER_VERSION=9.17.2
# renovate: datasource=npm depName=@playwright/test
ARG PLAYWRIGHT_VERSION=1.62.1
# renovate: datasource=npm depName=@playwright/cli
ARG PLAYWRIGHT_CLI_VERSION=0.1.18
# renovate: datasource=github-releases depName=getsops/sops extractVersion=^v?(?<version>.+)$
ARG SOPS_VERSION=3.13.3
# renovate: datasource=github-releases depName=nektos/act extractVersion=^v?(?<version>.+)$
ARG ACT_VERSION=0.2.89
# renovate: datasource=github-releases depName=wagoodman/dive extractVersion=^v?(?<version>.+)$
ARG DIVE_VERSION=0.13.1
# renovate: datasource=github-releases depName=antonmedv/fx extractVersion=^v?(?<version>.+)$
ARG FX_VERSION=39.2.0
# renovate: datasource=github-releases depName=charmbracelet/glow extractVersion=^v?(?<version>.+)$
ARG GLOW_VERSION=2.1.2
# renovate: datasource=github-releases depName=jesseduffield/lazygit extractVersion=^v?(?<version>.+)$
ARG LAZYGIT_VERSION=0.64.1
# renovate: datasource=github-releases depName=XAMPPRocky/tokei extractVersion=^v?(?<version>.+)$
ARG TOKEI_VERSION=13.0.0-alpha.0
# renovate: datasource=github-releases depName=dlvhdr/gh-dash extractVersion=^v?(?<version>.+)$
ARG GH_DASH_VERSION=4.25.2
# renovate: datasource=github-releases depName=charmbracelet/gum extractVersion=^v?(?<version>.+)$
ARG GUM_VERSION=0.17.0
# renovate: datasource=github-releases depName=o2sh/onefetch extractVersion=^v?(?<version>.+)$
ARG ONEFETCH_VERSION=2.27.1
# renovate: datasource=github-releases depName=wtfutil/wtf extractVersion=^v?(?<version>.+)$
ARG WTF_VERSION=0.50.0
# renovate: datasource=github-releases depName=ducaale/xh extractVersion=^v?(?<version>.+)$
ARG XH_VERSION=0.26.2
# renovate: datasource=github-releases depName=evilmartians/lefthook extractVersion=^v?(?<version>.+)$
ARG LEFTHOOK_VERSION=2.1.12
# renovate: datasource=github-releases depName=gitleaks/gitleaks extractVersion=^v?(?<version>.+)$
ARG GITLEAKS_VERSION=8.30.1
# renovate: datasource=github-releases depName=lycheeverse/lychee extractVersion=^lychee-v(?<version>.+)$
ARG LYCHEE_VERSION=0.24.2
# renovate: datasource=github-releases depName=alexpasmantier/television extractVersion=^v?(?<version>.+)$
ARG TV_VERSION=0.15.9
# renovate: datasource=github-releases depName=astral-sh/uv extractVersion=^v?(?<version>.+)$
ARG UV_VERSION=0.12.7
# renovate: datasource=github-releases depName=starship/starship extractVersion=^v?(?<version>.+)$
ARG STARSHIP_VERSION=1.26.0

# NODE_MAJOR is intentionally unmanaged: major upgrades are a compatibility
# decision. UV_INSTALL_DIR is installation configuration, not a version pin.
ARG NODE_MAJOR=24
ARG UV_INSTALL_DIR=/usr/local/bin

LABEL org.opencontainers.image.source="https://github.com/evanharmon1/harmon-init" \
    org.opencontainers.image.revision="${IMAGE_REVISION}" \
    org.opencontainers.image.version="sha-${IMAGE_REVISION}" \
    org.opencontainers.image.description="Shared Harmon development and agent toolchain" \
    org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------- apt packages ----------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bat \
        btop \
        direnv \
        dnsutils \
        eza \
        fd-find \
        ffmpeg \
        file \
        fzf \
        git-crypt \
        git-delta \
        git-extras \
        git-lfs \
        gron \
        htop \
        imagemagick \
        jo \
        lynx \
        mc \
        micro \
        mkcert \
        nmap \
        ncdu \
        ncurses-bin \
        netcat-openbsd \
        pandoc \
        pv \
        ripgrep \
        sd \
        shellcheck \
        socat \
        strace \
        tealdeer \
        tmux \
        tree \
        unzip \
        vim \
        w3m \
        yamllint \
        zip \
        zoxide \
        zsh \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && chsh -s /usr/bin/zsh vscode

RUN if [ ! -f /usr/share/doc/fzf/examples/key-bindings.zsh ]; then \
        mkdir -p /usr/share/doc/fzf/examples \
        && apt-get update -qq \
        && apt-get download fzf \
        && dpkg-deb -x fzf_*.deb / \
        && rm -f fzf_*.deb \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# ---------- shell environment ----------
USER vscode
RUN if [ ! -d "$HOME/.oh-my-zsh" ]; then \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; \
    fi \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
RUN git clone --single-branch https://github.com/gpakosz/.tmux.git "$HOME/.tmux" \
    && ln -s -f "$HOME/.tmux/.tmux.conf" "$HOME/.tmux.conf"
# Build continues with system-wide installs; this is not the runtime-user decision.
# nosemgrep: dockerfile.security.last-user-is-root.last-user-is-root
USER root

# ---------- Node.js ----------
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        >/etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable pnpm \
    && rm -rf /var/lib/apt/lists/*
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# ---------- task runner ----------
RUN case "${TARGETARCH}" in \
        "amd64") export TASK_ARCH="amd64" ;; \
        "arm64") export TASK_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${TASK_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin task

# ---------- code-quality linters ----------
RUN case "${TARGETARCH}" in \
        "amd64") export SHFMT_ARCH="amd64" HADOLINT_ARCH="x86_64" ACTIONLINT_ARCH="amd64" ;; \
        "arm64") export SHFMT_ARCH="arm64" HADOLINT_ARCH="arm64" ACTIONLINT_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${SHFMT_ARCH}" \
        -o /usr/local/bin/shfmt \
    && chmod +x /usr/local/bin/shfmt \
    && curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${HADOLINT_ARCH}" \
        -o /usr/local/bin/hadolint \
    && chmod +x /usr/local/bin/hadolint \
    && curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${ACTIONLINT_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin actionlint

# ---------- lefthook + gitleaks ----------
RUN case "${TARGETARCH}" in \
        "amd64") export LEFTHOOK_ARCH="x86_64" GITLEAKS_ARCH="x64" ;; \
        "arm64") export LEFTHOOK_ARCH="arm64" GITLEAKS_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION}_Linux_${LEFTHOOK_ARCH}" \
        -o /usr/local/bin/lefthook \
    && chmod +x /usr/local/bin/lefthook \
    && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GITLEAKS_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin gitleaks

# ---------- infrastructure and secrets tools ----------
# Terraform and TFLint are standalone, cross-project IaC CLIs. Verify their
# upstream release metadata before installing them: HashiCorp signs the
# Terraform checksum catalog, and TFLint's reviewed per-architecture checksums
# are pinned alongside its Renovate-managed release version.
#
# Ansible intentionally stays in each project's uv environment, where its
# Python dependencies are project-owned. Checkov likewise remains an on-demand,
# explicitly pinned `uvx` tool rather than a shared-image dependency.
RUN case "${TARGETARCH}" in \
        "amd64") export TERRAFORM_ARCH="amd64" ;; \
        "arm64") export TERRAFORM_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && terraform_gnupg_home="$(mktemp -d)" \
    && export GNUPGHOME="${terraform_gnupg_home}" \
    && curl -fsSL https://keybase.io/hashicorp/pgp_keys.asc -o /tmp/hashicorp-pgp-keys.asc \
    && gpg --batch --import /tmp/hashicorp-pgp-keys.asc \
    && gpg --batch --with-colons --fingerprint 34365D9472D7468F \
        | awk -F: '$1 == "fpr" { print $10; exit }' \
        | grep -qx 'C874011F0AB405110D02105534365D9472D7468F' \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip" \
        -o "/tmp/terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip" \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
        -o "/tmp/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" \
        -o "/tmp/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" \
    && gpg --batch --status-fd 1 --verify "/tmp/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" \
        "/tmp/terraform_${TERRAFORM_VERSION}_SHA256SUMS" 2>/dev/null \
        | awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == "C874011F0AB405110D02105534365D9472D7468F" { valid = 1 } END { exit !valid }' \
    && cd /tmp \
    && grep " terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip$" \
        "terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
        | sha256sum --check - \
    && unzip -q "/tmp/terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip" -d /usr/local/bin \
    && rm -rf "$GNUPGHOME" /tmp/hashicorp-pgp-keys.asc \
        "/tmp/terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip" \
        "/tmp/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
        "/tmp/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig"

RUN case "${TARGETARCH}" in \
        "amd64") export TFLINT_ARCH="amd64" TFLINT_SHA256="${TFLINT_SHA256_AMD64}" ;; \
        "arm64") export TFLINT_ARCH="arm64" TFLINT_SHA256="${TFLINT_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${TFLINT_ARCH}.zip" \
        -o "/tmp/tflint_linux_${TFLINT_ARCH}.zip" \
    && echo "${TFLINT_SHA256}  /tmp/tflint_linux_${TFLINT_ARCH}.zip" | sha256sum --check - \
    && unzip -p "/tmp/tflint_linux_${TFLINT_ARCH}.zip" tflint >/usr/local/bin/tflint \
    && chmod 0755 /usr/local/bin/tflint \
    && rm -f "/tmp/tflint_linux_${TFLINT_ARCH}.zip"

RUN case "${TARGETARCH}" in \
        "amd64") export TFDOCS_ARCH="amd64" YQ_ARCH="amd64" SOPS_ARCH="amd64" ACT_ARCH="x86_64" ;; \
        "arm64") export TFDOCS_ARCH="arm64" YQ_ARCH="arm64" SOPS_ARCH="arm64" ACT_ARCH="arm64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TFDOCS_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin terraform-docs \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${YQ_ARCH}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq \
    && curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${SOPS_ARCH}" \
        -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops \
    && curl -fsSL "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_${ACT_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin act

# ---------- CLI utilities ----------
RUN case "${TARGETARCH}" in \
        "amd64") export GLOW_ARCH="x86_64" GUM_ARCH="x86_64" XH_ARCH="x86_64" FX_ARCH="amd64" \
            LAZYGIT_ARCH="x86_64" TOKEI_ARCH="x86_64" DIVE_ARCH="amd64" \
            GH_DASH_ARCH="amd64" WTF_ARCH="amd64" LYCHEE_ARCH="x86_64" TV_ARCH="x86_64" ;; \
        "arm64") export GLOW_ARCH="arm64" GUM_ARCH="arm64" XH_ARCH="aarch64" FX_ARCH="arm64" \
            LAZYGIT_ARCH="arm64" TOKEI_ARCH="aarch64" DIVE_ARCH="arm64" \
            GH_DASH_ARCH="arm64" WTF_ARCH="arm64" LYCHEE_ARCH="aarch64" TV_ARCH="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_${DIVE_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin dive \
    && curl -fsSL "https://github.com/antonmedv/fx/releases/download/${FX_VERSION}/fx_linux_${FX_ARCH}" -o /usr/local/bin/fx \
    && chmod +x /usr/local/bin/fx \
    && curl -fsSL "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "glow_${GLOW_VERSION}_Linux_${GLOW_ARCH}/glow" \
    && curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${LAZYGIT_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin lazygit \
    && curl -fsSL "https://github.com/XAMPPRocky/tokei/releases/download/v${TOKEI_VERSION}/tokei-${TOKEI_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz -C /usr/local/bin tokei \
    && curl -fsSL "https://github.com/ducaale/xh/releases/download/v${XH_VERSION}/xh-v${XH_VERSION}-${XH_ARCH}-unknown-linux-musl.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "xh-v${XH_VERSION}-${XH_ARCH}-unknown-linux-musl/xh" \
    && ln -sf /usr/local/bin/xh /usr/local/bin/xhs \
    && curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "gum_${GUM_VERSION}_Linux_${GUM_ARCH}/gum" \
    && curl -fsSL "https://github.com/dlvhdr/gh-dash/releases/download/v${GH_DASH_VERSION}/gh-dash_v${GH_DASH_VERSION}_linux-${GH_DASH_ARCH}" \
        -o /usr/local/bin/gh-dash \
    && chmod +x /usr/local/bin/gh-dash \
    && curl -fsSL "https://github.com/wtfutil/wtf/releases/download/v${WTF_VERSION}/wtf_${WTF_VERSION}_linux_${WTF_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin wtfutil \
    && if [ "${TARGETARCH}" = "amd64" ]; then \
        curl -fsSL "https://github.com/o2sh/onefetch/releases/download/${ONEFETCH_VERSION}/onefetch-linux.tar.gz" \
            | tar -xz -C /usr/local/bin; \
    fi \
    && curl -fsSL "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-${LYCHEE_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "lychee-${LYCHEE_ARCH}-unknown-linux-gnu/lychee" \
    && curl -fsSL "https://github.com/alexpasmantier/television/releases/download/${TV_VERSION}/tv-${TV_VERSION}-${TV_ARCH}-unknown-linux-gnu.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin "tv-${TV_VERSION}-${TV_ARCH}-unknown-linux-gnu/tv"

# ---------- terminal / workflow tools ----------
RUN case "${TARGETARCH}" in \
        "amd64") export ZELLIJ_ARCH="x86_64" WORKMUX_ARCH="amd64" AOE_ARCH="amd64" AGENT_DECK_ARCH="amd64" SESH_ARCH="x86_64" \
            HERDR_ARCH="x86_64" ;; \
        "arm64") export ZELLIJ_ARCH="aarch64" WORKMUX_ARCH="arm64" AOE_ARCH="arm64" AGENT_DECK_ARCH="arm64" SESH_ARCH="arm64" \
            HERDR_ARCH="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${ZELLIJ_ARCH}-unknown-linux-musl.tar.gz" \
        | tar -xz -C /usr/local/bin zellij \
    && curl -fsSL "https://github.com/raine/workmux/releases/download/v${WORKMUX_VERSION}/workmux-linux-${WORKMUX_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin workmux \
    && curl -fsSL "https://github.com/njbrake/agent-of-empires/releases/download/v${AOE_VERSION}/aoe-linux-${AOE_ARCH}.tar.gz" \
        | tar -xz -C /tmp "aoe-linux-${AOE_ARCH}" \
    && install -m 0755 "/tmp/aoe-linux-${AOE_ARCH}" /usr/local/bin/aoe \
    && rm -f "/tmp/aoe-linux-${AOE_ARCH}" \
    && curl -fsSL "https://github.com/asheshgoplani/agent-deck/releases/download/v${AGENT_DECK_VERSION}/agent-deck_${AGENT_DECK_VERSION}_linux_${AGENT_DECK_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin agent-deck \
    && curl -fsSL "https://github.com/joshmedeski/sesh/releases/download/v${SESH_VERSION}/sesh_Linux_${SESH_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin sesh \
    && curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${HERDR_ARCH}" \
        -o /usr/local/bin/herdr \
    && chmod +x /usr/local/bin/herdr

# Keep Herdr's default-session server socket out of ~/.config/herdr — that
# directory is volume-persisted across rebuilds and a stale socket must not
# ride along. (Herdr derives the client socket from this too:
# /tmp/herdr-client.sock. Named sessions ignore this override and keep their
# sockets under ~/.config/herdr/sessions/<name>/, where a stale one may
# persist — harmless but not covered.)
ENV HERDR_SOCKET_PATH=/tmp/herdr.sock

# ---------- Python and prompt tooling ----------
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR="${UV_INSTALL_DIR}" sh
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --version "v${STARSHIP_VERSION}"

# ---------- Node.js global packages ----------
# hadolint ignore=DL3016
RUN npm install -g \
        "@commitlint/cli" \
        "@commitlint/config-conventional" \
        "markdownlint-cli2" \
    && npm cache clean --force

# Antigravity ships native archives rather than an npm package. Verify Google's
# published per-platform SHA-512 before installing the binary system-wide.
RUN case "${TARGETARCH}" in \
        "amd64") \
            AGY_PLATFORM="linux-x64"; \
            AGY_ARCHIVE="cli_linux_x64"; \
            AGY_SHA512="32d64529cf035ab9790352069dd0df4525d7c920b42872de1775e65455e77fd983b37a6dee81a6345b060c98d5f350729bb5e2ae881bbda80f46b7487af4588d" ;; \
        "arm64") \
            AGY_PLATFORM="linux-arm"; \
            AGY_ARCHIVE="cli_linux_arm64"; \
            AGY_SHA512="fb1acacdbde606a60a8002b6dc0a8c9800bb84aef3add069f843f6ffa3efaafe4a52fce440505c6f16aebd6b1257cce5ecfaec2dbab21732c625943422318cdb" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && AGY_TARBALL="/tmp/${AGY_ARCHIVE}.tar.gz" \
    && curl -fsSL \
        "https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_CLI_VERSION}-${ANTIGRAVITY_CLI_BUILD}/${AGY_PLATFORM}/${AGY_ARCHIVE}.tar.gz" \
        -o "${AGY_TARBALL}" \
    && echo "${AGY_SHA512}  ${AGY_TARBALL}" | sha512sum --check - \
    && tar -xzf "${AGY_TARBALL}" -C /tmp antigravity \
    && install -m 0755 /tmp/antigravity /usr/local/bin/agy \
    && rm -f "${AGY_TARBALL}" /tmp/antigravity

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g \
        "@playwright/test@${PLAYWRIGHT_VERSION}" \
        "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}" \
    && npx playwright install --with-deps chromium \
    && (playwright-cli install --with-deps chromium 2>/dev/null || true) \
    && chmod -R o+rx "${PLAYWRIGHT_BROWSERS_PATH}" \
    && rm -rf /var/lib/apt/lists/* \
    && npm cache clean --force

RUN uv pip install --system --break-system-packages --no-cache toml aiogram
# `export` rather than a command-prefix assignment: a `VAR=x cmd1 && cmd2`
# prefix applies to cmd1 ONLY, so every tool after the first would silently
# install under root's ~/.local instead of the system paths — invisible to the
# `vscode` runtime user. Exporting covers the whole chain and keeps the next
# tool added here correct by default.
RUN export UV_TOOL_BIN_DIR=/usr/local/bin UV_TOOL_DIR=/opt/uv-tools \
    && uv tool install "semgrep==${SEMGREP_VERSION}" \
    && uv tool install "copier==${COPIER_VERSION}" \
    && rm -rf /root/.cache/uv

# Keep frequently updated agent CLIs in the final expensive-tool layer.
# GitHub Copilot CLI's npm package ships no platform binary itself: it
# declares per-platform packages (@github/copilot-linux-{x64,arm64}) as
# optionalDependencies, which npm resolves and downloads during `npm install`
# itself -- not via a postinstall script and not deferred to first run. The
# trailing `copilot --version` proves that resolution actually landed a
# runnable binary in this same layer, so a freshly created container never
# needs network access on its first invocation.
# hadolint ignore=DL3016
RUN npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@github/copilot@${COPILOT_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}" \
        "dmux@${DMUX_VERSION}" \
    && npm cache clean --force \
    && copilot --version

# pi installs in its own layer, isolated from the combined install above.
# --ignore-scripts is pure hardening for pi itself (its published package
# ships no install/postinstall lifecycle hook); keeping it separate avoids
# any interaction with Copilot's own npm-managed platform-binary resolution
# in the combined layer.
RUN npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" --ignore-scripts \
    && npm cache clean --force

# oh-my-pi ships prebuilt binaries with no npm package (its npm distribution
# is bun-only). Verify the downloaded binary against a per-architecture
# digest reviewed and pinned above -- not a SHA256SUMS.txt fetched from the
# same release at build time -- matching TFLint's pattern elsewhere in this
# file: the trust anchor is the reviewer, not the mutable release itself.
RUN case "${TARGETARCH}" in \
        "amd64") export OMP_ARCH="x64" OMP_SHA256="${OH_MY_PI_SHA256_AMD64}" ;; \
        "arm64") export OMP_ARCH="arm64" OMP_SHA256="${OH_MY_PI_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/can1357/oh-my-pi/releases/download/v${OH_MY_PI_VERSION}/omp-linux-${OMP_ARCH}" \
        -o "/tmp/omp-linux-${OMP_ARCH}" \
    && echo "${OMP_SHA256}  /tmp/omp-linux-${OMP_ARCH}" | sha256sum --check - \
    && install -m 0755 "/tmp/omp-linux-${OMP_ARCH}" /usr/local/bin/omp \
    && rm -f "/tmp/omp-linux-${OMP_ARCH}"

# Claude Code is installed globally as root above, but containers run as
# `vscode`, so its in-place auto-updater can never write to
# /usr/lib/node_modules/@anthropic-ai/claude-code and fails every attempt with
# `no_permissions` -- surfacing a warning in `claude doctor` that no consumer
# can act on. Self-update is also unwanted here: the version is pinned by
# CLAUDE_CODE_VERSION above (Renovate-managed) and rolled out by rebuilding
# this image and bumping the digest consumers pin, so a container that updated
# itself would silently drift off the tested, reviewed version. Disabling it
# makes `claude doctor` report an accurate "disabled by env" status instead.
# Set after the npm layer so toggling it does not bust that cache.
ENV DISABLE_AUTOUPDATER=1
# OpenCode is pinned and root-owned for the same reason. Its built-in updater
# must not replace the reviewed image version or attempt to write into the
# system-wide npm installation while the container runs as vscode.
ENV OPENCODE_DISABLE_AUTOUPDATE=true
# Antigravity 1.1.3+ automatically falls back to file-backed OAuth storage when
# no D-Bus keyring is available. ~/.gemini is a named volume in both profiles,
# so the pinned 1.1.11 build keeps an interactive login across rebuilds.
ENV AGY_CLI_DISABLE_AUTO_UPDATE=true
# Copilot CLI is pinned by COPILOT_VERSION above (Renovate-managed); its own
# auto-update would silently replace the reviewed image version. Auto-update
# defaults to disabled in CI environments already, but this holds regardless
# of how a build or run environment identifies itself.
ENV COPILOT_AUTO_UPDATE=false
# pi is pinned by PI_VERSION above, for the same reason.
ENV PI_SKIP_VERSION_CHECK=1

# ---------- image/overlay contract ----------
COPY generate-manifest.sh smoke.sh /usr/local/sbin/
COPY install-repo-config.sh /usr/local/sbin/install-harmon-repo-config
RUN chmod 0755 \
        /usr/local/sbin/generate-manifest.sh \
        /usr/local/sbin/install-harmon-repo-config \
        /usr/local/sbin/smoke.sh \
    && /usr/local/sbin/generate-manifest.sh "${IMAGE_REVISION}" "${TARGETARCH}" \
        "task=${TASK_VERSION}" \
        "shfmt=${SHFMT_VERSION}" \
        "hadolint=${HADOLINT_VERSION}" \
        "actionlint=${ACTIONLINT_VERSION}" \
        "terraform-docs=${TERRAFORM_DOCS_VERSION}" \
        "terraform=${TERRAFORM_VERSION}" \
        "tflint=${TFLINT_VERSION}" \
        "yq=${YQ_VERSION}" \
        "zellij=${ZELLIJ_VERSION}" \
        "workmux=${WORKMUX_VERSION}" \
        "aoe=${AOE_VERSION}" \
        "claude-code=${CLAUDE_CODE_VERSION}" \
        "codex=${CODEX_VERSION}" \
        "copilot=${COPILOT_VERSION}" \
        "pi=${PI_VERSION}" \
        "omp=${OH_MY_PI_VERSION}" \
        "opencode=${OPENCODE_VERSION}" \
        "antigravity-cli=${ANTIGRAVITY_CLI_VERSION}" \
        "agent-deck=${AGENT_DECK_VERSION}" \
        "sesh=${SESH_VERSION}" \
        "herdr=${HERDR_VERSION}" \
        "dmux=${DMUX_VERSION}" \
        "semgrep=${SEMGREP_VERSION}" \
        "copier=${COPIER_VERSION}" \
        "playwright=${PLAYWRIGHT_VERSION}" \
        "playwright-cli=${PLAYWRIGHT_CLI_VERSION}" \
        "sops=${SOPS_VERSION}" \
        "act=${ACT_VERSION}" \
        "lefthook=${LEFTHOOK_VERSION}" \
        "gitleaks=${GITLEAKS_VERSION}" \
        "uv=${UV_VERSION}" \
        "starship=${STARSHIP_VERSION}"

# Extension contract: downstream Dockerfiles run the overlay installer as root
# and explicitly return to USER vscode after repository policy is installed.
# nosemgrep: dockerfile.security.last-user-is-root.last-user-is-root
USER root
