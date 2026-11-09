# Dockerfile - Isaac Sim 6.2.0 dev container (rebased onto base v0.28.0
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
# any wrapper to regenerate compose.yaml, then `just docker run -t <stage>`.
#
# Backward-compat: the legacy stage names `base` and `test` are still
# accepted by the blocklist during the v0.21.x transition (renamed to
# `devel-base` / `devel-test` here). They will be removed from the
# blocklist in a future major.

# Isaac Sim 6.2.0 GA, NGC tag 6.2.0.1 (isaac#295). NGC carries two tags for
# 6.2.0: `6.2.0` (built 2026-10-08, /isaac-sim/VERSION 6.2.0-rc.14) and
# `6.2.0.1` (built 2026-10-14, the GA release day, 6.2.0-rc.15). Same
# Dockerfile recipe; across all 52,988 .so/.py files the only differences
# are the URDF importer's UDIM material XML-declaration parser
# (material_reconstruction.py, on our model_import path), the unused UCX
# bridge, the version plugin and one test file. Every physics, RTX,
# replicator and ROS 2 binary is byte-identical, so evidence gathered on
# `6.2.0` (e.g. the IsaacSim#803 repro) holds for `6.2.0.1`.
ARG BASE_IMAGE="nvcr.io/nvidia/isaac-sim:6.2.0.1"
ARG TEST_TOOLS_IMAGE="test-tools:local"

############################## sys ##############################
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS sys

ARG USER_NAME="user"
ARG USER_GID=1000
ARG USER_UID=1000
ARG USER_GROUP="user"
ARG TZ="Asia/Taipei"
ARG APT_MIRROR_UBUNTU="tw.archive.ubuntu.com"
ARG DEBIAN_FRONTEND=noninteractive

# [isaac] The Isaac Sim 6.x base image ships with a non-root default user
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
# deriving from devel (headless / stream / devel-test) has it. Kept early
# in devel so day-to-day config / app COPY changes below do not invalidate
# this large layer. The framework (isaac_devkit) stays mounted, not baked
# (ADR-0017 section 2: base tools baked + pinned, framework mounted).
#
# Pinned to v3.0.0 (GA) -- the release NVIDIA pairs with Isaac Sim 6.2
# ("This release targets Isaac Sim 6.2, Python 3.12, PyTorch 2.11 with
# CUDA 13.0"; its pyproject pins isaacsim = "6.2.0.0"). Bumped from
# v3.0.0-beta2.patch1 (the 6.0.1 pairing) in isaac#295.
#
# RL learning frameworks (rl_games / rsl_rl / sb3 / skrl / robomimic) are
# NOT installed yet (`--install none` below; Isaac Lab 3.0 treats `none`
# as the old name for `core`): the current product is single-scene + ROS 2
# service, no reinforcement learning. They are DEFERRED, not excluded --
# parallel-environment / RL-style work is planned later (the "C" /
# InteractiveScene direction in ADR-0018). When that lands, replace the
# `--install none` line with the full install:
#
#     /opt/IsaacLab/isaaclab.sh --install all && \
#
# or install only the frameworks you need, e.g.:
#
#     /opt/IsaacLab/isaaclab.sh --install rl[rsl-rl],rl[skrl] && \
#
# PyTorch: Isaac Lab v3.0.0's installer owns the torch install. It
# installs the pinned torch==2.11.0 / torchvision==0.26.0 from the cu130
# index (cu130 wheels carry sm_120 kernels for the RTX 5090 runner; CUDA
# 13 needs driver >= 580, the runner has 610), repoints Isaac Sim's
# deprecated omni.isaac.ml_archive torch at the installed copy so no
# launch path can load the old one, and aborts the install if any pip
# step left a dangling pip_prebundle __init__.py (nvbugs 6343978). The
# 6.0.1 build had to pre-install torch 2.11.0+cu128 itself (beta2's
# installer let an older nccl without ncclCommShrink win); that step is
# gone -- a pre-installed cu128 torch would just be uninstalled and
# replaced by the cu130 one. The post-install check below asserts the
# torch that ended up on the path is the CUDA 13 build.
#
# isaac#288 (dangling pip_prebundle symlinks): on 6.0.1 the beta2 install
# deleted omni.isaac.core_archive's prebundled `packaging`, which
# omni.services.pip_archive links into -> 12 dangling links, matplotlib
# plots and the Newton experience broke. v3.0.0 filters pip_prebundle
# paths out of PYTHONPATH during every pip operation and fails the build
# on a new dangling __init__.py. The RUN after the xacro install below
# re-asserts it over every pip step in this file, not just Isaac Lab's.
#
# URDF importer: Isaac Sim 6.2.0 bundles isaacsim.asset.importer.urdf
# 3.11.12 (6.0.1: 3.11.2), and Isaac Lab 3.0's isaaclab.python.kit does not
# pin it. The 2.4.31 experience pin in
# framework/isaac_devkit/model_import.py (_simulation_app_kwargs) is a 5.1
# leftover that is now only a docstring; it does not block anything.
ARG ISAACLAB_VERSION="v3.0.0"
# cmake / build-essential are what isaaclab.sh would otherwise apt-install
# itself (it skips that when cmake is already present).
RUN apt-get update && \
    apt-get install -y --no-install-recommends git cmake build-essential && \
    git clone --depth 1 --branch "${ISAACLAB_VERSION}" \
        https://github.com/isaac-sim/IsaacLab.git /opt/IsaacLab && \
    ln -s /isaac-sim /opt/IsaacLab/_isaac_sim && \
    /opt/IsaacLab/isaaclab.sh --install none && \
    /isaac-sim/python.sh -m pip show isaaclab && \
    /isaac-sim/python.sh -c "import torch; v = torch.__version__; assert v.endswith('+cu130'), v; print('torch', v)" && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# xacro: the offline URDF preprocess (isaac_devkit.model_import,
