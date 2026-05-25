# isaac

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker development environment, built on top of [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) (previously `ycpss91255-docker/template`).

Image scope covers Isaac Sim itself plus the env wiring needed for its bundled ROS 2 bridge to talk cross-container. Downstream application nodes (CoreSAM, AGV bring-up) and the ROS 1 / ROS 2 bridge for Noetic interop live in sibling docker folders.

## Prerequisites

- NVIDIA driver `>= 580.65.06` (Isaac Sim 5.1 minimum)
- GPU `>= RTX 4080` (or equivalent), VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- ~20 GB free disk for the NGC image; cache dirs grow another 5–10 GB after first launch

NGC image (`nvcr.io/nvidia/isaac-sim:5.1.0`) is publicly pullable — no `docker login nvcr.io` required.

## Quick Start

> **First-time only:** run `./script/init_isaac_dirs.sh` **before** `make build`. Skipping it lets the docker daemon `mkdir` the cache mount points as **root**, and the container's non-root user will then fail to write — Isaac Sim will not start.

```bash
./script/init_isaac_dirs.sh   # first time only — creates 8 host-owned cache dirs
make build                    # builds devel stage (~16 GB image)
make run                      # interactive shell in devel container
```

Inside the container:

```bash
/isaac-sim/runheadless.sh -v   # WebRTC livestream — connect with the Isaac Sim WebRTC Streaming Client (see below)
/isaac-sim/runapp.sh           # local GUI (requires X11; run `xhost +local:docker` on the host first)
```

