# Dockerfile - Isaac Sim 5.1.0 dev container (rebased onto base v0.28.0
# Dockerfile.example baseline; isaac-specific additions layered on top).
#
# Upstream baseline: .base/dockerfile/Dockerfile.example (subtree pinned
# to base v0.28.0). The structure / order / comment blocks follow the
# baseline so a future `.base/upgrade.sh` diff is easy to read. The
# isaac-specific insertions are flagged inline.
#
# Stages:
#   sys           - User/group, locale, timezone (+ isaac-sim group join)
#   devel-base    - Development tools and packages
#   builder       - Compile/build stage (optional; opt-in for runtime split, keeps source)
#   devel         - Application-specific tools + entrypoint
#                   (+ fastdds.xml, ROS_DISTRO bake, env-wrapper shim)
#   devel-test    - Lint + bats smoke test (ephemeral, discarded after build)
#   headless      - Isaac Sim, no streaming (ISAAC_LIVESTREAM=0; pure inference / batch)
#   stream        - Isaac Sim + WebRTC streaming (ISAAC_LIVESTREAM=2; devel observation)
#   runtime-base  - Minimal runtime base (sudo + tini + ldd-driven libs), optional
#   runtime       - Minimal runtime image (COPY --from=builder install trees), optional
#   runtime-test  - Runtime install-check smoke (ephemeral, optional)
#
# Adding extra stages (base #215): any `FROM <base> AS <stage>` outside
# the baseline blocklist {sys, devel-base, devel, devel-test, runtime-test}
# is auto-emitted as a compose service that extends `devel` (inherits
# volumes / network / GPU / GUI / cap_add / additional_contexts) and
# overrides only build.target / image / container_name / stdin_open /
# tty / profiles. Stage names must match `^[a-z][a-z0-9_-]*$` and must
# not collide with `latest` / `v[0-9]*` (reserved release tag
# namespace). `headless` / `stream` below are the two repo-side entrypoint
# variants emitted via this mechanism. No setup.conf change needed; run
# any wrapper to regenerate compose.yaml, then `./run.sh -t <stage>`.
#
# Backward-compat: the legacy stage names `base` and `test` are still
# accepted by the blocklist during the v0.21.x transition (renamed to
# `devel-base` / `devel-test` here). They will be removed from the
# blocklist in a future major.

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

# [isaac] Isaac Sim 5.1.0 base image ships with a non-root default user
# (isaac-sim, UID 1234); switch to root so the system-setup steps below
# (apt, locale-gen, useradd) have permission. devel stage drops back to
# USER_NAME at the end. DL3002 false-positive is acknowledged upstream
# (hadolint/hadolint#405); inline ignore is the recommended workaround.
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

# Create user (handle UID/GID conflicts).
# [isaac] Also join the isaac-sim group (present in Isaac Sim base image)
# so the container user can read /isaac-sim/* which is mode 0750.
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
# Layered config/ override (base #254): two sequential COPYs into
# /tmp/config/. The first brings .base/config/ defaults; the second
# overlays <repo>/config/ on top. File-level merge — files in
# <repo>/config/ replace same-path files in /tmp/config/; files only in
# .base/config/ stay; files only in <repo>/config/ are added. Mental
# model is the same as setup.conf section-replace, just at file
# granularity. Trim <repo>/config/ files that match base default to
# start receiving template-side improvements (we did this in the
# rebase: only docker/setup.conf, shell/bashrc, ros2/fastdds.xml
# remain in <repo>/config/).
ARG CONFIG_SRC="config"