# ADR-0020 decision 6, isaac#169) expands a .xacro input to plain URDF
# before the Isaac importer runs. The standalone PyPI 'xacro' package is
# pure Python and expands without a live ROS environment (xacro.process_file).
# Installed into the Isaac python so the offline commit step
# (/isaac-sim/python.sh -m isaac_devkit.model_import) can import it.
RUN /isaac-sim/python.sh -m pip install --no-cache-dir xacro

# [isaac#288] Fail the build if any pip step above left a pip_prebundle
# package without its __init__.py. Isaac Sim shares prebundled packages
# between extensions as symlink farms; a pip install that removes the copy
# others link into breaks those extensions at runtime (6.0.1: `packaging`
# under omni.services.pip_archive -> matplotlib + the Newton experience).
RUN dangling="$(find /isaac-sim -xtype l -name '__init__.py' -path '*pip_prebundle*')" && \
    if [ -n "${dangling}" ]; then \
        echo "dangling pip_prebundle package(s):" >&2; \
        echo "${dangling}" >&2; \
        exit 1; \
    fi

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
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/dist/config "${CONFIG_DIR}"
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
# (just docker build) to switch distros.
ARG ROS_DISTRO=humble
RUN mkdir -p /etc/isaac && echo "${ROS_DISTRO}" > /etc/isaac/ros-distro

# [isaac] Pre-create the extension folders Kit tries to create at boot.
# The experience file lists ${app}/../extsUser, which the NGC image does
# not ship, and the non-root container user cannot create it under
# /isaac-sim (0750, owned by isaac-sim). Kit then keeps that folder as ''
# and scans the working directory (~/work, the repo root) for extensions,
# warning "Extensions config 'extension.toml' doesn't exist" once per
# top-level directory on every launch. kit/exts and kit/extsPhysics are
# the other two folders Kit tries to create there.
RUN mkdir -p /isaac-sim/extsUser /isaac-sim/kit/exts /isaac-sim/kit/extsPhysics

# [isaac] Soft bake for devel stage (interactive shell). headless / stream
# stages additionally run the wrapper shim below — that re-exports from
# /etc/isaac/ros-distro at every container start, hard-baking against
# runtime override.
ENV ROS_DISTRO=${ROS_DISTRO} \
    LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.core/${ROS_DISTRO}/lib

# [isaac] ENTRYPOINT shim for headless / stream stages: re-reads
# /etc/isaac/ros-distro and unconditionally exports ROS_DISTRO +
# LD_LIBRARY_PATH before exec'ing the wrapped binary. Lives in /usr/local/bin/
# so the headless / stream stages can name it absolutely in ENTRYPOINT.
COPY --chmod=0755 script/isaac-ros-env-wrapper.sh /usr/local/bin/isaac-ros-env-wrapper.sh

