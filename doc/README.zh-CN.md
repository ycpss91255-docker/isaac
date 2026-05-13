# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 开发环境，以 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（前身为 `ycpss91255-docker/template`）为基础构建。

Image scope 涵盖 Isaac Sim 本体，加上让其内建 ROS 2 bridge 跨容器通讯所需的 env wiring。下游应用节点（CoreSAM、AGV bring-up）以及给 Noetic interop 用的 ROS 1 / ROS 2 bridge 放在相邻的 docker folder。

## 前置需求

- NVIDIA driver `>= 580.65.06`（Isaac Sim 5.1 最低需求）
- GPU `>= RTX 4080`（或同级），VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- 约 20 GB 空闲空间给 NGC image；首次启动后 cache 再增长 5–10 GB

NGC image（`nvcr.io/nvidia/isaac-sim:5.1.0`）公开可拉，无需 `docker login nvcr.io`。

## Quick Start

> **首次必跑：** `./build.sh` **之前**先跑 `./script/init_isaac_dirs.sh`。没跑的话 docker daemon 会以 **root** 身份 mkdir cache mount 点，导致容器内非 root user 无法写入，Isaac Sim 启动失败。

```bash
./script/init_isaac_dirs.sh   # 首次必跑，创建 8 个 host-owned cache 目录
./build.sh                    # build devel stage（约 16 GB image）
./run.sh                      # 进 devel 容器互动 shell
```

容器内：

```bash
/isaac-sim/runheadless.sh -v   # WebRTC livestream — 用 Isaac Sim WebRTC Streaming Client 连（见下）
/isaac-sim/runapp.sh           # 本机 GUI（需要 X11；host 端先跑 `xhost +local:docker`）
```

