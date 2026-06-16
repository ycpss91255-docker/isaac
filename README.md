# isaac

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker development environment, built on top of [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) (previously `ycpss91255-docker/template`).

Image scope covers Isaac Sim itself plus the env wiring needed for its bundled ROS 2 bridge to talk cross-container. NVIDIA Isaac Lab 2.3 is also baked in as the scene-spawn backend (`sim_utils` spawners, `UrdfConverter`, `AppLauncher`; ADR-0018). Downstream application nodes (CoreSAM, AGV bring-up) and the ROS 1 / ROS 2 bridge for Noetic interop live in sibling docker folders.

The repo also carries the Isaac Sim workspace content (driver scripts, ADRs, USD/URDF models) under [`src/`](src/README.md); the Dockerfile + base subtree at root is the development environment that runs that workspace. Both used to live in `ycpss91255-research/isaac` and `ycpss91255-docker/isaac` as a research-wraps-docker submodule pair, merged here per [#78](https://github.com/ycpss91255-docker/isaac/issues/78).

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

Production stages (both idle on startup — exec driver scripts into the running container):

```bash
make run -- -t headless -d                # pure sim, no streaming (ISAAC_LIVESTREAM=0)
make run -- -t stream -d         # sim + WebRTC streaming (ISAAC_LIVESTREAM=2)
make exec -- -t stream /isaac-sim/python.sh <script>   # run a driver script
```

> Two stages auto-emitted as profile-gated compose services per [base #215](https://github.com/ycpss91255-docker/base/issues/215): `headless` (pure sim, `ISAAC_LIVESTREAM=0`) and `stream` (sim + WebRTC, `ISAAC_LIVESTREAM=2`). Both idle on startup — the container stays up and you exec driver scripts in via `make exec -- -t <stage> <cmd>`. Use `make run -- -t <stage> -d` to launch.

## Connecting to the WebRTC livestream

Isaac Sim 5.1 uses the NVCF (`omni.services.livestream.nvcf`) livestream protocol. Connect with the desktop client or a browser-based viewer:

1. Download the **Isaac Sim WebRTC Streaming Client (1.1.5)** from [NVIDIA docs — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html). 1.1.5 is the latest, ships with 5.1.
2. While `stream` is running, launch the client and enter Server: `<server-ip>` (use `localhost` for same-machine, the server's LAN IP otherwise). **Do not add `:8011` or any port suffix** — the client manages signaling/data ports internally; appending a port routes through the wrong path and yields a black screen.
3. Click Connect. First-time shader compile takes 1–3 min before the viewport renders.

### Browser-based viewer (omniverse_web_viewer)

The [`omniverse_web_viewer`](https://github.com/ycpss91255-docker/omniverse_web_viewer) repo provides a browser-based client as a sidecar container. Bundled as a submodule at `web_viewer/` in this repo.

```bash
# First time: init submodules + create per-host config
git submodule update --init --recursive web_viewer
cp config/host.yaml.example config/host.yaml
# Edit config/host.yaml: set network.public_ip to this host's LAN IP

# Bring up the idle stream container + host.yaml + web-viewer.
# The post-run hook (base #440) copies host.yaml in and starts the viewer.
make run -- -t stream -d
# (multi-instance: append --instance <name>; see Multi-Instance below)

# Launch Isaac Sim into the container -- an explicit step (run = infra,
# exec = workload). Either a driver script:
make exec -- -t stream /isaac-sim/python.sh <driver.py>
# ...or, for a no-driver quick stream, the livestream wrapper:
#   make exec -- -t stream /usr/local/bin/runheadless-host-config.sh

# Watch Isaac Sim load
docker logs -f $(. .env && echo "${USER_NAME}-${IMAGE_NAME}-stream")

# Open Chrome -> http://<host-ip>:5173
# Boots straight into the live stream (stream-only auto-launch; no UI Option screen)

# Stop everything (the post-stop hook removes the web-viewer)
make stop
```

`config/host.yaml` is gitignored and per-machine. Its `network.public_ip` is mounted into both the Isaac container (read by `runheadless-host-config.sh` for the Kit `publicEndpointAddress` arg) and the web-viewer container (read by entrypoint for `SIGNALING_SERVER`).

For multi-instance, `./run.sh --instance <name>` loads `config/instances/<name>.{yaml,env}` as a compose overlay (base #465) and the post-run hook starts a paired web-viewer per instance (see [Multi-Instance](#multi-instance) below). The hook also passes `network.public_ip` to the viewer container as `SIGNALING_SERVER` env -- defense in depth so the viewer still gets the right host IP if its locally cached image was built before `omniverse_web_viewer#12` (the entrypoint that reads `/etc/host.yaml`). Rebuild `owv:runtime` after the `web_viewer/` submodule pointer bumps to pick up newer entrypoint changes.

Requirements: Chrome or Chromium (Firefox incompatible). One interactive client per Isaac Sim instance.

Notes:

- The streaming kit app simultaneously listens on `8011` (NVCF signaling, FastAPI/uvicorn), `49100` (self-host WebRTC), and `8211` (kit API / streaming viewer). The 1.1.5 client picks the right one — leave the port off.
- **Only one client can connect at a time** (NVIDIA limitation). A second connection attempt is rejected.
- `network_mode: host` is set in `setup.conf`, so the container's listen port = host's listen port. Make sure the host firewall allows `8011/tcp` and `49100/tcp` (e.g. `sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`).
- `gpu_capabilities` in `setup.conf [deploy]` must include `video` — without it, nvidia-container-runtime does not mount NVENC libs (`libnvidia-encode.so`, `libnvcuvid.so`), so the server connects but cannot encode frames → black screen. The current `setup.conf` already includes `video`.
- Verify the listeners from the server: `ss -tln | grep -E ':8011|:49100'` should show both `LISTEN ... :8011` and `LISTEN ... :49100`.

## ROS 2 bridge (bundled, build-time distro)

Isaac Sim 5.1 ships internal ROS 2 libraries for both Humble and Jazzy under `/isaac-sim/exts/isaacsim.ros2.bridge/{humble,jazzy}/`, both with Python 3.11 rclpy matching kit's embedded interpreter. **This image hard-bakes the distro at build time** via `setup.conf [build] arg_N=ROS_DISTRO=<value>` (default `humble`, CoreSAM-aligned).

The bridge extension `isaacsim.ros2.bridge` auto-loads via the default kit experience (`isaacsim.exp.full.kit` → `isaac.startup.ros_bridge_extension`). No additional launch flag needed.

Env wiring shipped in `setup.conf [environment]` (distro-agnostic):

| Var | Value | Why |
|-----|-------|-----|
| `ROS_DOMAIN_ID` | `0` | small-team default; bump if multiple users share the host |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | explicit FastDDS, no inherit from host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile (cross-container DDS reliable, no SHM flakiness) |

### Distro choice (build-time, hard-baked)

`ARG ROS_DISTRO=humble` in the Dockerfile is wired to `setup.conf [build]`. At build time the value is written to `/etc/isaac/ros-distro`, and `script/isaac-ros-env-wrapper.sh` is installed at `/usr/local/bin/`. The `headless` and `stream` stages set `ENTRYPOINT` to that wrapper, which on every container start unconditionally re-exports `ROS_DISTRO` and `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` from the baked file — runtime `-e ROS_DISTRO=...` flags are therefore ineffective on the production paths.

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

After `make run -- -t stream -d` (with the humble override env) and connecting via the WebRTC client or browser viewer, open Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run. The script auto-presses Play (publishers only fire while the timeline is playing) and starts publishing `std_msgs/String "hello N"` on `/isaac/test`.

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

`isaac_ws/src/script/` ships both in-kit Script Editor versions of M1 / M2 demos and standalone equivalents that boot their own kit via `SimulationApp({"livestream": 2})`. Both `headless` and `stream` stages idle on startup, so standalone scripts are exec'd into the running container — Ctrl+C cleanly exits via SIGINT handler, no Script Editor UI needed.

| In-kit (Script Editor → File → Open → Run) | Standalone (`make exec -- -t stream /isaac-sim/python.sh <path>`) |
|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py` |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py` |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py` |
| (no in-kit equivalent) | `cmd_vel_planar_standalone.py` — subscribes `/cmd_vel` (geometry_msgs/Twist) → OpenBase planar move |

Pattern:

```bash
make run -- -t stream -d   # idle container with WebRTC streaming enabled
make exec -- -t stream /isaac-sim/python.sh /home/yunchien/work/src/script/<name>_standalone.py
# Connect via WebRTC client or browser viewer to see the stage
# Ctrl+C in the exec session kills the script cleanly; container stays idle
make stop                           # cleanup
```

## Multi-Instance

Multiple Isaac Sim instances can run on the same GPU. Each instance gets isolated ports and cache directories to avoid conflicts.

### Prerequisites

- Same GPU shared across instances (VRAM must accommodate all running sims)
- `pid=host` in `setup.conf` (required for GPU process visibility)
- Staggered startup — wait for each instance to report "is loaded" before starting the next
- Each instance MUST have isolated cache dirs (sharing causes corruption)

### Usage

```bash
# Author per-instance overlays from the committed template (ports + cache).
# These live in config/instances/<name>.{yaml,env} (base #465 convention)
# and are gitignored except the example template.
cp config/instances/example.env  config/instances/warehouse.env
cp config/instances/example.yaml config/instances/warehouse.yaml
# edit warehouse.env: bump the ports for a second concurrent instance

# Start instances (stagger — wait for "is loaded" between launches).
# The pre-run hook creates the cache tree; the post-run hook copies
# host.yaml in and starts the per-instance web-viewer.
./run.sh -t stream -d --instance warehouse
# ... wait for "is loaded" ...
./run.sh -t stream -d --instance factory

# Launch Isaac Sim into a specific instance (container is
# ${USER_NAME}-isaac-stream-<name>):
./exec.sh -t stream --instance warehouse /isaac-sim/python.sh <script>

# Tear down (the post-stop hook also removes the per-instance web-viewer)
./stop.sh --instance warehouse
./stop.sh --instance factory
```

### Port layout

Each instance is assigned a unique set of ports, hand-authored in `config/instances/<name>.env` (copy from `example.env`):

| Port | Purpose | Instance 1 (default) | Instance 2 | Step |
|------|---------|---------------------|------------|------|
| Signal | NVCF livestream signaling (`--/app/livestream/port`) | 49100 | 49200 | +100 |
| Media | WebRTC media (`--/app/livestream/fixedHostPort`) | 47998 | 48098 | +100 |
| API | Kit HTTP API (`--/exts/omni.services.transport.server.http/port`) | 8011 | 8012 | +1 |
| Viewer | omniverse_web_viewer (`SERVE_PORT`) | 5173 | 5174 | +1 |

`config/instances/example.env` ships the default-instance values with the per-instance offsets documented inline. There is no auto-assignment generator: copy the template and bump the ports by their step for each concurrent instance. The overlay `<name>.yaml` feeds the ports into the container env (so `runheadless-host-config.sh` builds the matching Kit args) and remaps the cache mounts.

### Cache isolation

Each instance stores runtime state under its `INSTANCE_CACHE_DIR` (default `instance/<name>`, relative to the docker repo root) instead of the shared default paths. The pre-run hook (`script/hooks/pre/run.sh`) creates this directory tree automatically on `run.sh --instance <name>`. **Instances MUST NOT share cache directories** — concurrent writes to the same shader cache or kit data directory cause corruption and crashes.

### Connecting

Pair each instance with its own `omniverse_web_viewer` pointed at that instance's signal port, or use the native WebRTC client (one client per instance).

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

Multi-instance setups use per-instance cache directories at each instance's `INSTANCE_CACHE_DIR` (default `instance/<name>`, mirroring the same subdirectory structure above). These are created by the pre-run hook (`script/hooks/pre/run.sh`) and must not overlap with the shared default paths or with other instances.

First headless launch spends 1–3 min compiling shaders; subsequent launches start in `< 30s` thanks to the persisted caches.

## Container user

The container runs as a host-UID-aligned non-root user (`USER_NAME` from `.env`, UID 1000 by default). The user is added to the image's `isaac-sim` group so it can read `/isaac-sim/*` (mode `0750`). Files written through `/home/${USER_NAME}/work` (mounted to `${WS_PATH}` on the host) keep their host owner — no `chown` dance.

## EULA

`ACCEPT_EULA=Y` and `PRIVACY_CONSENT=Y` are injected via `setup.conf [environment]`. Note: Isaac Sim 5.1 reads privacy consent from `OMNI_ENV_PRIVACY_CONSENT` (different name from earlier versions); the `PRIVACY_CONSENT=Y` we currently set is harmless but has no effect — set explicitly if you want telemetry opt-in.

## Smoke Tests

See [doc/test/TEST.md](doc/test/TEST.md).

## Python testing toolkit (devel-test stage)

The `devel-test` stage ships `pytest`, `pyyaml`, and `pytest-cov` installed into Isaac Sim's bundled Python (`/isaac-sim/python.sh`), so consumer repos can run Python unit / integration tests inside the container. The runtime `devel` stage stays lean — the testing dependencies are only paid for in `devel-test`.

Usage:

```bash
make build -- -t devel-test                                     # build the devel-test stage
make exec -- -t devel-test /isaac-sim/python.sh -m pytest test/unit/
make exec -- -t devel-test /isaac-sim/python.sh -m pytest --cov=<pkg> test/
```

System `python3` cannot install these packages (PEP 668 blocks `pip` on the Isaac base image) — always invoke `/isaac-sim/python.sh -m pytest ...` instead of `pytest ...`.

GPU integration tests (Isaac Sim must boot, e.g. the camera → ROS 2 headless smoke, #127) run through the `test` compose service, which gets an NVIDIA GPU reservation from the `[stage:devel-test]` override in `setup.conf` (`deploy.gpu_mode = force`, base #493):

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_camera_ros2_headless.py
```

Pass criterion is stdout marker lines (`[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]`), not the return code — Kit's `app.close` calls `_exit(0)`. See [doc/test/TEST.md](doc/test/TEST.md).
