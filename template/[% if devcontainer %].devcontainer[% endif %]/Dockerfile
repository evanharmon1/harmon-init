FROM ghcr.io/evanharmon1/harmon-devcontainer:sha-c490a391b3be21a32f48e32c1ffce0aab4dbcb66@sha256:179433a88e470f14b33cde69b2e17ff555f560aedccc0999bd0260ad62d5e79f

USER root

# Add genuinely repository-specific native packages here. Shared tools belong
# in the canonical harmon-init image, not in generated repository Dockerfiles.

COPY .devcontainer/config/ /usr/local/share/devcontainer-config/
RUN /usr/local/sbin/install-harmon-repo-config

USER vscode