> `run.sh -t {headless|gui}` 快捷功能在 [base issue #215](https://github.com/ycpss91255-docker/base/issues/215) 推进中。落地前先用上述手动 launcher。

## 连接 WebRTC livestream

Isaac Sim 5.1 用 NVCF（`omni.services.livestream.nvcf`）livestream 协议，**旧版的浏览器 viewer 已移除**，只能用桌面 client 连：

1. 从 [NVIDIA 文档 — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html) 下载 **Isaac Sim WebRTC Streaming Client (1.1.5)**。1.1.5 是 5.1 的最新版。
2. 容器内 `runheadless.sh -v` 运行时，启动 client，输入 Server: `<server-ip>`（同机用 `localhost`，远端用 server 的 LAN IP）。**不要加 `:8011` 或任何 port 后缀** — client 自己会选 signaling / data port；加 port 后缀会走错 path、看到黑画面。
3. 按 Connect。首次 shader compile 需 1–3 分钟 viewport 才会出画面。

注意：

- streaming kit app 同时 listen 在 `8011`（NVCF signaling，FastAPI/uvicorn）跟 `49100`（self-host WebRTC）。1.1.5 client 会自己选对的，**不要写 port**
- **同时只能一个 client 连**（NVIDIA 限制）。第二个连接会被拒绝
- `setup.conf` 已开 `network_mode: host`，容器内 listen 的 port = host 的 port。Host 防火墙要放行 `8011/tcp` 跟 `49100/tcp`（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` 必须含 `video` — 否则 nvidia-container-runtime 不 mount NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`），server 连得上但画面 encode 不出来 → 黑画面。当前 `setup.conf` 已加
- Server 端确认 listener：`ss -tln | grep -E ':8011|:49100'` 应看到两个 `LISTEN`

## ROS 2 bridge（内置，build-time distro）

Isaac Sim 5.1 在 `/isaac-sim/exts/isaacsim.ros2.bridge/{humble,jazzy}/` 内置 Humble 与 Jazzy 两套 ROS 2 lib，两者都是 Python 3.11 rclpy，与 kit 内嵌 interpreter 对齐。**本 image 在 build time 把 distro hard-bake 进去** — 透过 `setup.conf [build] arg_N=ROS_DISTRO=<value>` 注入（默认 `humble`，与 CoreSAM 对齐）。

`isaacsim.ros2.bridge` extension 透过预设 kit experience（`isaacsim.exp.full.kit` → `isaac.startup.ros_bridge_extension`）自动 load，`runheadless.sh` / `runapp.sh` 不需要加 `--enable` flag。

Env wiring 写在 `setup.conf [environment]`（distro-agnostic）：

| 变量 | 值 | 原因 |
|-----|-------|-----|
| `ROS_DOMAIN_ID` | `0` | small-team default; bump if multiple users share the host |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | explicit FastDDS, no inherit from host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile (cross-container DDS reliable, no SHM flakiness) |

### Distro 选择（build-time、hard-baked）

Dockerfile 内 `ARG ROS_DISTRO=humble`，由 `setup.conf [build]` 串进来。Build time 时该值写入 `/etc/isaac/ros-distro`，并把 `script/isaac-ros-env-wrapper.sh` 装到 `/usr/local/bin/`。`headless` / `gui` stage 把 `ENTRYPOINT` 设成该 wrapper，每次 container 起来都从 baked file 无条件 re-export `ROS_DISTRO` 与 `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` — 因此 production path 上 runtime 的 `-e ROS_DISTRO=...` flag 不会生效。

`devel` stage 透过 Dockerfile `ENV` 做 soft-bake（互动 shell 默认带这两个值；developer 可 `export ROS_DISTRO=...` 临时实验）。

切到 jazzy：

```bash
./setup.sh remove build.arg "ROS_DISTRO=humble"
./setup.sh add build.arg "ROS_DISTRO=jazzy"
./build.sh           # 用新 ARG 重 build（只重 build 受影响 layer，~10s）
./run.sh -t headless -d
```

jazzy path 与 Isaac 在 24.04 上的 auto-default 对齐（LTS until 2029）— 已知坑：jazzy on noble 有 Python 3.11/3.12 混用与 Nav2 path 粗糙问题，仍在 NVIDIA 论坛追踪中，预期 Isaac Sim 6.0 修平。

### 验证 cross-container DDS

跑 `./run.sh -t headless -d`（已带 humble override env）并用 WebRTC client 连上后，开 Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run。脚本会自动按 Play（publisher 只在 timeline 播放时触发），开始在 `/isaac/test` 发布 `std_msgs/String "hello N"`。

在同一 host 另一个 terminal：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic list &&
             ros2 topic echo /isaac/test --once'
```

预期：topic list 出现 `/isaac/test`，`echo` 印出 hello 讯息。

反向（host → Isaac）：在 Script Editor 跑 `ros2_test_sub.py`，从相邻容器 pub：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic pub /host/test std_msgs/String "{data: hello-from-host}" --once'
```

kit terminal 应印出 `[ros2_test_sub] /host/test <- 'hello-from-host'`。

> 跑 jazzy-aligned Isaac instance 时把两边都换成 `ros:jazzy` + `/opt/ros/jazzy/setup.bash` — 两边 distro 必须一致，IDL hash 才能对齐。

## Cache 路径

所有 Isaac Sim runtime state 都持久化在 host 端的 `${WS_PATH}/isaac-sim/`（即 `isaac_ws/isaac-sim/`）：

| Host | Container | 用途 |
|------|-----------|------|
| `isaac-sim/cache/kit` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/cache/ov` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache（主要是 shader 编译产物）|
| `isaac-sim/cache/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/cache/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/cache/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents（USD scenes 等）|

首次 headless 启动需 1–3 分钟编译 shader；之后启动 cache hit `< 30 秒`。

## 容器 User

容器以对齐 host UID 的非 root user 跑（`USER_NAME` 从 `.env` 读取，默认 UID 1000）。该 user 被加进 image 的 `isaac-sim` group，可读取 `/isaac-sim/*`（mode `0750`）。通过 `/home/${USER_NAME}/work`（mount 到 host `${WS_PATH}`）写的文件保留 host 端 owner，无需 `chown`。

## EULA

`ACCEPT_EULA=Y` 与 `PRIVACY_CONSENT=Y` 通过 `setup.conf [environment]` 注入。注意：Isaac Sim 5.1 改用 `OMNI_ENV_PRIVACY_CONSENT` 读取 privacy consent（环境变量名称跟旧版不同）；目前设的 `PRIVACY_CONSENT=Y` 无害但实际无作用，要 telemetry opt-in 请另设正确的变量。

## Smoke Tests

详见 [doc/test/TEST.md](test/TEST.md)。