# [isaac #149 / ADR-0018] Isaac Lab as a baked base tool (alongside Isaac
# Sim). It is the scene-spawn backend: sim_utils spawners (build_scene),
# the UrdfConverter (model_import), and AppLauncher + SimulationContext
# (driver). Installed against the bundled Isaac Sim binary via the
# documented _isaac_sim symlink, into /isaac-sim's Python, so every stage
# deriving from devel (headless / stream / devel-test) has it. Pinned to a
# 2.3 tag (built on Isaac Sim 5.1, Python 3.11 -- NVIDIA's recommended
# pairing). Kept early in devel so day-to-day config / app COPY changes
# below do not invalidate this large layer. The framework (isaac_devkit)
# stays mounted, not baked (ADR-0017 section 2: base tools baked + pinned,
# framework mounted).
#
# RL learning frameworks (rl_games / rsl_rl / sb3 / skrl / robomimic) are
# NOT installed yet (`--install none` below): the current product is
# single-scene + ROS 2 service, no reinforcement learning. They are
# DEFERRED, not excluded -- parallel-environment / RL-style work is planned
# later (the "C" / InteractiveScene direction in ADR-0018). When that
# lands, replace the `--install none` line with the full install (the
# cmake / build-essential that robomimic needs are already apt-installed
# below):
#
#     /opt/IsaacLab/isaaclab.sh --install all && \
#
# or install only the frameworks you need, e.g.:
#
#     /opt/IsaacLab/isaaclab.sh --install rl_games rsl_rl sb3 skrl && \
#
ARG ISAACLAB_VERSION="v2.3.2"
RUN apt-get update && \
    apt-get install -y --no-install-recommends git cmake build-essential && \
    git clone --depth 1 --branch "${ISAACLAB_VERSION}" \
        https://github.com/isaac-sim/IsaacLab.git /opt/IsaacLab && \
    ln -s /isaac-sim /opt/IsaacLab/_isaac_sim && \
    /opt/IsaacLab/isaaclab.sh --install none && \
    /isaac-sim/python.sh -m pip show isaaclab && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Add your application-specific packages here
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         your-package \
#         && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
# Layer 1: .base/config/ defaults (subtree-managed, updates with
# .base/upgrade.sh).
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"
# Layer 2: <repo>/config/ overrides (per-repo, survives subtree pull).
# Files here overlay matching paths from layer 1.
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"
# [isaac] Fast DDS profile (UDPv4-only, no built-in transports). Per
# Isaac Sim 5.1 official ROS 2 install guide, required for cross-container
# DDS to work reliably on a shared host (--net=host). Pointed to by
# FASTRTPS_DEFAULT_PROFILES_FILE in setup.conf [environment]. Lands
# directly at /isaac-sim/ (not via CONFIG_DIR) because the runtime path
# is what the env var references — no override mechanism needed.
COPY --chmod=0644 config/ros2/fastdds.xml /isaac-sim/fastdds.xml

