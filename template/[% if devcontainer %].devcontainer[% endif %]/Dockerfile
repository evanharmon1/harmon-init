FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-df47298d393decd21192f521d96ade4e1eba2556@sha256:0a8a4087d7587785aa4c736eac3c89ca61d394100ea56c481713c588e53ae479

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
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
