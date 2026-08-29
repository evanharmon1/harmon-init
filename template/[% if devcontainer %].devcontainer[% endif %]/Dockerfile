FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-79ad7fb3879d7eeb086b7fdac1350be0b7d91773@sha256:50bfe5d555a64006bac473c26338dfaad5a6c996c7a0e11cc9c839ca5bc99b4a

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
