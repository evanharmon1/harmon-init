FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-e09f420b36b8113bc3e3d7f5d567a0985c1d0bea@sha256:1c72300876889169724a8fe4bff012ad522b8e9eea15cf074437f4102498f79a

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
