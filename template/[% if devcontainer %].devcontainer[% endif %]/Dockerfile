FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-e0f52ee23fa668e66921bd125509733ea2205c2f@sha256:03e8b4c3cc6714145aa18162a80e42fc6b81aa36f31ebb210bd1aaffe9141eae

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
