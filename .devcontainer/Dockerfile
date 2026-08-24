FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-8d4db88487df37a2c91c8d31887bcf18f70b875a@sha256:8152426543e5a0ef255493b008a81fb8e7c86639ccbb96e2eb5ab231c607ef8e

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
