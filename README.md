# isaac

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker development environment, built on top of [`ycpss91255-docker/template`](https://github.com/ycpss91255-docker/template).

Image scope is limited to Isaac Sim itself; ROS 2 bridges, downstream applications, and other layered tooling belong in sibling docker folders (e.g. `isaac-ros/`).

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
