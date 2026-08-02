FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-fc09257f2e9e6cfd78c0b949d19c9a9fbdb7568f@sha256:7194091c1bc33e7094cfd6f41cc72a068ef0f3ef1b0fcfa4c09489648fc709f8

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
