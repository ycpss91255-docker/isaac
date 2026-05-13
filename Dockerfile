# Dockerfile.example - Template for new Docker container repos
#
# Copy this file to your repo root as "Dockerfile" and customize.
# The test-tools image (ShellCheck, Hadolint, Bats) is consumed via the
# TEST_TOOLS_IMAGE build arg. Default `test-tools:local` works for the
# local `./build.sh` flow (builds Dockerfile.test-tools into the host
# Docker daemon). CI overrides this to
# `ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z` so buildx can pull the
# arch-correct pre-built image without the cross-step image-store
# isolation that broke the old test-tools:local CI pattern.
#
# Stages:
#   sys        - User/group, locale, timezone
#   devel-base - Development tools and packages (renamed from `base` in
#                base repo v0.21.0 for symmetry with runtime-base)
#   devel      - Application-specific tools + entrypoint
#   devel-test - Lint + smoke test (ephemeral, discarded after build;
#                renamed from `test` in base repo v0.21.0 for symmetry
#                with runtime-test)
#   runtime    - Minimal runtime image (optional)

ARG BASE_IMAGE="nvcr.io/nvidia/isaac-sim:5.1.0"
ARG TEST_TOOLS_IMAGE="test-tools:local"

############################## sys ##############################
FROM ${BASE_IMAGE} AS sys

ARG USER_NAME="user"
ARG USER_GID=1000
ARG USER_UID=1000
ARG USER_GROUP="user"
ARG TZ="Asia/Taipei"
ARG APT_MIRROR_UBUNTU="tw.archive.ubuntu.com"
ARG DEBIAN_FRONTEND=noninteractive

# Some base images (e.g. nvcr.io/nvidia/isaac-sim:5.1.0) ship with a
# non-root default user; switch to root so the system-setup steps below
# (apt, locale-gen, useradd) have permission. Devel stage drops back to
# USER_NAME at the end. DL3002 false-positive is acknowledged upstream
# (hadolint/hadolint#405): inline ignores are the recommended workaround.
# hadolint ignore=DL3002
USER root

SHELL ["/bin/bash", "-x", "-euo", "pipefail", "-c"]

RUN sed -i "s@archive.ubuntu.com@${APT_MIRROR_UBUNTU}@g" /etc/apt/sources.list || true; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        tzdata \
        locales \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG="en_US.UTF-8" && \
    ln -snf /usr/share/zoneinfo/"${TZ}" /etc/localtime && echo "${TZ}" > /etc/timezone

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV TZ="${TZ}"

# Create user (handle UID/GID conflicts)
RUN if getent group "${USER_GID}" >/dev/null; then \
        groupmod -n "${USER_GROUP}" "$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${USER_GID}" "${USER_GROUP}"; \
    fi && \
    if getent passwd "${USER_UID}" >/dev/null; then \
        usermod -l "${USER_NAME}" -d "/home/${USER_NAME}" -m \
            "$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
    else \
        useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"; \
    fi && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    if getent group isaac-sim >/dev/null; then \
        usermod -aG isaac-sim "${USER_NAME}"; \
    fi

############################## devel-base ##############################
FROM sys AS devel-base

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sudo \
        git \
        vim \
        tmux \
        terminator \
        curl \
        wget \
        python3 \
        python3-pip \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## devel ##############################
FROM devel-base AS devel

ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
# <repo>/config is a per-repo copy of .base/config seeded by
# init.sh. Edit files there freely; base upgrades do not touch
# this directory (upgrade.sh prints a diff hint when upstream moves).
ARG CONFIG_SRC="config"

# Add your application-specific packages here
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         your-package \
#         && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"

# Fast DDS profile (UDPv4-only, no built-in transports). Per Isaac Sim
# 5.1 official ROS 2 install guide, this is required for cross-container
# DDS to work reliably on a shared host (--net=host). Pointed to by
# FASTRTPS_DEFAULT_PROFILES_FILE in setup.conf [environment].
COPY --chmod=0644 config/ros2/fastdds.xml /isaac-sim/fastdds.xml

# ROS distro is a build-time choice — set via setup.conf [build]
# arg_N=ROS_DISTRO=<value> (default humble). Bake the value into a
# const file consumed by the headless / gui ENTRYPOINT shim, so
# runtime `-e ROS_DISTRO=...` flags are ignored. Rebuild (./build.sh)
# to switch distros.
ARG ROS_DISTRO=humble
RUN mkdir -p /etc/isaac && echo "${ROS_DISTRO}" > /etc/isaac/ros-distro

