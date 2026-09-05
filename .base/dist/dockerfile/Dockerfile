# Dockerfile.example - Template for new Docker container repos
#
# Copy this file to your repo root as "Dockerfile" and customize.
# The test-tools image (ShellCheck, Hadolint, Bats) is consumed via the
# TEST_TOOLS_IMAGE build arg, always passed explicitly (no bare-tag
# default). The local `./build.sh` flow builds Dockerfile.test-tools into
# the host Docker daemon and passes a version-scoped
# `test-tools:<base-version>` (mirroring the CI tag minus the registry
# prefix, so two base versions never collide on one host). CI passes
# `ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z` so buildx can pull the
# arch-correct pre-built image without the cross-step image-store
# isolation that broke the old test-tools:local CI pattern.
#
# Stages:
#   sys           - User/group, locale, timezone
#   devel-base    - Development tools and packages
#   builder       - Compile/build stage (optional; opt-in for runtime split, keeps source)
#   devel         - Application-specific tools + entrypoint
#   devel-test    - Lint + bats smoke test (ephemeral, discarded after build)
#   runtime-base  - Minimal runtime base (sudo + tini + ldd-driven libs), optional
#   runtime       - Minimal runtime image (COPY --from=builder install trees), optional
#   runtime-test  - Runtime install-check + bats smoke (ephemeral, optional)
#
# The generalized `-test` stage rule: EVERY `-test` stage is
#   `FROM <the real stage it tests>` (devel-test FROM devel,
#   runtime-test FROM runtime) and brings the shared toolchain in via
#   `COPY --from=test-tools-stage` -- ShellCheck / Hadolint / Bats from
#   the pre-built, version-pinned, multi-arch test-tools image. Do NOT
#   make any `-test` stage `FROM ${TEST_TOOLS_IMAGE}`: a `-test` stage
#   must inherit the REAL environment of the artifact under test, then
#   layer the tools on top. The inverse (real artifacts copied onto the
#   fat tools base) silently masks the very bugs `-test` exists to catch
#   -- runtime-test's `ldd` scan would resolve missing `.so`s against
#   the tools base and report a false green while the shipped runtime is
#   still broken (ros1_bridge#123). See the runtime-test block below.
#
#   Flavour-specific test tooling (e.g. ROS: colcon test / ament_* /
#   launch_testing) is the CONSUMER's responsibility, installed in its
#   own `-test` stage on top of the COPYed common toolchain -- base
#   ships only the common toolchain, no flavoured test image.
#
#   `-test` stages may be heavier than the stages they test; that is
#   fine because they are ephemeral and never reach users (they exist
#   only inside the build/test graph).
#
# Adding extra stages: any `FROM <base> AS <stage>` outside the
# baseline blocklist {sys, devel-base, devel, devel-test, runtime-test}
# is auto-emitted as a compose service that extends `devel` (inherits
# volumes / network / GPU / GUI / cap_add / additional_contexts) and
# overrides only build.target / image / container_name / stdin_open /
# tty / profiles. Stage names must match `^[a-z][a-z0-9_-]*$` and must
# not collide with `latest` / `v[0-9]*` (reserved release tag
# namespace). Use case: entrypoint variants like `headless` + `gui`
# for the same baseline. No setup.conf change needed; run any wrapper
# to regenerate compose.yaml, then `./run.sh -t <stage>`.
#
# Backward-compat: the legacy stage names `base` and `test` are still
# accepted by the blocklist during the v0.21.x transition (downstream
# Dockerfiles renamed to `devel-base` / `devel-test` over a coordinated
# rollout). They will be removed from the blocklist in a future major.

ARG BASE_IMAGE="ubuntu:24.04"
# No bare-tag default (was `test-tools:local`): build.sh (local) passes a
# version-scoped `test-tools:<base-version>` and CI passes
# `ghcr.io/ycpss91255-docker/test-tools:<version>`, both explicitly. An
# unset value resolves an empty base image and fails the build loudly
# rather than silently reusing a stale, wrong-version local image.
ARG TEST_TOOLS_IMAGE

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
        useradd -m -l -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USER_NAME}"; \
    fi && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

############################## devel-base ##############################
FROM sys AS devel-base

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        sudo \
        ca-certificates \
        git \
        vim \
        tmux \
        terminator \
        curl \
        wget \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

############################## devel ##############################
FROM devel-base AS devel