> Three stages auto-emitted as profile-gated compose services per [base #215](https://github.com/ycpss91255-docker/base/issues/215): `headless` (ENTRYPOINT `runheadless.sh -v` for WebRTC livestream), `gui` (ENTRYPOINT `runapp.sh` for X11), `standalone` (no ENTRYPOINT, idle — pair with `make exec -- -t standalone /isaac-sim/python.sh <script>` for Python workflows where the script instantiates `SimulationApp({"livestream": 2})` and boots its own kit + WebRTC). Use `make run -- -t <stage> -d`. The manual launchers above still work for ad-hoc cases.

## Connecting to the WebRTC livestream

Isaac Sim 5.1 uses the NVCF (`omni.services.livestream.nvcf`) livestream protocol; **the browser-based viewer from earlier versions has been removed**. Connect with the desktop client:

1. Download the **Isaac Sim WebRTC Streaming Client (1.1.5)** from [NVIDIA docs — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html). 1.1.5 is the latest, ships with 5.1.
2. While `runheadless.sh -v` is running inside the container, launch the client and enter Server: `<server-ip>` (use `localhost` for same-machine, the server's LAN IP otherwise). **Do not add `:8011` or any port suffix** — the client manages signaling/data ports internally; appending a port routes through the wrong path and yields a black screen.
3. Click Connect. First-time shader compile takes 1–3 min before the viewport renders.

Notes:

- The streaming kit app simultaneously listens on `8011` (NVCF signaling, FastAPI/uvicorn) and `49100` (self-host WebRTC). The 1.1.5 client picks the right one — leave the port off.
- **Only one client can connect at a time** (NVIDIA limitation). A second connection attempt is rejected.
- `network_mode: host` is set in `setup.conf`, so the container's listen port = host's listen port. Make sure the host firewall allows `8011/tcp` and `49100/tcp` (e.g. `sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`).
- `gpu_capabilities` in `setup.conf [deploy]` must include `video` — without it, nvidia-container-runtime does not mount NVENC libs (`libnvidia-encode.so`, `libnvcuvid.so`), so the server connects but cannot encode frames → black screen. The current `setup.conf` already includes `video`.
- Verify the listeners from the server: `ss -tln | grep -E ':8011|:49100'` should show both `LISTEN ... :8011` and `LISTEN ... :49100`.

## ROS 2 bridge (bundled, build-time distro)

Isaac Sim 5.1 ships internal ROS 2 libraries for both Humble and Jazzy under `/isaac-sim/exts/isaacsim.ros2.bridge/{humble,jazzy}/`, both with Python 3.11 rclpy matching kit's embedded interpreter. **This image hard-bakes the distro at build time** via `setup.conf [build] arg_N=ROS_DISTRO=<value>` (default `humble`, CoreSAM-aligned).

The bridge extension `isaacsim.ros2.bridge` auto-loads via the default kit experience (`isaacsim.exp.full.kit` → `isaac.startup.ros_bridge_extension`). No `--enable` launch flag needed in `runheadless.sh` / `runapp.sh`.

Env wiring shipped in `setup.conf [environment]` (distro-agnostic):

| Var | Value | Why |
|-----|-------|-----|
| `ROS_DOMAIN_ID` | `0` | small-team default; bump if multiple users share the host |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | explicit FastDDS, no inherit from host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile (cross-container DDS reliable, no SHM flakiness) |

### Distro choice (build-time, hard-baked)

`ARG ROS_DISTRO=humble` in the Dockerfile is wired to `setup.conf [build]`. At build time the value is written to `/etc/isaac/ros-distro`, and `script/isaac-ros-env-wrapper.sh` is installed at `/usr/local/bin/`. The `headless` and `gui` stages set `ENTRYPOINT` to that wrapper, which on every container start unconditionally re-exports `ROS_DISTRO` and `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` from the baked file — runtime `-e ROS_DISTRO=...` flags are therefore ineffective on the production paths.

The `devel` stage soft-bakes the same values via `Dockerfile ENV` (interactive shells get them by default; devs can `export ROS_DISTRO=...` to experiment).

Switch to jazzy:

```bash
make setup -- remove build.arg "ROS_DISTRO=humble"
make setup -- add build.arg "ROS_DISTRO=jazzy"
make build           # rebuild with new ARG (only the affected layers, ~10s)
make run -- -t headless -d
```

The jazzy path aligns with Isaac's auto-default on 24.04 (LTS until 2029) — known caveat: jazzy on noble has a Python 3.11/3.12 mix and rough Nav2 paths still under NVIDIA forum tracking, expected smooth on Isaac Sim 6.0.

### Verify cross-container DDS

After `make run -- -t headless -d` (with the humble override env) and connecting via the WebRTC client, open Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run. The script auto-presses Play (publishers only fire while the timeline is playing) and starts publishing `std_msgs/String "hello N"` on `/isaac/test`.

From a separate terminal on the same host:

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic list &&
             ros2 topic echo /isaac/test --once'
```

Expected: `/isaac/test` appears in the topic list, and `echo` prints the hello message.

For the host → Isaac direction, run `ros2_test_sub.py` in Script Editor and pub from a sibling container:

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic pub /host/test std_msgs/String "{data: hello-from-host}" --once'
```

The kit terminal should print `[ros2_test_sub] /host/test <- 'hello-from-host'`.

> Swap both sides to `ros:jazzy` + `/opt/ros/jazzy/setup.bash` when running a jazzy-aligned Isaac instance — distros must match across both sides for IDL hashes to align.

### Standalone Python workflow (alternative to Script Editor)

`isaac_ws/src/script/` ships both in-kit Script Editor versions of M1 / M2 demos and standalone equivalents that boot their own kit via `SimulationApp({"livestream": 2})`. The standalone variant runs through `make run -- -t standalone` + `make exec -- -t standalone /isaac-sim/python.sh <script>` — Ctrl+C cleanly exits via SIGINT handler, no Script Editor UI needed.

| In-kit (Script Editor → File → Open → Run) | Standalone (`make exec -- -t standalone /isaac-sim/python.sh <path>`) |
|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py` |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py` |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py` |
| (no in-kit equivalent) | `cmd_vel_planar_standalone.py` — subscribes `/cmd_vel` (geometry_msgs/Twist) → OpenBase planar move |

Pattern:

```bash
make run -- -t standalone -d   # idle kit container (no runheadless ENTRYPOINT)
make exec -- -t standalone /isaac-sim/python.sh /home/yunchien/work/src/script/<name>_standalone.py
# Browser: localhost:8211/streaming/webrtc-client to view the stage
# Ctrl+C in the exec session kills the script cleanly; container stays idle
make stop                      # cleanup
```

`headless` and `standalone` stages cannot run simultaneously — both bind WebRTC port 8211. Pick one per session.

## Cache layout

All Isaac Sim runtime state persists under `${WS_PATH}/isaac-sim/` on the host (i.e. inside `isaac_ws/isaac-sim/`):

| Host | Container | Purpose |
|------|-----------|---------|
| `isaac-sim/kit/cache` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/kit/data` | `/isaac-sim/kit/data` | Kit app data (`user.config.json`, pipapi envs) |
| `isaac-sim/kit/logs` | `/isaac-sim/kit/logs` | Kit app logs |
| `isaac-sim/ov/cache` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache (shader build, mostly) |
| `isaac-sim/ov/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/ov/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/nvidia/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/nvidia/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents (USD scenes etc.) |

Pre-2026-05-21 layout (`cache/{kit,ov,pip,glcache,computecache}`, flat `logs/`, flat `data/`) is auto-migrated to the new namespaced paths by `./script/init_isaac_dirs.sh` on first run after upgrade (issue #21 fix-A). Pre-existing shader / pip / compute caches are preserved through the move.

First headless launch spends 1–3 min compiling shaders; subsequent launches start in `< 30s` thanks to the persisted caches.

## Container user

The container runs as a host-UID-aligned non-root user (`USER_NAME` from `.env`, UID 1000 by default). The user is added to the image's `isaac-sim` group so it can read `/isaac-sim/*` (mode `0750`). Files written through `/home/${USER_NAME}/work` (mounted to `${WS_PATH}` on the host) keep their host owner — no `chown` dance.

## EULA

`ACCEPT_EULA=Y` and `PRIVACY_CONSENT=Y` are injected via `setup.conf [environment]`. Note: Isaac Sim 5.1 reads privacy consent from `OMNI_ENV_PRIVACY_CONSENT` (different name from earlier versions); the `PRIVACY_CONSENT=Y` we currently set is harmless but has no effect — set explicitly if you want telemetry opt-in.

## Smoke Tests

See [doc/test/TEST.md](doc/test/TEST.md).
