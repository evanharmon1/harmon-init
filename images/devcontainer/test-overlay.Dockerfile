ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config
USER vscode