ARG USER="${USER_NAME}"
ARG GROUP="${USER_GROUP}"
ARG ENTRYPOINT_FILE="script/entrypoint.sh"
ARG CONFIG_DIR="/tmp/config"
# Layered config/ override (template#254): two sequential COPYs into
# /tmp/config/. The first brings .base/dist/config/ defaults; the
# second overlays <repo>/config/ on top. File-level merge -- files in
# <repo>/config/ replace same-path files in /tmp/config/; files only
# in .base/dist/config/ stay; files only in <repo>/config/ are added.
# Mental model is the same as setup.conf section-replace, just at
# file granularity. <repo>/config/ becomes opt-in (init.sh seeds an
# empty .gitkeep for new repos, not the full tree); existing repos
# with a full <repo>/config/ snapshot from earlier seed continue to
# work (their copy overrides every template default, identical to
# pre-v0.22.0 behaviour). Trim <repo>/config/ files that match
# template default to start receiving template-side improvements.
ARG CONFIG_SRC="config"

# Add your application-specific packages here
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         your-package \
#         && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 "./${ENTRYPOINT_FILE}" "/entrypoint.sh"
# Host-side log tee helper. Source from
# script/entrypoint.sh with a single un-guarded line:
#   . /usr/local/lib/base/logging.sh
# The helper is a no-op when LOG_FILE_PATH is unset, so the source
# line is safe to add unconditionally -- repos that haven't opted
# into [logging] local_path stay unaffected. In-image path (vs the
# bind-mounted .base) avoids two failure modes: build-time smoke
# crashes when $USER is unset, and multi-repo workspaces where
# WS_PATH is the workspace parent rather than the repo root.
COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
# Shared glog-style rotate/symlink/prune helper. logging.sh sources
# this sibling from the same in-image dir to write per-start log files, a
# stable <svc>.log symlink, and keep/days retention; it must be COPY'd
# alongside logging.sh or the container tee degrades to no rotation/prune.
COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh
# Generic single-service watchdog. Sourced from
# script/entrypoint.sh right after logging.sh with a single un-guarded
# line:
#   . /usr/local/lib/base/watchdog.sh
# The helper is a no-op while the [lifecycle] watchdog_check knob is unset
# (WATCHDOG_CHECK empty), so the source line is safe to add
# unconditionally. It reuses logrotate.sh for its own watchdog.log, so it
# must be COPY'd alongside logging.sh / logrotate.sh.
COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh
# Layer 1: .base/dist/config/ defaults (subtree-managed, updates with
# .base/dist/script/base/upgrade.sh).
COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/dist/config "${CONFIG_DIR}"
# Layer 2: <repo>/config/ overrides (per-repo, survives subtree
# pull). Files here overlay matching paths from layer 1.
COPY --chown="${USER}":"${GROUP}" --chmod=0755 "${CONFIG_SRC}" "${CONFIG_DIR}"

USER "${USER}"

# WORKDIR is a Docker directive: it interpolates build-time ARG / ENV
# only, not shell-time $HOME. Without this explicit ENV, the
# `WORKDIR "${HOME}/work"` below silently collapses to /work (BuildKit
# emits `WARN: UndefinedVar`) and `docker inspect` reports the wrong
# WorkingDir.
ENV HOME="/home/${USER_NAME}"

# Setup shell, terminator, tmux. The bashrc append picks up the
# bashrc.d bootstrap loop (template#254) which sources any *.sh
# drop-ins under ~/.bashrc.d/ at interactive shell start.
RUN cat "${CONFIG_DIR}"/shell/bashrc >> "${HOME}/.bashrc" && \
    chown "${USER}":"${GROUP}" "${HOME}/.bashrc" && \
    mkdir -p "${HOME}/.bashrc.d" && \
    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true && \
    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" && \
    "${CONFIG_DIR}"/shell/terminator/setup.sh && \
    "${CONFIG_DIR}"/shell/tmux/setup.sh && \
    sudo rm -rf "${CONFIG_DIR}"

