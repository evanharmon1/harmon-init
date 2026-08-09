FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-6c71438a339fe842b97bcab95ac9addd04d3eef5@sha256:4c883e9a87b4ef1484675913c752615656cb5454f3853597f279987935eb6c3e

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