# [isaac] runheadless wrapper that reads per-host config from
# /etc/host.yaml (mounted from <repo>/config/host.yaml by caller).
# Used by script/hooks/post/run.sh and script/ci/stream_smoke.sh to inject
# --/app/livestream/publicEndpointAddress without host-side YAML
# parsing. See doc/ for the host.yaml schema.
COPY --chmod=0755 script/runheadless-host-config.sh /usr/local/bin/runheadless-host-config.sh
# Shared host.yaml parser sourced by the wrapper above (and by host-side
# script/hooks/post/run.sh + script/ci/stream_smoke.sh) -- single source of
# truth (#104).
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

# [isaac] The NGC base image ships a HEALTHCHECK that greps a Kit log under
# /isaac-sim/.nvidia-omniverse/logs/Kit for "App is loaded". devel and the
# stages built on it (headless / stream / test) idle with no Kit by design
# and mount the Kit logs elsewhere, so every container reported
# `unhealthy` forever. Health is not meaningful for an idle shell; Kit's
# state is in its log.
HEALTHCHECK NONE

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]

############################## devel-test ##############################
# Resolves to test-tools:local (local build.sh) or ghcr.io/.../test-tools:vX.Y.Z (CI).
# hadolint ignore=DL3006
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
# normal .base/ layout. The `COPY .base/dist/script/docker/lib /lint/lib`
# below brings ALL of these in one shot.
COPY .base/dist/script/docker/lib /lint/lib
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
# [#233] Host-side CI drivers (script/ci/) are likewise missed by the flat
# /lint/*.sh glob. The whole dir is copied so `-x` can follow
# stream_smoke.sh -> stream_smoke_lib.sh.
COPY script/ci /lint/ci
RUN shellcheck -S warning -x /lint/ci/*.sh
WORKDIR /lint
RUN hadolint Dockerfile

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

# Smoke test (shared from base + repo-specific). base v0.42.0 ships its
# smoke templates under the canonical tool-first layout
# .base/dist/test/bats/smoke/{shared,devel-test,runtime-test}/ (base#650 /
# base#835). Repo-local .bats files move to the matching test/bats/smoke/
# (base's canonical consumer layout; this is what release-worker.yaml's
# archive keep-list expects). Selective COPY of base's shared baseline +
# the devel-test stage specs, then the repo's own smoke specs, flattened
# into /smoke_test/ for `bats /smoke_test/` (see .base/doc/test/smoke.md).
COPY .base/dist/test/bats/smoke/shared/ /smoke_test/
COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/
COPY test/bats/smoke/ /smoke_test/
# [#104] Shared host.yaml parser, baked next to host_yaml_spec.bats.
COPY script/host_yaml.sh /smoke_test/host_yaml.sh
# [#233] Tier A stream-smoke decision logic (client-connect sequence +
# dwell/liveness assertions), baked next to stream_smoke_lib_spec.bats.
COPY script/ci/stream_smoke_lib.sh /smoke_test/stream_smoke_lib.sh
# [owv#55] The Tier A GPU driver itself, baked next to
# stream_smoke_isolation_spec.bats so the spec can exercise its compose-
# project isolation (distinct PROJECT_NAME bring-up + project-scoped
# teardown; base v0.42.0 removed --instance, base#666) against stub
# run.sh / docker -- behavioral, no docker, no GPU. The GPU path stays
# host-side and nightly-only (stream-smoke.yaml).
COPY --chmod=0755 script/ci/stream_smoke.sh /smoke_test/stream_smoke.sh
# [base #440] Scripts under test by the migrated specs: the livestream
# wrapper + the post run/stop hooks. The hooks are named run.sh / stop.sh
# inside their post dir, so they are baked under distinct flat names that
# match the *_spec.bats files.
COPY --chmod=0755 script/runheadless-host-config.sh /smoke_test/runheadless-host-config.sh
COPY --chmod=0755 script/hooks/post/run.sh /smoke_test/post_run_hook.sh
COPY --chmod=0755 script/hooks/post/stop.sh /smoke_test/post_stop_hook.sh
# [base#1550 / base#1551 stopgap] The pre build/run/stop hooks refuse a
# checkout still on the shared image tag / compose project; baked next to
# checkout_identity_spec.bats so the spec drives the real hooks.
COPY --chmod=0755 script/hooks/pre/build.sh /smoke_test/pre_build_hook.sh
COPY --chmod=0755 script/hooks/pre/run.sh /smoke_test/pre_run_hook.sh
COPY --chmod=0755 script/hooks/pre/stop.sh /smoke_test/pre_stop_hook.sh
COPY --chmod=0755 script/checkout_identity.sh /smoke_test/checkout_identity.sh
# [owv#55] The GPU-pytest baseline gate, baked next to
# assert_pytest_baseline_isolation_spec.bats so the spec can exercise its
# --gpu `run.sh -t test` invocation against a stub run.sh (no docker, no GPU).
COPY --chmod=0755 test/assert_pytest_baseline.sh /smoke_test/assert_pytest_baseline.sh

ARG USER="${USER_NAME}"
USER "${USER}"

RUN bats /smoke_test/

# Restore the runtime working directory to the workspace mount. The
# hadolint step above uses `WORKDIR /lint` (base v0.42.0's declarative
# migration of `cd /lint && hadolint`, avoiding hadolint DL3003), but
# that WORKDIR persists into the image -- leaving the devel-test runtime
# CWD at /lint. `./script/run.sh -t test -- ... pytest test/integration/
# pytest/` passes a workspace-relative path, so a /lint CWD makes pytest
# collect 0 items ("rootdir: /lint"). Reset to ${HOME}/work (the bind
# mount target, same as the devel stage) so relative test paths resolve.
WORKDIR "${HOME}/work"

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
#   just docker run -t headless -d
#   just docker exec -t headless /isaac-sim/python.sh <driver.py>
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
#   just docker run -t stream -d
#   just docker exec -t stream /isaac-sim/python.sh <driver.py>
#   # -> browser connects via web-viewer at :5173
#
# For one-off headless streaming without a driver script:
#   just docker exec -t stream /isaac-sim/runheadless.sh -v \
#     --/app/livestream/nvcf/quitOnSessionEnded=false
FROM devel AS stream

ENV ISAAC_LIVESTREAM=2
CMD ["sleep", "infinity"]

############################## producer ##############################
# [isaac #223 / owv#48 / #173] Deterministic WebRTC stream-source producer.
# Published as a pullable, pinned GHCR image
# (ghcr.io/ycpss91255-docker/isaac-stream-source:<tag>, via
# .github/workflows/publish-stream-source.yaml) so the omniverse_web_viewer
# visual e2e (owv#48) and the Tier B browser-frames smoke (isaac#173) always
# have a real, reproducible WebRTC source without a live desktop Isaac
# session. Unlike the headless / stream stages (which idle and have driver
# scripts exec'd in from the bind-mounted workspace), this stage BAKES its
# driver and boots it directly, so `docker run --network=host -e
# PUBLIC_IP=<ip> <image>` launches a running producer with no volume mount.
#
# src/ is not carried by any base stage (it is bind-mounted at runtime for
# the devel / headless / stream stages), so the single driver file is COPY'd
# in explicitly here. COPY writes as the builder (not the image USER), so it
# lands root-owned 0644 (world-readable) under /opt without a USER switch;
# /isaac-sim/python.sh reads it fine. The driver reads PUBLIC_IP /
# ISAAC_SIGNAL_PORT from env (its argparse defaults); ISAAC_LIVESTREAM=2 is
# inherited from the stream stage.
FROM stream AS producer

# What this image is, in the image, so nobody has to run an 18 GB container to
# find out (isaac#252 aftermath). The version tag deliberately does NOT encode
# the Isaac Sim version -- it just increments -- so the base image is recorded
# here instead, where it cannot drift from what was actually built.
#
#   docker inspect <image> \
#     --format '{{index .Config.Labels "org.opencontainers.image.base.name"}}'
#
# script/ci/sync_producer_versions.py reads exactly this label, from the
# registry and without pulling, to regenerate the READMEs' version table.
# `org.opencontainers.image.*` are the OCI-specified keys; MAINTAINER is the
# deprecated instruction these replaced.
ARG BASE_IMAGE
ARG GIT_SHA="unknown"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.source="https://github.com/ycpss91255-docker/isaac"
LABEL org.opencontainers.image.description="Deterministic WebRTC stream-source producer for downstream viewer e2e (isaac#223)"

COPY --chmod=0644 src/script/stream_source_producer.py \
     /opt/isaac-producer/stream_source_producer.py

ENV PUBLIC_IP="" \
    ISAAC_SIGNAL_PORT=49100

CMD ["/isaac-sim/python.sh", "/opt/isaac-producer/stream_source_producer.py"]

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
