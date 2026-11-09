# isaac

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

NVIDIA Isaac Sim 6.2.0 Docker development environment, built on top of [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base) (previously `ycpss91255-docker/template`).

Image scope covers Isaac Sim itself plus the env wiring needed for its bundled ROS 2 bridge to talk cross-container. NVIDIA Isaac Lab 3.0 (`v3.0.0`) is also baked in as the scene-spawn backend (`sim_utils` spawners, `UrdfConverter`, `AppLauncher`; ADR-0018). Downstream application nodes (CoreSAM, AGV bring-up) and the ROS 1 / ROS 2 bridge for Noetic interop live in sibling docker folders.

The repo also carries the Isaac Sim workspace content (driver scripts, ADRs, USD/URDF models) under [`src/`](src/README.md); the Dockerfile + base subtree at root is the development environment that runs that workspace. Both used to live in `ycpss91255-research/isaac` and `ycpss91255-docker/isaac` as a research-wraps-docker submodule pair, merged here per [#78](https://github.com/ycpss91255-docker/isaac/issues/78).

## Prerequisites

- NVIDIA driver `>= 580` (Isaac Lab 3.0 installs the CUDA 13 PyTorch build; NVIDIA tested Isaac Sim 6.2.0 on 595.58.03; verified here on driver 610)
- GPU `>= RTX 4080` (or equivalent), VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- ~50 GB free disk. The built image is ~31 GB, of which 20.7 GB is the NGC base image and ~10 GB is Isaac Lab and tooling; the other stages share those layers. Building needs headroom for the BuildKit cache, and the cache dirs grow another 5–10 GB after first launch

NGC image (`nvcr.io/nvidia/isaac-sim:6.2.0.1`, the 6.2.0 GA build -- see the `Dockerfile` `BASE_IMAGE` comment for why not `:6.2.0`) is publicly pullable — no `docker login nvcr.io` required.

## Quick Start

From a fresh clone, run these from the repo root:

```bash
./script/checkout_identity.sh isolate   # first time only — gives this checkout its own image tag + compose project
./script/init_isaac_dirs.sh             # first time only — runs ./script/setup.sh apply, creates the 10 host-owned cache dirs
just docker build                       # builds the devel stage (~31 GB image, see Prerequisites)
just docker run                         # interactive shell in the devel container
```

> The cache dirs must exist and be owned by you **before** a container mounts them. Otherwise the docker daemon creates them as **root**, and Kit cannot write its caches. It then cannot register the ROS 2 OmniGraph nodes (`[Errno 13] ... kit/cache/ogn_generated`), and it still exits 0. `init_isaac_dirs.sh` creates them, and the pre-run hook runs it again before every `just docker run`. If they are already root-owned, the script stops and prints a `chown` fix.

Production stages (both idle on startup — exec driver scripts into the running container):

```bash
just docker run -t headless -d                # pure sim, no streaming (ISAAC_LIVESTREAM=0)
just docker run -t stream -d         # sim + WebRTC streaming (ISAAC_LIVESTREAM=2)
just docker exec -t stream /isaac-sim/python.sh <script>   # run a driver script
```

> Two stages auto-emitted as profile-gated compose services per [base #215](https://github.com/ycpss91255-docker/base/issues/215): `headless` (pure sim, `ISAAC_LIVESTREAM=0`) and `stream` (sim + WebRTC, `ISAAC_LIVESTREAM=2`). Both idle on startup — the container stays up and you exec driver scripts in via `just docker exec -t <stage> <cmd>`. Use `just docker run -t <stage> -d` to launch.

### Headless: bring Isaac up and run a scene

The `example/` camera_bot scene runs headless, publishes a ROS 2 camera topic and subscribes to `/cmd_vel`. The container's working directory is the repo root (mounted at `~/work`), so script paths are repo-relative. This sequence was verified on Isaac Sim 6.2.0 (RTX 5090):

```bash
just docker build -t headless
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; EXAMPLE_TICK_BUDGET=100000 exec /isaac-sim/python.sh example/sim/example_driver.py'
# prints [CAMERA GRAPH OK] and [BOOT OK] in about 30 s

# In a second terminal: the camera topic, from a sibling ROS 2 container
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble bash -c \
  'source /opt/ros/humble/setup.bash && ros2 topic echo --once /camera_bot/camera/color/image_raw sensor_msgs/msg/Image --field header'
# frame_id: camera_bot_camera_color_optical_frame

just docker stop
```

Without `EXAMPLE_TICK_BUDGET`, the driver stops by itself after 1800 updates (about 2 minutes headless) and prints `[EXIT CLEAN]`. Kit writes its session log to `isaac-sim/kit/logs/Kit/<app>/<version>/kit_<timestamp>.log` on the host. To follow the newest one:

```bash
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"
```

`docker logs` on the container shows only its idle main process (`sleep infinity`), not the scripts you exec in.

> Commands with a quoted `bash -c '...'` go through `./script/exec.sh` instead of `just docker exec`. In base v0.42.0, the `just` recipe re-splits its arguments, so the quoted command and any `>` would run on the host. base fixed this in v0.43.0-rc5 (base PR #1298), and this repo still pins v0.42.0 (#297).

### Stopping a driver script

Ctrl+C in an interactive `just docker exec` reaches the script. Its SIGINT handler then shuts Kit down. But if the exec client is not a TTY, or if it is killed (a closed terminal, `timeout`, CI), the signal never reaches the script and **Kit keeps running** inside the container. To stop it reliably, record the PID when you start the script, as the example above does with `echo $$ > /tmp/isaac-driver.pid`. Then send SIGINT to that process's child, which is the Python that `python.sh` started:

```bash
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
```

Do not use a bare `pkill -f <script>`. The containers run with `pid: host`, so that pattern also matches processes on the host and in other containers. To stop everything instead, `just docker stop` removes this checkout's containers, and with them any Kit running inside.

### One image and one compose project per checkout

Every checkout of this repo on a host used to resolve the same image tag (`<hub>/isaac:<stage>`) and the same compose project (`<hub>-isaac`). `just docker build` then pruned the image another checkout had built, and `just docker stop` / `run` removed another checkout's containers (upstream: [base#1550](https://github.com/ycpss91255-docker/base/issues/1550), [base#1551](https://github.com/ycpss91255-docker/base/issues/1551), [base#1552](https://github.com/ycpss91255-docker/base/issues/1552)). Until base fixes that:

- `./script/checkout_identity.sh isolate` writes `[image] rule_1 = string:isaac-<dir>-<hash>` into the gitignored `.setup.conf.local`. The image tag, the compose project and the container names all follow it. `./script/checkout_identity.sh show` prints what this checkout resolves to.
- The pre build / run / stop hooks refuse to act on the shared names. `ISAAC_ALLOW_SHARED_IDENTITY=1` overrides that; CI's build steps use it.
- `just docker run` does not rebuild an image that already exists (base#1552). After pulling changes, run `just docker build -t <stage>` before `just docker run -t <stage>`.
- Containers started before isolating stay in the shared project. List them with `docker compose -p <hub>-isaac ps -a` and stop yours by name. `ISAAC_ALLOW_SHARED_IDENTITY=1 just docker stop` stops the whole shared project, other checkouts' containers included.

## Connecting to the WebRTC livestream

Isaac Sim 6.2.0 uses the NVCF (`omni.services.livestream.nvcf`) livestream protocol. Connect with the desktop client or a browser-based viewer:

1. Download the **Isaac Sim WebRTC Streaming Client** from [NVIDIA docs — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/6.2.0/installation/manual_livestream_clients.html). Use the client version NVIDIA lists there for your Isaac Sim release.
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
just docker run -t stream -d

# Launch Isaac Sim into the container -- an explicit step (run = infra,
# exec = workload). Either a driver script:
just docker exec -t stream /isaac-sim/python.sh <driver.py>
# ...or, for a no-driver quick stream, the livestream wrapper:
#   just docker exec -t stream /usr/local/bin/runheadless-host-config.sh

# Watch Isaac Sim load: Kit's session log on the host (docker logs only
# shows the container's idle main process)
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"

# Open Chrome -> http://<host-ip>:5173
# Boots straight into the live stream (stream-only auto-launch; no UI Option screen)

# Stop everything (the post-stop hook removes the web-viewer)
just docker stop
```

`config/host.yaml` is gitignored and per-machine. Its `network.public_ip` is mounted into both the Isaac container (read by `runheadless-host-config.sh` for the Kit `publicEndpointAddress` arg) and the web-viewer container (read by entrypoint for `SIGNALING_SERVER`).

The post-run hook also passes `network.public_ip` to the viewer container as `SIGNALING_SERVER` env -- defense in depth so the viewer still gets the right host IP if its locally cached image was built before `omniverse_web_viewer#12` (the entrypoint that reads `/etc/host.yaml`). Rebuild `owv:runtime` after the `web_viewer/` submodule pointer bumps to pick up newer entrypoint changes.

Requirements: Chrome or Chromium (Firefox incompatible). One interactive client per running Isaac Sim.

Notes:

- The streaming kit app simultaneously listens on `8011` (NVCF signaling, FastAPI/uvicorn), `49100` (self-host WebRTC), and `8211` (kit API / streaming viewer). The WebRTC Streaming Client picks the right one — leave the port off.
- **Only one client can connect at a time** (NVIDIA limitation). A second connection attempt is rejected.
- `network_mode: host` is set in `setup.conf`, so the container's listen port = host's listen port. Make sure the host firewall allows `8011/tcp` and `49100/tcp` (e.g. `sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`).
- `gpu_capabilities` in `setup.conf [deploy]` must include `video` — without it, nvidia-container-runtime does not mount NVENC libs (`libnvidia-encode.so`, `libnvcuvid.so`), so the server connects but cannot encode frames → black screen. The current `setup.conf` already includes `video`.
- Verify the listeners from the server: `ss -tln | grep -E ':8011|:49100'` should show both `LISTEN ... :8011` and `LISTEN ... :49100`.

### Deterministic stream-source producer (GHCR image, isaac#223)

For CI and the browser-based visual e2e ([`omniverse_web_viewer#48`](https://github.com/ycpss91255-docker/omniverse_web_viewer/issues/48), consumed by the Tier B browser-frames smoke isaac#173), a pullable, pinned producer image publishes a *guaranteed non-black* WebRTC source without a live desktop Isaac session. On boot it renders a deterministic empty-but-lit stage — a dome + distant key light over a 12×12 checkerboard floor, camera framed at `eye=[15,-15,11]` — and livestreams it forever, so a browser can connect at any time and always see a reproducible frame. The whole scene is authored programmatically (no external asset), so the image is self-contained.

- **Image**: `ghcr.io/ycpss91255-docker/isaac-stream-source:<tag>` (pinned, immutable tag — not `:latest`). Built from the `producer` Dockerfile stage.
- **Driver**: `src/script/stream_source_producer.py`, baked at `/opt/isaac-producer/stream_source_producer.py` and launched by the image `CMD`.
- **Publish**: manual only via the `Publish Stream-Source Producer (GHCR)` workflow (`workflow_dispatch`, input `tag`, default `0.0.1`). There is no push/tag trigger, so nothing publishes on merge.

Run it:

```bash
# --network=host so the container's WebRTC listen ports = host's.
# PUBLIC_IP is this host's LAN IP (what a remote browser dials);
# ISAAC_SIGNAL_PORT overrides the default signaling port (49100).
docker run --rm --network=host --gpus all \
  -e PUBLIC_IP=<host-lan-ip> \
  -e ISAAC_SIGNAL_PORT=49100 \
  ghcr.io/ycpss91255-docker/isaac-stream-source:0.0.2

# Then connect a browser / the omniverse_web_viewer to <host-lan-ip> (see above).
```

No producer image has been published from Isaac Sim 6.2.0 yet. The newest one is `0.0.2`, built on 6.0.1, so the table below ends there. Publishing is a manual `workflow_dispatch` of the publish workflow, and the table updates from the image's own label.

### Which Isaac Sim is in which image

The producer image version increments on its own; it does not encode the Isaac Sim version. To find out which Isaac Sim a given image was built on, ask the image.

<!-- producer-versions:start -->
| Tag | Isaac Sim | Source |
|---|---|---|
| `0.0.1` | 5.1.0 | declared (predates the label) |
| `0.0.2` | 6.0.1 | declared (predates the label) |

Generated by `script/ci/sync_producer_versions.py`; do not edit by hand.

The table is a convenience view. The authority is the image itself --
ask it directly when it matters:

```bash
docker inspect ghcr.io/ycpss91255-docker/isaac-stream-source:<tag> \
  --format '{{index .Config.Labels "org.opencontainers.image.base.name"}}'
```
<!-- producer-versions:end -->

Required: an NVIDIA GPU runtime (`--gpus all`) for NVENC frame encoding, `--network=host`, and `PUBLIC_IP` for a non-localhost client. `ISAAC_SIGNAL_PORT` is optional (defaults to `49100`). The driver also accepts `--public-ip` / `--port` / `--run-seconds N` (`N>0` bounds a smoke run; the default runs forever).

## ROS 2 bridge (bundled, build-time distro)

Isaac Sim 6.2.0 ships internal ROS 2 libraries for both Humble and Jazzy under `/isaac-sim/exts/isaacsim.ros2.core/{humble,jazzy}/` (in 5.1 this lived under `isaacsim.ros2.bridge/`; 6.0 split the monolithic bridge ext into `isaacsim.ros2.core` + `isaacsim.ros2.nodes` etc.), both with Python 3.12 rclpy matching kit's embedded interpreter. **This image hard-bakes the distro at build time** via `setup.conf [build] arg_N=ROS_DISTRO=<value>` (default `humble`, CoreSAM-aligned).

The bridge extension is enabled at Kit boot by the base `IsaacDriver` (`BOOT_EXTENSIONS` -> `--enable isaacsim.ros2.bridge` kit args), which is required for headless camera -> ROS 2 publish under Isaac Sim 6.x (isaac#248; re-checked on 6.2.0: a runtime enable still closes the app). No additional launch flag is needed on the driver path.

Env wiring shipped in `setup.conf [environment]` (distro-agnostic):

| Var | Value | Why |
|-----|-------|-----|
| `ROS_DOMAIN_ID` | `0` | small-team default; bump if multiple users share the host |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | explicit FastDDS, no inherit from host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile (cross-container DDS reliable, no SHM flakiness) |

### Distro choice (build-time, hard-baked)

`ARG ROS_DISTRO=humble` in the Dockerfile is wired to `setup.conf [build]`. At build time the value is written to `/etc/isaac/ros-distro`, and `script/isaac-ros-env-wrapper.sh` is installed at `/usr/local/bin/`. The `headless` and `stream` stages set `ENTRYPOINT` to that wrapper, which on every container start unconditionally re-exports `ROS_DISTRO` and `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.core/${ROS_DISTRO}/lib` from the baked file — runtime `-e ROS_DISTRO=...` flags are therefore ineffective on the production paths.

The `devel` stage soft-bakes the same values via `Dockerfile ENV` (interactive shells get them by default; devs can `export ROS_DISTRO=...` to experiment).

Switch to jazzy:

```bash
just docker setup remove build.arg "ROS_DISTRO=humble"
just docker setup add build.arg "ROS_DISTRO=jazzy"
just docker build           # rebuild with new ARG (only the affected layers, ~10s)
just docker run -t headless -d
```

The jazzy path aligns with Isaac's auto-default on 24.04 (LTS until 2029) — known caveat: jazzy on noble has a Python 3.11/3.12 mix and rough Nav2 paths still under NVIDIA forum tracking. The jazzy path has not been re-verified on Isaac Sim 6.2.0 in this repo; humble is the verified default.

### Verify cross-container DDS

After `just docker run -t stream -d` (with the humble override env) and connecting via the WebRTC client or browser viewer, open Script Editor → File → Open → `~/work/src/script/ros2_test_pub.py` (the repo's `src/script/`, as mounted in the container) → Run. The script auto-presses Play (publishers only fire while the timeline is playing) and starts publishing `std_msgs/String "hello N"` on `/isaac/test`.

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

`src/script/` ships in-kit Script Editor versions of the M1 / M2 demos and standalone equivalents. The standalone ones boot their own Kit through `SimulationApp`, following the stage's `ISAAC_LIVESTREAM` (`headless` 0, `stream` 2). `cmd_vel_planar_standalone.py` always runs Kit headless, because the livestream and the ROS 2 bridge in one standalone process have crashed Kit (IsaacSim#228). Each standalone script takes `--run-seconds N`, and it exits 1 on any error (it used to exit 0).

| In-kit (Script Editor → File → Open → Run) | Standalone (`just docker exec -t headless /isaac-sim/python.sh src/script/<name>`) | Verified on 6.2.0 (headless) |
|---|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py`: publishes `/isaac/test` once per second | `ros2 topic hz` 1.000 |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py`: prints each `/host/test` message | 3/3 received |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py`: fixed `CMD_VX/VY/WZ` planar move | x +0.5 m/s, z stays 0 |
| (no in-kit equivalent) | `cmd_vel_planar_standalone.py`: subscribes `/cmd_vel` (geometry_msgs/Twist) and moves the OpenBase in the plane | still at 0 command, x +0.5 m/s at `linear.x: 0.5`, z stays 0 |

Pattern:

```bash
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; exec /isaac-sim/python.sh src/script/<name>_standalone.py'
# stop it (see "Stopping a driver script"):
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
just docker stop                           # cleanup
```

A shared host can have other `/cmd_vel` publishers on ROS domain 0, and they move the OpenBase too. Give your run a private domain, for example `bash -c 'ROS_DOMAIN_ID=77 exec /isaac-sim/python.sh ...'`, with the same `-e ROS_DOMAIN_ID=77` on the sibling container.

## Cache layout

All Isaac Sim runtime state persists under `${WS_PATH}/isaac-sim/` on the host. `WS_PATH` resolves to the repo root, so this is `isaac-sim/` in your checkout. It is gitignored and kept out of the docker build context by `.dockerignore`:

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

Kit creates `isaac-sim/documents/Kit/shared/screenshots` with mode 000 when the directory does not exist yet. `init_isaac_dirs.sh` pre-creates it as 0755 and repairs a mode-000 one.

The containers report no health status (`HEALTHCHECK NONE`). The NGC base image's check greps a Kit log for `App is loaded`, but these containers idle with no Kit by design, so it marked every one of them `unhealthy`.

First headless launch spends 1–3 min compiling shaders; subsequent launches start in `< 30s` thanks to the persisted caches.

## Container user

The container runs as a host-UID-aligned non-root user (`USER_NAME` from `.env`, UID 1000 by default). The user is added to the image's `isaac-sim` group so it can read `/isaac-sim/*` (mode `0750`). Files written through `/home/${USER_NAME}/work` (mounted to `${WS_PATH}` on the host) keep their host owner — no `chown` dance.

## EULA

`ACCEPT_EULA=Y` and `PRIVACY_CONSENT=Y` are injected via `setup.conf [environment]`. Note: Isaac Sim 6.x reads privacy consent from `OMNI_ENV_PRIVACY_CONSENT` (the name adopted in 5.1, different from pre-5.1 versions); the `PRIVACY_CONSENT=Y` we currently set is harmless but has no effect — set explicitly if you want telemetry opt-in.

## Smoke Tests

See [doc/test/TEST.md](doc/test/TEST.md).

## Python testing toolkit (devel-test stage)

The `devel-test` stage ships `pytest`, `pyyaml`, and `pytest-cov` installed into Isaac Sim's bundled Python (`/isaac-sim/python.sh`), so consumer repos can run Python unit / integration tests inside the container. The runtime `devel` stage stays lean — the testing dependencies are only paid for in `devel-test`.

Usage:

```bash
just docker build -t devel-test                                     # build the devel-test stage
just docker exec -t devel-test /isaac-sim/python.sh -m pytest test/unit/
just docker exec -t devel-test /isaac-sim/python.sh -m pytest --cov=<pkg> test/
```

System `python3` cannot install these packages (PEP 668 blocks `pip` on the Isaac base image) — always invoke `/isaac-sim/python.sh -m pytest ...` instead of `pytest ...`.

GPU integration tests (Isaac Sim must boot, e.g. the camera → ROS 2 headless smoke, #127) run through the `test` compose service, which gets an NVIDIA GPU reservation from the `[stage:devel-test]` override in `setup.conf` (`deploy.gpu_mode = force`, base #493):

```bash
just docker run -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_camera_ros2_headless.py
```

Pass criterion is stdout marker lines (`[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]`), not the return code — Kit's `app.close` calls `_exit(0)`. See [doc/test/TEST.md](doc/test/TEST.md).
