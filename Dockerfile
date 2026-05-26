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
#   headless      - Isaac Sim WebRTC streaming entrypoint (FROM devel)
#   gui           - Isaac Sim X11 entrypoint (FROM devel)
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
# namespace). `headless` / `gui` below are the two repo-side entrypoint
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
# Build-time setup scaffolding (base #261): pip install + other deferred
# Dockerfile RUN helpers live under .base/dockerfile/setup/ post this
# release. Previously sat under .base/config/pip/ but that blurred
# "user-facing runtime config" (everything else in config/) with
# "build-time install scaffolding" (pip only). Separating them keeps
# config/ as the pure runtime-override surface (base #254 layered COPY
# semantics) and lets new build-time helpers land alongside without
# re-introducing the conceptual mix. Cleared via `sudo rm -rf ${SETUP_DIR}`
# at the end of the shell-setup RUN block, same lifetime as CONFIG_DIR.
ARG SETUP_DIR="/tmp/setup"
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
# Build-time setup scaffolding (base #261). No layered override here —
# .base/dockerfile/setup/ is the single source of truth; downstream
# customizes by patching its own Dockerfile RUN line(s) or by adding
# more entries to its own dockerfile/setup/ tree + a matching COPY
# (rare). The directory is cleared at the end of the shell-setup RUN
# block alongside CONFIG_DIR.
COPY --chmod=0755 .base/dockerfile/setup "${SETUP_DIR}"

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
# the value into a const file consumed by the headless / gui ENTRYPOINT
# shim, so runtime `-e ROS_DISTRO=...` flags are ignored. Rebuild
# (./build.sh) to switch distros.
ARG ROS_DISTRO=humble
RUN mkdir -p /etc/isaac && echo "${ROS_DISTRO}" > /etc/isaac/ros-distro

# [isaac] Soft bake for devel stage (interactive shell). headless / gui
# stages additionally run the wrapper shim below — that re-exports from
# /etc/isaac/ros-distro at every container start, hard-baking against
# runtime override.
ENV ROS_DISTRO=${ROS_DISTRO} \
    LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib

# [isaac] ENTRYPOINT shim for headless / gui stages: re-reads
# /etc/isaac/ros-distro and unconditionally exports ROS_DISTRO +
# LD_LIBRARY_PATH before exec'ing the wrapped binary. Lives in /usr/local/bin/
# so the headless / gui stages can name it absolutely in ENTRYPOINT.
COPY --chmod=0755 script/isaac-ros-env-wrapper.sh /usr/local/bin/isaac-ros-env-wrapper.sh

USER "${USER}"

# [isaac] HOME is implicit on Linux but Docker's WORKDIR directive
# interpolates only build-time ARG / ENV (not shell-set HOME). Without
# this explicit ENV the `WORKDIR "${HOME}/work"` below silently resolves
# to `/work` and emits a BuildKit `UndefinedVar` warning. Setting HOME
# explicitly silences the warning and makes the WORKDIR intent — and
# non-interactive `docker exec` cwd — match the interactive shell.
ENV HOME="/home/${USER_NAME}"

# Setup pip packages (build-time scaffolding from SETUP_DIR, base #261).
RUN "${SETUP_DIR}"/pip/setup.sh

# Setup shell, terminator, tmux. The bashrc append picks up the
# bashrc.d bootstrap loop (base #254) which sources any *.sh
# drop-ins under ~/.bashrc.d/ at interactive shell start.
# SETUP_DIR is cleared alongside CONFIG_DIR (same build-time-only
# lifetime; once their content has been consumed by the RUN steps
# above, they are pure bloat in the final image).
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}" "${SETUP_DIR}"

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
COPY .base/script/docker/_lib.sh \
     .base/script/docker/i18n.sh \
     .base/script/docker/_tui_conf.sh \
     /lint/
# _lib.sh post-base#284 is an umbrella that sources lib/*.sh sub-libs.
# Preserve the lib/ subdirectory in /lint/ so the source paths inside
# _lib.sh resolve identically to the normal .base/ layout.
COPY .base/script/docker/lib /lint/lib
# Lint coverage for repo-local Dockerfile-internal build helpers
# (base #275). Uncomment if your repo has any <repo>/script/docker/*.sh
# build helpers (see the commented example in the devel stage above);
# the COPY brings them into /lint/ so ShellCheck catches issues at
# build time.
#COPY script/docker/*.sh /lint/
RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh
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
# [isaac] Auto-emitted as compose service by setup.sh (base #215).
# `./run.sh -t headless -d` 直接拉起 Isaac Sim WebRTC streaming server，
# 不需要 docker exec /isaac-sim/runheadless.sh。
#
# ENTRYPOINT goes through isaac-ros-env-wrapper.sh which re-exports
# ROS_DISTRO + LD_LIBRARY_PATH from /etc/isaac/ros-distro (baked at
# build time from ARG ROS_DISTRO). This makes runtime
# `-e ROS_DISTRO=...` flags ineffective — distro is build-time only.
FROM devel AS headless

ENTRYPOINT ["/usr/local/bin/isaac-ros-env-wrapper.sh", "/isaac-sim/runheadless.sh"]
CMD ["-v", "--/app/livestream/nvcf/quitOnSessionEnded=false"]

############################## gui ##############################
# [isaac] 本機 GUI（X11 forward）— 需要 host 端 `xhost +local:docker` 已開
# (base run.sh 自動處理) 與 DISPLAY env (base 也自動帶入)。
# `./run.sh -t gui -d` 直接拉起 Isaac Sim 視窗版本。
#
# Same wrapper as headless — re-exports ROS env from baked file.
FROM devel AS gui

ENTRYPOINT ["/usr/local/bin/isaac-ros-env-wrapper.sh", "/isaac-sim/runapp.sh"]
CMD []

############################## standalone ##############################
# [isaac] Standalone Python workflow — 用 `/isaac-sim/python.sh` 直接跑
# Python 腳本 (內部 `SimulationApp({"livestream": 2})` 自己 boot 一份 kit
# + WebRTC server)。使用 pattern:
#   ./run.sh -t standalone -d
#   ./exec.sh -t standalone /isaac-sim/python.sh <script>
# (Ctrl+C 殺 script，容器仍 idle；./stop.sh 收尾。)
#
# CMD ["sleep", "infinity"] 讓容器 idle 等待 ./exec.sh dive-in。為什麼
# 不繼承 devel 的 `bash` CMD: profile-gated compose service 預設
# `stdin_open: false, tty: false` (vs devel base service `true/true`),
# bash 在 non-TTY 環境下 immediately exit 0，容器被視為 Exited 啟動失敗。
# 換成 long-lived `sleep infinity` 保證 idle 直到 ./stop.sh 收。
# ENTRYPOINT 仍繼承自 devel (`/entrypoint.sh`) — entrypoint 做完 env
# init 後 exec "$@" 跑 sleep infinity，乾淨。
#
# 為什麼不用 devel: base v1 [stage:devel] 是 reserved 不開放 per-stage
# override。standalone 是 non-base stage，能透過 `[stage:standalone]
# gui.mode = off` 把 X11 mount strip 掉避免 cosmetic warnings。
# 為什麼不用 headless: headless 的 ENTRYPOINT 是 runheadless.sh，
# 容器一起來已經跑著一個 kit 進程，再 exec python.sh 會啟第二份 kit
# 撞 PhysX / DDS / port 8211。standalone idle 啟動，python.sh 在
# exec session 內是唯一 kit 進程。
FROM devel AS standalone

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
