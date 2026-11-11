FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-8be3fd9df1b0f94db1b71ec4073a16f7deafadd4@sha256:e4b77c9832e8037338e2c786d815d76fdc0464cea970e7dae16cdaa6630728b0

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
COPY .devcontainer/Dockerfile /tmp/harmon-image-inputs/Dockerfile
COPY .devcontainer/devcontainer.json /tmp/harmon-image-inputs/devcontainer.json
COPY .devcontainer/agent/devcontainer.json /tmp/harmon-image-inputs/agent/devcontainer.json
COPY .devcontainer/dev/devcontainer.json /tmp/harmon-image-inputs/dev/devcontainer.json
RUN mkdir -p /etc/harmon-devcontainer \
    && (cd /tmp/harmon-image-inputs && sha256sum Dockerfile devcontainer.json agent/devcontainer.json dev/devcontainer.json) \
        > /etc/harmon-devcontainer/image-inputs.sha256 \
    && rm -rf /tmp/harmon-image-inputs
RUN /usr/local/sbin/install-harmon-repo-config

# Prepend ~/.local/bin onto PATH for every process the container ever runs —
# baked into the image, not devcontainer.json's containerEnv: that layer's
# ${containerEnv:PATH} cannot self-expand while Docker is creating the
# container (it is passed to `docker run -e` literally, unresolved, which
# breaks the container's own shell). A Dockerfile ENV directive is Docker's
# own, working self-reference and applies identically to any docker exec,
# not only an interactive login shell — the antigravity bot-autonomy
# wrapper's precedence over the system agy binary depends on this.
ENV PATH="/home/vscode/.local/bin:${PATH}"

USER vscode