# CONVENTION: bake self-built artifacts at an ABSOLUTE /opt/... path,
# never under $HOME.
#
# The `ENV HOME=` line above resolves at BUILD time, so anything this
# image bakes under $HOME is coupled to the build-time USER_NAME. `just
# build` injects the local host's user; CI / release bakes `user` (UID
# 1000). Run a prebuilt / GHCR / `docker save`+`load` image under a
# different USER_NAME -- or just rebuild with one -- and every $HOME path
# points at a different, EMPTY home tree: the baked workspace is invisible
# and the entrypoint's `source` fails. Content at an absolute /opt path is
# immune, because there is no $HOME indirection to resolve.
#
# Three rules:
#
# 1. Install self-built artifacts (colcon workspaces, SDKs, compiled
#    tools) at absolute /opt/<name>. Reserve $HOME for dotfiles and
#    convenience symlinks.
# 2. Have the entrypoint / bashrc source the ABSOLUTE path, never `~` or
#    $HOME. A `~/<name> -> /opt/<name>` convenience symlink created in the
#    per-user RUN block is fine for interactive discoverability -- it is
#    the only user-coupled bit and is cheap to recreate -- but nothing may
#    SOURCE it.
# 3. Never spell a concrete username into a path. Use ${HOME} /
#    ${USER_NAME} where a home path is genuinely needed. A shipped
#    Dockerfile / entrypoint carrying a literal one fails base's
#    `home-literal` lint (`just test lint --home-literal`).
#
# Rule 3 is mechanical and gated; rules 1-2 are a judgement call the lint
# cannot make for you. Rationale: ADR-00000024.
#
# Example (uncomment and adapt):
#RUN mkdir -p /opt/some_ws && \
#    <build into /opt/some_ws> && \
#    sudo chown -R "${USER}":"${GROUP}" /opt/some_ws
#RUN ln -snf /opt/some_ws "${HOME}/some_ws"
# then in script/entrypoint.sh:
#   . /opt/some_ws/install/setup.bash --

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
# Resolves to test-tools:<base-version> (local build.sh) or ghcr.io/.../test-tools:vX.Y.Z (CI).
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
# the seven user-facing wrappers live under <repo>/script/;
# pull them in via that directory (BuildKit follows the ../.base/...
# symlinks since the target sits inside the build context).
COPY script/*.sh /lint/
# Helpers sourced by the wrappers. Must sit next to them so
# build.sh / run.sh / exec.sh / stop.sh / setup.sh can source _lib.sh
# (which in turn sources i18n.sh); setup.sh also sources _tui_conf.sh.
# removing these used to be compensated by inline
# `_detect_lang` fallbacks in every script — now the canonical
# definition lives once in i18n.sh.
# all libs (including _lib.sh, i18n.sh, _tui_conf.sh) now live
# under lib/. Single COPY preserves the directory structure.
COPY .base/dist/script/docker/lib /lint/lib
COPY .base/dist/script/docker/wrapper /lint/wrapper
RUN shellcheck -S warning /lint/wrapper/*.sh /lint/lib/*.sh
WORKDIR /lint
RUN hadolint Dockerfile

# Bats (from pre-built test-tools image; see TEST_TOOLS_IMAGE at top)
COPY --from=test-tools-stage /opt/bats /opt/bats
COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
RUN ln -sf /opt/bats/bin/bats /usr/local/bin/bats

ENV BATS_LIB_PATH="/usr/lib/bats"

# Smoke test (build-verification type). Per-stage selective COPY: only
# the shared baseline + THIS stage's own specs, from both the template
# (.base/dist/test/bats/smoke/) and the repo (test/bats/smoke/). No
# whole-tree COPY, so the ephemeral -test image stays small and picks up
# exactly the specs that apply to devel-test. Adding a stage = a folder
# under smoke/<stage>/ + an analogous COPY block (see runtime-test).
COPY .base/dist/test/bats/smoke/shared/     /smoke_test/
COPY .base/dist/test/bats/smoke/devel-test/ /smoke_test/
COPY test/bats/smoke/shared/                /smoke_test/
COPY test/bats/smoke/devel-test/            /smoke_test/

ARG USER
USER "${USER}"

RUN bats /smoke_test/

############################## builder + runtime split (optional) ##############################
# Three concrete stages for repos that need a separate runtime image
# (compiled binaries / generated artifacts to ship without dev deps).
# Lessons lifted from ycpss91255-docker/ros1_bridge#60 PR -- empirically
# saved ~1.1 GB/arch on that repo's runtime image.
#
# Three rules, all of which the previous commented-out hint was silent on:
#
# 1. `runtime` MUST NOT be `FROM devel`. ros1_bridge had
#    `FROM devel AS runtime` which forced devel to delete its source
#    trees in the same RUN that built them (otherwise runtime carried
#    the bloat). Result: devel was unusable for the standard
#    "edit source, rebuild, retest" workflow. The fix is the
#    conventional split: builder keeps source, devel inherits builder,
#    runtime starts from a fresh base and only `COPY --from=builder`
#    the install trees.
#
# 2. Runtime apt: install only the libs `ldd` proves are missing.
#    Don't bulk-install builder deps "to be safe" -- that defeats the
#    point. Identify the gap empirically:
#      docker run --rm -it <builder-image> bash
#      ldd /opt/<framework>/lib/*.so | grep "not found"
#      dpkg -S <missing.so>     # map back to apt package name
#    For ros1_bridge the gap was a small set:
#    libboost-{chrono,filesystem,program_options,thread}, libpoco-foundation,
#    libgpgme. Note the cross-distro suffix split: noble adds `t64`
#    (time_t-64bit) on some packages, jammy does not -- handle with a
#    `case "${BASE_IMAGE}"` or `case "${UBUNTU_CODENAME}"` branch.
#
# 3. `source FILE` in entrypoints needs a trailing `--`. Bash's
#    `source FILE` (without explicit args) propagates the calling
#    script's positional parameters to the sourced file. Frameworks
#    that re-forward them (ROS 1's catkin/_setup_util.py is the
#    canonical case) then see CMD's `--flag` as their own argparse
#    input, print usage to stdout, and the wrapper sources that usage
#    as shell -- container dies with `setup.sh.<rand>: line 1:
#    usage:: command not found`, exit 127. Pass `--` explicitly:
#      source /opt/<framework>/setup.bash --
#    Document this in script/entrypoint.sh; add a smoke test that runs
#    the runtime image with `--help` as CMD and asserts a sensible
#    exit, not 127.
#
# To enable: uncomment the three blocks below, change `devel` above
# from `FROM devel-base AS devel` to `FROM builder AS devel` so devel
# inherits builder's build artifacts (without re-installing build
# deps), and set `build_runtime: true` in main.yaml's
# call-docker-build job (default is true; only agent/* repos that
# ship no runtime override it to false).

############################## builder (optional) ##############################
# FROM devel-base AS builder
#
# ARG DEBIAN_FRONTEND=noninteractive
#
# # Build-time deps. KEEP source / build intermediates -- devel
# # inherits this stage for the dev workflow, and runtime
# # COPY --from=builder only the install trees (not the source).
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
# # Fetch + build (example: a colcon workspace).
# WORKDIR /build_ws
# COPY src/ /build_ws/src/
# RUN apt-get update && \
#     rosdep install --from-paths ./src --ignore-src -y && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*
# RUN colcon build --install-base /build_ws/install
# # IMPORTANT: do NOT rm -rf source/build trees here. devel needs them
# # for the rebuild workflow; runtime only pulls /build_ws/install via
# # COPY --from=builder, so the source weight never lands in runtime.

############################## runtime-base + runtime (optional) ##############################
# FROM ${BASE_IMAGE} AS runtime-base
#
# ARG DEBIAN_FRONTEND=noninteractive
#
# # Minimal runtime apt: sudo (entrypoint usually needs it), tini
# # (PID 1 signal-handler), plus the ldd-identified shared libs that
# # the install trees need. Keep this list short -- bloat here
# # defeats the purpose of the builder/runtime split.
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         sudo \
#         tini \
#         # libboost-chrono1.74.0 \
#         # libboost-filesystem1.74.0 \
#         # libpoco-foundation70 \
#         # libgpgme11 \
#         && \
#     apt-get clean && \
#     rm -rf /var/lib/apt/lists/*
#
# FROM runtime-base AS runtime
#
# ARG USER="${USER_NAME}"
# ARG GROUP="${USER_GROUP}"
#
# # Pull only the install artifacts out of builder. Source / build
# # intermediates stay in builder (and devel, transitively); runtime
# # carries only what the binary needs to execute.
# COPY --from=builder /build_ws/install /opt/app/install
#
# COPY --chmod=0755 script/entrypoint.sh /entrypoint.sh
# # Host-side log tee helper. Runtime starts from a
# # fresh BASE_IMAGE so the devel stage's helper COPY is NOT
# # inherited -- repos that ship a runtime image and want to opt
# # into [logging] local_path tee must repeat the COPY here so
# # `. /usr/local/lib/base/logging.sh` works in the
# # runtime image too.
# COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh
# # logging.sh sources its logrotate.sh sibling for per-start files +
# # symlink + retention, so COPY it here too.
# COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh
# # Generic single-service watchdog. A no-op while
# # [lifecycle] watchdog_check is unset; a repo enabling it in the runtime
# # image must COPY it here too (runtime is a fresh BASE_IMAGE, so devel's
# # COPY is not inherited). It reuses logrotate.sh (above) for watchdog.log.
# COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh
#
# # (Optional) Interactive-shell env source for `docker exec`.
# #
# # The repo env (e.g. ROS `ros2`) has to reach THREE kinds of process
# # via THREE complementary mechanisms -- this is not a base bug, just
# # how the runtime stage is minimal:
# #   1. PID 1 / the app (`ros2 launch`, exec'd directly, non-interactive):
# #      only the ENTRYPOINT can source it. A directly-exec'd
# #      non-interactive process never reads bashrc, so the entrypoint is
# #      necessary and cannot be replaced by bashrc.
# #   2. Interactive shells (`just exec -t runtime bash`, i.e.
# #      `docker exec -it`): bashrc / ~/.bashrc.d/. devel wires this up;
# #      the minimal runtime does NOT -- this is the gap closes.
# #   3. Non-interactive ad-hoc exec (`docker exec ... ros2 ...`):
# #      neither the entrypoint (exec bypasses it) nor bashrc
# #      (non-interactive) applies. This case inherently needs an
# #      explicit `source` or a `bash -ic` wrapper; do NOT bake env into
# #      Dockerfile `ENV` (arch- and python-version-dependent
# #      LD_LIBRARY_PATH / PYTHONPATH -- fragile; sourcing is canonical,
# #      as upstream `ros:` images do).
# #
# # To give interactive `docker exec` shells the env WITHOUT dragging the
# # full config/ COPY + bashrc.d machinery into the minimal runtime, drop
# # one source line into the system-wide /etc/bash.bashrc (read by every
# # interactive bash). base is ROS-agnostic, so the consumer supplies the
# # ROS-specific line, e.g.:
# #   RUN echo 'source /opt/ros/$ROS_DISTRO/setup.bash' >> /etc/bash.bashrc
# # Heavier alternative: replicate devel's ~/.bashrc + ~/.bashrc.d/ wiring
# # (COPY config/ + the bashrc append loop from the devel stage) so the
# # SAME per-repo drop-ins (config/shell/bashrc.d/*.sh) apply in runtime
# # too. Prefer the single-line /etc/bash.bashrc form to keep runtime
# # minimal. Either way, this is interactive-only: PID 1 and
# # non-interactive exec are unchanged.
# USER "${USER}"
# # WORKDIR interpolates only build-time ARG / ENV (not shell $HOME);
# # for why the explicit ENV is required.
# ENV HOME="/home/${USER_NAME}"
# WORKDIR "${HOME}/work"
# ENTRYPOINT ["/entrypoint.sh"]
# CMD ["bash"]

############################## runtime-test (optional) ##############################
# Install-check + bats smoke for the runtime image. Mirrors `FROM devel
# AS devel-test` -- the generalized `-test` rule: stay
# `FROM runtime` (the REAL minimal runtime under test) and `COPY
# --from=test-tools-stage` the shared toolchain in. Ephemeral,
# build-only, never pushed. CI builds this target after `target:
# runtime`; build failure surfaces a smoke failure visibly in the GHA
# log.
#
# Two smoke styles, both supported (use either or both):
#   (a) ldd-based install-check via RUNTIME_SMOKE_CMD -- the bare,
#       dependency-free default; proves the real runtime resolves every
#       shared library its binaries need (the ros1_bridge#123
#       false-green trap in the header).
#   (b) Bats smoke against the real runtime -- COPY Bats in from
#       test-tools-stage (exactly as devel-test does) and run a
#       runtime-specific .bats suite. Lets the runtime image assert real
#       behaviour (entrypoint, installed CLIs, library resolution) with
#       the same harness devel-test uses, while still running INSIDE the
#       genuine minimal runtime.
#
# Flavour-specific runtime test tooling (e.g. ROS colcon test / ament_*
# / launch_testing) is the consumer's own job: `apt-get install` it in
# THIS stage on top of the COPYed common toolchain. base ships only the
# common toolchain, not a ROS-flavoured test image (scope).
#
# NOTE (build-worker prerequisite,): the moment runtime-test does
# `COPY --from=test-tools-stage`, the test-tools image enters
# runtime-test's build graph, so its build must receive the pinned
# `TEST_TOOLS_IMAGE` build-arg too (not just devel-test). build-worker's
# "Build runtime-test stage" step forwards it; a local `./build.sh`
# forwards its version-scoped `test-tools:<base-version>` tag.
#
# Default smoke command is generic install-check (USER set + bash on
# PATH). Override per repo via `build_args: RUNTIME_SMOKE_CMD=<command>`
# to test domain binaries.
#
# Constraint: command must be CLI-only -- no GUI tools that init
# QApplication / OGRE on `--version` / `--help` (rqt, rviz2,
# gazebo-classic). Prefer `<binary> --help`, `command -v <binary>`,
# package manager queries (`ros2 pkg list | grep ...`, `rospack
# find ...`) over invoking the GUI binary itself.
#
# `bash -c` wrapper required: `RUN ${ARG}` does word-splitting on the
# substituted value and treats shell operators (&&, ||, etc.) as
# literal arguments to the first word. Wrapping with
# `bash -c "${RUNTIME_SMOKE_CMD}"` passes the value as a single string
# for bash to parse, preserving operators, nested quotes, AND bash-only
# constructs commonly used in install-checks: `source <bash-script>`
# (and `. <bash-script>` against bash-syntax files like
# `/opt/ros/$DISTRO/setup.bash`), `${var:-default}` style parameter
# expansion, etc. An earlier `sh -c` wrapper (v0.21.1 through v0.23.0)
# broke any override that sourced bash-syntax files because /bin/sh on
# Debian/Ubuntu is dash, which has neither `source` nor bash parameter
# expansion. bash is present in every Ubuntu/Debian-based runtime image
# the template targets, so the bash dependency is safe.
#
# Only enable when the runtime stage above is also enabled. The
# `if: build_runtime` gate in build-worker.yaml mirrors this -- if
# your repo doesn't ship a runtime stage, leave both runtime and
# runtime-test commented out and set `build_runtime: false` in
# main.yaml.
#
# FROM runtime AS runtime-test
#
# # Style (a) -- ldd-based install-check (default, no toolchain needed).
# #default smoke check includes an ldd-based missing-dep scan
# # via runtime/smoke.sh (catches missing .so installs that the old
# # 'whoami && bash --version' default silently passed -- e.g.
# # libboost_regex.so absent in ros1_bridge#123).
# COPY .base/dist/script/docker/runtime/smoke.sh /usr/local/lib/base/smoke.sh
# ARG RUNTIME_SMOKE_CMD='whoami && bash --version && bash /usr/local/lib/base/smoke.sh'
# # Inherit USER from runtime (non-root). install-check doesn't need
# # privilege; if downstream override needs root, prefix with sudo.
# RUN bash -c "${RUNTIME_SMOKE_CMD}"
#
# # Style (b) -- Bats smoke against the real runtime (opt-in). Same
# # generalized pattern as devel-test: COPY Bats in from the pre-built
# # test-tools image (NO re-download / re-install -- the cached
# # multi-arch image devel-test already uses), then run a
# # runtime-specific suite INSIDE the genuine minimal runtime. Requires
# # the TEST_TOOLS_IMAGE build-arg to reach this stage's build (see the
# # build-worker prerequisite note above).
# #
# # Stay non-root (inherit from runtime, so hadolint DL3002 is happy and
# # the smoke runs as the real user). `COPY --from` already runs as root
# # regardless of the current USER; the few writes into system paths use
# # the runtime image's passwordless sudo rather than a `USER root`
# # switch (which would have to be undone before the final RUN).
# COPY --from=test-tools-stage /opt/bats /opt/bats
# COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats
# RUN sudo ln -sf /opt/bats/bin/bats /usr/local/bin/bats
# ENV BATS_LIB_PATH="/usr/lib/bats"
# # Runtime-specific bats suite (e.g. assert installed CLIs resolve,
# # entrypoint exits 0 on --help, ldd clean). Keep it CLI-only -- no GUI
# # binaries that init QApplication / OGRE. Same per-stage selective COPY
# # as devel-test: only shared/ + this stage's runtime-test/, from both
# # the template and the repo.
# COPY .base/dist/test/bats/smoke/shared/       /smoke_test/
# COPY .base/dist/test/bats/smoke/runtime-test/ /smoke_test/
# COPY test/bats/smoke/shared/                  /smoke_test/
# COPY test/bats/smoke/runtime-test/            /smoke_test/
# # Flavour-specific runtime test deps are the consumer's job -- install
# # them HERE on top of the common toolchain, e.g. for ROS:
# #   RUN sudo apt-get update && \
# #       sudo apt-get install -y --no-install-recommends \
# #           python3-colcon-common-extensions \
# #           && \
# #       sudo apt-get clean && sudo rm -rf /var/lib/apt/lists/*
# RUN bats /smoke_test/
