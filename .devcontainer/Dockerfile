FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-8100424ef1c175d1f97dc6ce8e15614fde4cc44d@sha256:b8a305693e996ac5289bf6f18ae47dd75d9d04ed1763499ef03f52949ea5b519

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
