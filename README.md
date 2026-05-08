# isaac

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker development environment, built on top of [`ycpss91255-docker/template`](https://github.com/ycpss91255-docker/template).

Image scope covers Isaac Sim itself plus the env wiring needed for its bundled ROS 2 bridge to talk cross-container. Downstream application nodes (CoreSAM, AGV bring-up) and the ROS 1 / ROS 2 bridge for Noetic interop live in sibling docker folders.

## Prerequisites

- NVIDIA driver `>= 580.65.06` (Isaac Sim 5.1 minimum)
- GPU `>= RTX 4080` (or equivalent), VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- ~20 GB free disk for the NGC image; cache dirs grow another 5–10 GB after first launch

NGC image (`nvcr.io/nvidia/isaac-sim:5.1.0`) is publicly pullable — no `docker login nvcr.io` required.

## Quick Start

> **First-time only:** run `./script/init_isaac_dirs.sh` **before** `./build.sh`. Skipping it lets the docker daemon `mkdir` the cache mount points as **root**, and the container's non-root user will then fail to write — Isaac Sim will not start.

```bash
./script/init_isaac_dirs.sh   # first time only — creates 8 host-owned cache dirs
./build.sh                    # builds devel stage (~16 GB image)
./run.sh                      # interactive shell in devel container
```

Inside the container:

```bash
/isaac-sim/runheadless.sh -v   # WebRTC livestream — connect with the Isaac Sim WebRTC Streaming Client (see below)
/isaac-sim/runapp.sh           # local GUI (requires X11; run `xhost +local:docker` on the host first)
```

> A `run.sh -t {headless|gui}` shortcut is in flight via [template issue #215](https://github.com/ycpss91255-docker/template/issues/215). Until that lands, use the manual launchers above.

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

## ROS 2 bridge (bundled, distro-agnostic)

Isaac Sim 5.1 ships internal ROS 2 libraries for both Humble and Jazzy under `/isaac-sim/exts/isaacsim.ros2.bridge/{humble,jazzy}/`, both with Python 3.11 rclpy matching kit's embedded interpreter. **This image keeps the distro choice open** — `ROS_DISTRO` and `LD_LIBRARY_PATH` are deliberately not set in `setup.conf`, letting Isaac's `/isaac-sim/setup_ros_env.sh` auto-detect at startup:

| Image Ubuntu | Auto distro |
|---|---|
| 22.04 (jammy) | humble |
| 24.04 (noble) — this image | **jazzy** |

The bridge extension `isaacsim.ros2.bridge` auto-loads via the default kit experience (`isaacsim.exp.full.kit` → `isaac.startup.ros_bridge_extension`). No `--enable` launch flag needed in `runheadless.sh` / `runapp.sh`.

Env wiring shipped in `setup.conf [environment]`:

| Var | Value | Why |
|-----|-------|-----|
| `ROS_DOMAIN_ID` | `0` | small-team default; bump if multiple users share the host |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | explicit FastDDS, no inherit from host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile (cross-container DDS reliable, no SHM flakiness) |

### Pin to humble at compose run time (CoreSAM-aligned)

Most downstream stacks (CoreSAM, `ros1_bridge` Noetic↔Humble, this org's `*_humble` driver repos) target Humble. Override Isaac's 24.04 jazzy auto-default by passing both env vars together at compose run time:

```bash
docker compose -p yunchien-isaac up -d \
    -e ROS_DISTRO=humble \
    -e LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/humble/lib \
    headless
```

Both are required together — `setup_ros_env.sh` wraps the lib-path update inside `if [ -z "$ROS_DISTRO" ]`, so once `ROS_DISTRO` is set the helper skips priming `LD_LIBRARY_PATH`. Same pattern with `jazzy` substituted is the alternative path for stacks that want to ride Isaac's auto-default (LTS until 2029, native 24.04) — known caveat: jazzy on noble has a Python 3.11/3.12 mix and rough Nav2 paths still under NVIDIA forum tracking, expected smooth on Isaac Sim 6.0.

### Verify cross-container DDS

After `./run.sh -t headless -d` (with the humble override env) and connecting via the WebRTC client, open Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run. The script auto-presses Play (publishers only fire while the timeline is playing) and starts publishing `std_msgs/String "hello N"` on `/isaac/test`.

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

## Cache layout

All Isaac Sim runtime state persists under `${WS_PATH}/isaac-sim/` on the host (i.e. inside `isaac_ws/isaac-sim/`):

| Host | Container | Purpose |
|------|-----------|---------|
| `isaac-sim/cache/kit` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/cache/ov` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache (shader build, mostly) |
| `isaac-sim/cache/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/cache/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/cache/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents (USD scenes etc.) |

First headless launch spends 1–3 min compiling shaders; subsequent launches start in `< 30s` thanks to the persisted caches.

## Container user

The container runs as a host-UID-aligned non-root user (`USER_NAME` from `.env`, UID 1000 by default). The user is added to the image's `isaac-sim` group so it can read `/isaac-sim/*` (mode `0750`). Files written through `/home/${USER_NAME}/work` (mounted to `${WS_PATH}` on the host) keep their host owner — no `chown` dance.

## EULA

`ACCEPT_EULA=Y` and `PRIVACY_CONSENT=Y` are injected via `setup.conf [environment]`. Note: Isaac Sim 5.1 reads privacy consent from `OMNI_ENV_PRIVACY_CONSENT` (different name from earlier versions); the `PRIVACY_CONSENT=Y` we currently set is harmless but has no effect — set explicitly if you want telemetry opt-in.

## Smoke Tests

See [doc/test/TEST.md](doc/test/TEST.md).
