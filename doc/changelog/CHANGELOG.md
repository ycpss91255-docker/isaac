# Changelog

## [Unreleased]

### Added
- Isaac Sim 5.1.0 base image (`nvcr.io/nvidia/isaac-sim:5.1.0`) wired in via Dockerfile `ARG BASE_IMAGE`
- `script/init_isaac_dirs.sh` — host-side first-time setup that pre-creates 8 Isaac Sim cache dirs under `${WS_PATH}/isaac-sim/` so the container's non-root user can write to them (avoids docker daemon root auto-mkdir)
- `setup.conf [environment]`: `ACCEPT_EULA=Y`, `PRIVACY_CONSENT=Y`
- `setup.conf [volumes]`: 8 cache mounts (`kit` / `ov` / `pip` / `glcache` / `computecache` / `logs` / `data` / `documents`)
- `setup.conf [deploy] gpu_capabilities`: added `video` to expose NVENC libs (`libnvidia-encode.so`, `libnvcuvid.so`) via nvidia-container-runtime. Without this the WebRTC client connects but the server cannot encode frames, producing a black viewport.
- `test/smoke/isaac_smoke.bats` — 5 image-side sanity assertions (launchers, Python 3.11, runtime user identity, isaac-sim group membership, HOME writability)
- Dockerfile `headless` + `gui` stages — non-baseline stages auto-emitted as compose services by template v0.17+ (#215). `./run.sh -t headless -d` directly launches WebRTC streaming server (entrypoint `runheadless.sh -v`); `./run.sh -t gui -d` launches X11 GUI app (entrypoint `runapp.sh`). Replaces the previous "manual `docker exec /isaac-sim/runheadless.sh` from inside `devel`" workflow.
- `setup.conf [stage:headless] gui.mode = off` — per-stage override (#220, requires template ≥ v0.18.1) that strips X11 mount + `DISPLAY` env from the headless service so kit no longer emits `X11 connection rejected because of wrong authentication` cosmetic warnings during livestream startup.
- `setup.conf [environment]` ROS 2 bridge baseline (distro-agnostic) — `ROS_DOMAIN_ID=0`, `RMW_IMPLEMENTATION=rmw_fastrtps_cpp`, `FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml`. The image keeps the ROS distro choice open: `ROS_DISTRO` and `LD_LIBRARY_PATH` are deliberately NOT set, letting Isaac Sim's `/isaac-sim/setup_ros_env.sh` auto-detect (24.04 noble → jazzy default). Downstream consumers needing humble override both env vars at compose run time. Aligns with NVIDIA's official [Isaac Sim 5.1 ROS 2 install guide](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/install_ros.html).
- `config/ros2/fastdds.xml` — Fast DDS profile (UDPv4-only, `useBuiltinTransports=false`) lifted verbatim from the official guide. Built-in SHM transport is unreliable across containers even with `--ipc=host`; forcing UDP makes cross-container discovery deterministic on `--net=host`.
- `Dockerfile` devel stage `COPY config/ros2/fastdds.xml /isaac-sim/fastdds.xml` (mode 0644) — bakes the profile into the image so both `isaac` and any sibling `ros:humble` container can point `FASTRTPS_DEFAULT_PROFILES_FILE` at the same file (or bind-mount it to ROS 2 client containers).
- `test/smoke/docker_env.bats` — `fastdds.xml` is baked + readable + contains `<useBuiltinTransports>false</useBuiltinTransports>`.
- `test/smoke/isaac_smoke.bats` — bundled humble + jazzy `lib/librmw_fastrtps_cpp.so` + `rclpy/rclpy` are both present, image stays distro-agnostic.

### Changed
- Dockerfile sys stage now starts with `USER root` so apt / locale / useradd work on base images that ship with a non-root default user (e.g. Isaac Sim's `isaac-sim` UID 1234)
- Dockerfile sys stage adds the host-aligned `USER_NAME` to the `isaac-sim` group when present, so the container user can read `/isaac-sim/*` (mode `0750`)
- DL3002 ("Last USER should not be root") suppressed via `# hadolint ignore=DL3002` inline comment on the sys stage's `USER root` line, per upstream hadolint #405's recommended workaround. Replaces the previous repo-level `.hadolint.yaml` ignore (which was a symlink to template's, getting reset on every `make upgrade`).

### Notes
- Isaac Sim 5.1 reads privacy consent from `OMNI_ENV_PRIVACY_CONSENT`, not `PRIVACY_CONSENT`. The latter is preserved for backwards compat but no longer effective; set the former explicitly to opt in to telemetry.
- `[stage:headless] gui.mode = off` requires template **v0.18.1 or later** — v0.18.0 had a list-inheritance bug where the override was emitted on top of `extends: devel`, so X11 mounts inherited regardless. Fixed in v0.18.1 by switching to standalone-emit when any list-affecting override fires.
- ROS 2 bridge auto-loads via the default kit experience (`isaacsim.exp.full.kit` → `[settings] isaac.startup.ros_bridge_extension = "isaacsim.ros2.bridge"`); no `--enable isaacsim.ros2.bridge` launch flag is needed in `runheadless.sh` / `runapp.sh` CMD.
- Distro selection is intentionally left open in this repo. `/isaac-sim/setup_ros_env.sh` auto-detects: 22.04 → humble, 24.04 → jazzy (default for this image). Bridge distro priority (per `isaacsim.ros2.bridge/extension.py`): `os.environ["ROS_DISTRO"]` > kit setting `exts."isaacsim.ros2.bridge".ros_distro` (resolves `system_default` → Ubuntu detection).
- Override to humble via `setup.conf [environment]` (wrapper-aligned): `./setup.sh add environment.env "ROS_DISTRO=humble"` then `./setup.sh add environment.env "LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib"`, then `./run.sh -t headless -d`. The `${ROS_DISTRO}` cross-reference is expanded by setup.sh at compose-emit time (template ≥ v0.20.1, [#236](https://github.com/ycpss91255-docker/template/issues/236)) — order-sensitive, so `ROS_DISTRO=humble` must be added first.
- Template upgraded v0.18.1 → v0.20.1: ships the `${KEY}` cross-reference fix above, plus `setup_tui` main-menu restructure (cosmetic) and an opt-in `publish-worker.yaml` reusable workflow (we don't consume it).