# Soft bake for devel stage (interactive shell). headless / gui stages
# additionally run the wrapper shim below — that re-exports from
# /etc/isaac/ros-distro at every container start, hard-baking against
# runtime override.
ENV ROS_DISTRO=${ROS_DISTRO} \
    LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib

COPY --chmod=0755 script/isaac-ros-env-wrapper.sh /usr/local/bin/isaac-ros-env-wrapper.sh

USER "${USER}"

# Setup pip packages
RUN "${CONFIG_DIR}"/pip/setup.sh

# Setup shell, terminator, tmux
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}"

WORKDIR "${HOME}/work"

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

############################## devel-test ##############################
# Resolves to test-tools:local (local build.sh) or ghcr.io/.../test-tools:vX.Y.Z (CI).
FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage

FROM devel AS devel-test

USER root

# Lint tools (from pre-built test-tools image; see TEST_TOOLS_IMAGE at top)
COPY --from=test-tools-stage /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=test-tools-stage /usr/local/bin/hadolint /usr/local/bin/hadolint

# Lint: ShellCheck (.sh) + Hadolint (Dockerfile)
COPY .hadolint.yaml /lint/.hadolint.yaml
COPY Dockerfile /lint/Dockerfile
COPY *.sh /lint/
# Repo-side helpers (init_isaac_dirs.sh, isaac-ros-env-wrapper.sh, etc).
# Lint together with root-level wrappers so any new shim added to
# script/ is enforced from day one.
COPY script/*.sh /lint/script/
# Helpers sourced by the root-level scripts. Must sit next to them so
# build.sh / run.sh / exec.sh / stop.sh / setup.sh can source _lib.sh
# (which in turn sources i18n.sh); setup.sh also sources _tui_conf.sh.
# Issue #104: removing these used to be compensated by inline
# `_detect_lang` fallbacks in every script — now the canonical
# definition lives once in i18n.sh.
COPY .base/script/docker/_lib.sh \
     .base/script/docker/i18n.sh \
     .base/script/docker/_tui_conf.sh \
     /lint/
# v0.28.0 PR #306 split _lib.sh into focused sub-libs under
# .base/script/docker/lib/; mirror that layout under /lint/lib/ so the
# /lint/-stage _lib.sh sources its sub-libs identically to the normal
# .base/ layout. Without this the smoke stage's `bash /lint/build.sh -h`
# fails with `/lint/lib/log.sh: No such file or directory`.
COPY .base/script/docker/lib /lint/lib
RUN shellcheck -S warning /lint/*.sh /lint/script/*.sh /lint/lib/*.sh
RUN cd /lint && hadolint Dockerfile

# Bats (from pre-built test-tools image; see TEST_TOOLS_IMAGE at top)
COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Smoke test (shared from base + repo-specific)
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/

ARG USER
USER "${USER}"

RUN bats /smoke_test/

############################## headless ##############################
# Auto-emitted as compose service by setup.sh (template v0.17 #215).
# `./run.sh -t headless -d` 直接拉起 Isaac Sim WebRTC streaming server，
# 不需要 docker exec /isaac-sim/runheadless.sh。
#
# ENTRYPOINT goes through isaac-ros-env-wrapper.sh which re-exports
# ROS_DISTRO + LD_LIBRARY_PATH from /etc/isaac/ros-distro (baked at
# build time from ARG ROS_DISTRO). This makes runtime
# `-e ROS_DISTRO=...` flags ineffective — distro is build-time only.
FROM devel AS headless

ENTRYPOINT ["/usr/local/bin/isaac-ros-env-wrapper.sh", "/isaac-sim/runheadless.sh"]
CMD ["-v"]

############################## gui ##############################
# 本機 GUI（X11 forward）— 需要 host 端 `xhost +local:docker` 已開
# (template run.sh 自動處理) 與 DISPLAY env (template 也自動帶入)。
# `./run.sh -t gui -d` 直接拉起 Isaac Sim 視窗版本。
#
# Same wrapper as headless — re-exports ROS env from baked file.
FROM devel AS gui

ENTRYPOINT ["/usr/local/bin/isaac-ros-env-wrapper.sh", "/isaac-sim/runapp.sh"]
CMD []

############################## runtime (optional) ##############################
# FROM sys AS runtime-base
#
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         sudo \
#         tini \
#         && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*
#
# FROM runtime-base AS runtime
#
# ARG USER="${USER_NAME}"
# COPY --chmod=0755 script/entrypoint.sh /entrypoint.sh
# USER "${USER}"
# WORKDIR "${HOME}/work"
# ENTRYPOINT ["/entrypoint.sh"]
# CMD ["bash"]