# [isaac] Custom kit experience files. Layered into /isaac-sim/apps/
# next to NVIDIA's bundled experiences (isaacsim.exp.base.python.kit,
# isaacsim.exp.full.streaming.kit, ...). SimulationApp drivers can opt
# in via experience="/isaac-sim/apps/<name>.kit".
#
# Current entries:
#   isaacsim.exp.base.python.streaming.kit
#       Closes #21 fix-B: the lightweight Python experience layered with
#       omni.kit.livestream.{core,webrtc} so SimulationApp + livestream:2
#       actually serves a WebRTC stream. Avoids the full.streaming.kit
#       segfault that hits when that experience is loaded via
#       SimulationApp instead of the kit binary directly.
COPY --chmod=0644 apps/*.kit /isaac-sim/apps/

# [isaac] ROS distro is a build-time choice — set via
# setup.conf [build] arg_N=ROS_DISTRO=<value> (default humble). Bake
# the value into a const file consumed by the headless / stream ENTRYPOINT
# shim, so runtime `-e ROS_DISTRO=...` flags are ignored. Rebuild
# (./build.sh) to switch distros.
ARG ROS_DISTRO=humble
RUN mkdir -p /etc/isaac && echo "${ROS_DISTRO}" > /etc/isaac/ros-distro

# [isaac] Soft bake for devel stage (interactive shell). headless / stream
# stages additionally run the wrapper shim below — that re-exports from
# /etc/isaac/ros-distro at every container start, hard-baking against
# runtime override.
ENV ROS_DISTRO=${ROS_DISTRO} \
    LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib

# [isaac] ENTRYPOINT shim for headless / stream stages: re-reads
# /etc/isaac/ros-distro and unconditionally exports ROS_DISTRO +
# LD_LIBRARY_PATH before exec'ing the wrapped binary. Lives in /usr/local/bin/
# so the headless / stream stages can name it absolutely in ENTRYPOINT.
COPY --chmod=0755 script/isaac-ros-env-wrapper.sh /usr/local/bin/isaac-ros-env-wrapper.sh

# [isaac] runheadless wrapper that reads per-host config from
# /etc/host.yaml (mounted from <repo>/config/host.yaml by caller).
# Used by Makefile.local run-stream + run_instance.sh to inject
# --/app/livestream/publicEndpointAddress without host-side YAML
# parsing. See doc/ for the host.yaml schema.
COPY --chmod=0755 script/runheadless-host-config.sh /usr/local/bin/runheadless-host-config.sh
# Shared host.yaml parser sourced by the wrapper above (and by host-side
# run_instance.sh from the repo tree) -- single source of truth (#104).
COPY --chmod=0755 script/host_yaml.sh /usr/local/lib/host_yaml.sh

USER "${USER}"

# [isaac] HOME is implicit on Linux but Docker's WORKDIR directive
# interpolates only build-time ARG / ENV (not shell-set HOME). Without
# this explicit ENV the `WORKDIR "${HOME}/work"` below silently resolves
# to `/work` and emits a BuildKit `UndefinedVar` warning. Setting HOME
# explicitly silences the warning and makes the WORKDIR intent — and
# non-interactive `docker exec` cwd — match the interactive shell.
ENV HOME="/home/${USER_NAME}"

# Setup shell, terminator, tmux. The bashrc append picks up the
# bashrc.d bootstrap loop (base #254) which sources any *.sh
# drop-ins under ~/.bashrc.d/ at interactive shell start.
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}"

# [isaac #127] Bake ~/.cache and ~/.nv user-owned into the image. The
# compose volumes mount subpaths (~/.cache/ov, ~/.cache/pip,
# ~/.cache/nvidia/GLCache, ~/.nv/ComputeCache); when the parent dir is
# absent from the image, dockerd mkdirs it as root at mount time, and
# anything else that writes under ~/.cache then fails -- concretely
# warp's '~/.cache/warp' PermissionError kills omni.replicator.core at
# extension startup, which unregisters the SDG node templates
# (DispatchSync etc.) the ROS2 camera publish chain needs: graph builds,
# zero frames published.
RUN mkdir -p "${HOME}/.cache" "${HOME}/.nv" && \
    chown "${USER}":"${GROUP}" "${HOME}/.cache" "${HOME}/.nv"

# (Optional) Repo-local Dockerfile-internal build helpers. Put any
# shell helpers that should run during `docker build` under
# <repo>/script/docker/<name>.sh, then COPY them into a build-time
# scratch location and RUN them. Cleanup keeps the final image lean.
# Runtime helpers (entrypoint, ros bringup, ...) stay under
# <repo>/script/ as before; the two classes are deliberately split.
#
# Example (uncomment and adapt):
#COPY --chmod=0755 script/docker/build_helper.sh /tmp/build_helper.sh
#RUN /tmp/build_helper.sh && rm /tmp/build_helper.sh

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
# [isaac] Post-v0.31.0 wrappers live under script/. Two COPYs:
# - /lint/       flat: upstream smoke tests expect /lint/build.sh
# - /lint/script/: isaac tests expect /lint/script/init_isaac_dirs.sh
COPY script/*.sh /lint/
COPY script/*.sh /lint/script/
# Helpers sourced by the root-level scripts. Must sit next to them so
# build.sh / run.sh / exec.sh / stop.sh / setup.sh can source _lib.sh
# (which in turn sources i18n.sh); setup.sh also sources _tui_conf.sh.
# Issue base#104: removing these used to be compensated by inline
# `_detect_lang` fallbacks in every script — now the canonical
# definition lives once in i18n.sh.
# Post-base#406 (v0.39.0+): wrapper scripts moved to script/docker/wrapper/
# and all libs consolidated under script/docker/lib/. _lib.sh, i18n.sh,
# _tui_conf.sh are now under lib/. Preserve the lib/ subdirectory in
# /lint/ so the source paths inside _lib.sh resolve identically to the
# normal .base/ layout. The `COPY .base/script/docker/lib /lint/lib`
# below brings ALL of these in one shot.
COPY .base/script/docker/lib /lint/lib
# Lint coverage for repo-local Dockerfile-internal build helpers
# (base #275). Uncomment if your repo has any <repo>/script/docker/*.sh
# build helpers (see the commented example in the devel stage above);
# the COPY brings them into /lint/ so ShellCheck catches issues at
# build time.
#COPY script/docker/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
# [base #440] Repo-local run/stop hooks live under script/hooks/{pre,post}/
# (nested, so the flat /lint/*.sh glob above misses them). Lint them here.
COPY script/hooks /lint/hooks
RUN shellcheck -S warning /lint/hooks/pre/*.sh /lint/hooks/post/*.sh
RUN cd /lint && hadolint Dockerfile

# [isaac] Python testing toolkit (pytest + common deps). Installed into
# Isaac Sim's bundled Python (/isaac-sim/python.sh) because PEP 668
# blocks the system python's pip. Stage-scoped to devel-test only,
# keeping the runtime devel image lean — devel-test is the only stage
# that pays the ~30-50MB cost. Closes #59.
RUN /isaac-sim/python.sh -m pip install --no-cache-dir \
        pytest pyyaml pytest-cov && \
    /isaac-sim/python.sh -m pytest --version

# Bats (from pre-built test-tools image; see TEST_TOOLS_IMAGE at top)
COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Smoke test (shared from base + repo-specific). Repo-local .bats
# files live under test/smoke/bats/ per isaac#64 (separating tool
# layers under test/<category>/<tool>/), so future Python smoke tests
# under test/smoke/pytest/ do not collide with bats discovery.
COPY .base/test/smoke/ /smoke_test/
COPY test/smoke/bats/ /smoke_test/
# [#104] Shared host.yaml parser, baked next to host_yaml_spec.bats.
COPY script/host_yaml.sh /smoke_test/host_yaml.sh
# [base #465/#440] Scripts under test by the migrated specs: the
# livestream wrapper + the per-instance run/stop hooks. Both hooks are
# named run.sh / stop.sh inside their pre/post dirs, so they are baked
# under distinct flat names that match the *_spec.bats files.
COPY --chmod=0755 script/runheadless-host-config.sh /smoke_test/runheadless-host-config.sh
COPY --chmod=0755 script/hooks/pre/run.sh /smoke_test/pre_run_hook.sh
COPY --chmod=0755 script/hooks/post/run.sh /smoke_test/post_run_hook.sh
COPY --chmod=0755 script/hooks/post/stop.sh /smoke_test/post_stop_hook.sh

ARG USER
USER "${USER}"

RUN bats /smoke_test/

# [isaac #127] Idle on startup so the `test` compose service survives
# `compose up -d` and `./script/run.sh -t test -- <cmd>` (up -d + exec)
# can run GPU pytest inside it. The inherited devel CMD ["bash"] exits
# immediately because the emitted test service sets stdin_open/tty to
# false ("container is not running", PR #84). Same idle pattern as the
# headless / stream stages below.
CMD ["sleep", "infinity"]

############################## headless ##############################
# [isaac] Pure simulation, no streaming. Idles on startup; driver
# scripts are exec'd in and read ISAAC_LIVESTREAM=0 to skip streaming.
#
# Usage:
#   make run -- -t headless -d
#   make exec -- -t headless /isaac-sim/python.sh <driver.py>
#
# Follows the Gazebo gzserver/gzclient separation model: one
# container = one Kit process at a time. The driver script is the
# single Kit owner; no dual-Kit port conflict.
FROM devel AS headless

ENV ISAAC_LIVESTREAM=0
CMD ["sleep", "infinity"]

############################## stream ##############################
# [isaac] Simulation + WebRTC streaming server. Same idle pattern as
# headless; driver scripts read ISAAC_LIVESTREAM=2 to enable streaming.
#
# Usage:
#   make run -- -t stream -d
#   make exec -- -t stream /isaac-sim/python.sh <driver.py>
#   # -> browser connects via web-viewer at :5173
#
# For one-off headless streaming without a driver script:
#   make exec -- -t stream /isaac-sim/runheadless.sh -v \
#     --/app/livestream/nvcf/quitOnSessionEnded=false
FROM devel AS stream

ENV ISAAC_LIVESTREAM=2
CMD ["sleep", "infinity"]

############################## builder + runtime split (optional) ##############################
# Three concrete stages for repos that need a separate runtime image
# (compiled binaries / generated artifacts to ship without dev deps).
# Lessons lifted from ycpss91255-docker/ros1_bridge#60 PR — empirically
# saved ~1.1 GB/arch on that repo's runtime image.
#
# Three rules, all of which the previous commented-out hint was silent on:
#
# 1. `runtime` MUST NOT be `FROM devel`. Pre-#60 ros1_bridge had
#    `FROM devel AS runtime` which forced devel to delete its source
#    trees in the same RUN that built them (otherwise runtime carried
#    the bloat). Result: devel was unusable for the standard
#    "edit source, rebuild, retest" workflow. The fix is the
#    conventional split: builder keeps source, devel inherits builder,
#    runtime starts from a fresh base and only `COPY --from=builder`
#    the install trees.
#
# 2. Runtime apt: install only the libs `ldd` proves are missing.
#    Don't bulk-install builder deps "to be safe" — that defeats the
#    point. Identify the gap empirically:
#      docker run --rm -it <builder-image> bash
#      ldd /opt/<framework>/lib/*.so | grep "not found"
#      dpkg -S <missing.so>     # map back to apt package name
#
# 3. `source FILE` in entrypoints needs a trailing `--`. Bash's
#    `source FILE` (without explicit args) propagates the calling
#    script's positional parameters to the sourced file. Frameworks
#    that re-forward them (ROS 1's catkin/_setup_util.py is the
#    canonical case) then see CMD's `--flag` as their own argparse
#    input, print usage to stdout, and the wrapper sources that usage
#    as shell — container dies with exit 127. Pass `--` explicitly.
#
# To enable: uncomment the three blocks below, change `devel` above
# from `FROM devel-base AS devel` to `FROM builder AS devel` so devel
# inherits builder's build artifacts (without re-installing build
# deps), and set `build_runtime: true` in main.yaml's
# call-docker-build job. Isaac Sim 5.1 dev images are not currently a
# runtime-split candidate (the 15 GB Isaac base is the dominant size
# anyway), so these stays commented.

############################## builder (optional) ##############################
# FROM devel-base AS builder
#
# ARG DEBIAN_FRONTEND=noninteractive
#
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         build-essential \
#         cmake \
#         pkg-config \
#         python3-dev \
#         && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*
#
# WORKDIR /build_ws
# COPY src/ /build_ws/src/
# RUN apt-get update && \
#     rosdep install --from-paths ./src --ignore-src -y && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*
# RUN colcon build --install-base /build_ws/install

############################## runtime-base + runtime (optional) ##############################
# FROM ${BASE_IMAGE} AS runtime-base
#
# ARG DEBIAN_FRONTEND=noninteractive
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
# ARG GROUP="${USER_GROUP}"
#
# COPY --from=builder /build_ws/install /opt/app/install
# COPY --chmod=0755 script/entrypoint.sh /entrypoint.sh
# USER "${USER}"
# WORKDIR "${HOME}/work"
# ENTRYPOINT ["/entrypoint.sh"]
# CMD ["bash"]

############################## runtime-test (optional) ##############################
# Install-check smoke for the runtime image. Mirrors `FROM devel AS
# devel-test` — ephemeral stage, build-only, never pushed.
#
# FROM runtime AS runtime-test
#
# ARG RUNTIME_SMOKE_CMD='whoami && bash --version'
# RUN bash -c "${RUNTIME_SMOKE_CMD}"
