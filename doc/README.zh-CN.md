# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 6.2.0 Docker 开发环境，以 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（前身为 `ycpss91255-docker/template`）为基础构建。

Image scope 涵盖 Isaac Sim 本体，加上让其内建 ROS 2 bridge 跨容器通讯所需的 env wiring。NVIDIA Isaac Lab 3.0（`v3.0.0`）也一并 baked 进 image，作为 scene-spawn backend（`sim_utils` spawner、`UrdfConverter`、`AppLauncher`；ADR-0018）。下游应用节点（CoreSAM、AGV bring-up）以及给 Noetic interop 用的 ROS 1 / ROS 2 bridge 放在相邻的 docker folder。

本 repo 同时收纳 Isaac Sim workspace 内容（driver script、ADR、USD / URDF 模型）于 [`src/`](../src/README.md)；root 的 Dockerfile + base subtree 是运行该 workspace 的开发环境。两者原本分属 `ycpss91255-research/isaac` 与 `ycpss91255-docker/isaac`（research wraps docker via submodule），按 [#78](https://github.com/ycpss91255-docker/isaac/issues/78) 合并至此。

## 前置需求

- NVIDIA driver `>= 580`（Isaac Lab 3.0 会装 CUDA 13 版 PyTorch；NVIDIA 以 595.58.03 测过 Isaac Sim 6.2.0；本 repo 已在 driver 610 验证）
- GPU `>= RTX 4080`（或同级），VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- 约 50 GB 空闲空间。build 出来的 image 约 31 GB，其中 20.7 GB 是 NGC base image，约 10 GB 是 Isaac Lab 与工具链；其他 stage 共用这些 layer。build 时还需要预留 BuildKit cache 的空间，首次启动后 cache 目录再增长 5–10 GB

NGC image（`nvcr.io/nvidia/isaac-sim:6.2.0.1`，即 6.2.0 GA build；为何不用 `:6.2.0` 见 `Dockerfile` `BASE_IMAGE` 注释）公开可拉，无需 `docker login nvcr.io`。

## Quick Start

从刚 clone 下来的 repo 开始，先在 repo root 跑这两个首次步骤：

```bash
./script/checkout_identity.sh isolate   # 首次必跑，让这个 checkout 有自己的 image tag 与 compose project
./script/init_isaac_dirs.sh             # 首次必跑，会执行 ./script/setup.sh apply，并建好 10 个 host-owned cache 目录
```

> cache 目录必须在容器 mount 之**前**就存在且 owner 是你。否则 docker daemon 会以 **root** 身份创建它们，Kit 就无法写入自己的 cache，进而无法注册 ROS 2 OmniGraph node（`[Errno 13] ... kit/cache/ogn_generated`），而且照样 exit 0。`init_isaac_dirs.sh` 负责创建这些目录，pre-run hook 也会在每次 `just docker run` 之前再跑一次。如果目录已经是 root 所有，脚本会停下来并打印 `chown` 修复指令。

接着**只选一条**路径。各 stage 相互独立：只 build 你要跑的那个 stage。走 headless 路径之前**不需要**先 build devel。

| 你想要 | Build | Run |
|---|---|---|
| 跑一个场景并看它的 ROS 2 topic（建议从这里开始） | `just docker build -t headless` | `just docker run -t headless -d`，接着看下方「Headless：启动 Isaac 并跑一个场景」 |
| 一个用来开发的交互 shell | `just docker build`（devel） | `just docker run` |
| 通过 WebRTC 看仿真画面 | `just docker build -t stream` | `just docker run -t stream -d`，接着看「连接 WebRTC livestream」 |

冷启动的第一次 build 大约要一小时：先 pull 20.7 GB 的 NGC base image，再安装 Isaac Lab。GitHub-hosted CI 的 build 花了 45 到 84 分钟（[45 分](https://github.com/ycpss91255-docker/isaac/actions/runs/42550974606/job/128946327237)、[58 分](https://github.com/ycpss91255-docker/isaac/actions/runs/42545601510/job/128929863953)、[84 分](https://github.com/ycpss91255-docker/isaac/actions/runs/42491566385/job/128764928999)）。之后的 build 会复用 layer cache，其他 stage 也共用这些 layer，所以 build 第二个 stage 只要几秒到几分钟。

Production stage（两个 stage 启动后都 idle — driver 脚本用 exec 送进运行中的 container）：

```bash
just docker run -t headless -d                             # pure sim, no streaming (ISAAC_LIVESTREAM=0)
just docker run -t stream -d                               # sim + WebRTC streaming (ISAAC_LIVESTREAM=2)
just docker exec -t stream /isaac-sim/python.sh <script>   # run a driver script
```

> 两个 stage 透过 [base #215](https://github.com/ycpss91255-docker/base/issues/215) auto-emit 为 profile-gated compose service：`headless`（pure sim，`ISAAC_LIVESTREAM=0`）、`stream`（sim + WebRTC，`ISAAC_LIVESTREAM=2`）。两者启动后都 `CMD ["sleep","infinity"]` idle（没有 `runheadless.sh -v` ENTRYPOINT）— container 持续存活，由你用 `just docker exec -t <stage> <cmd>` 把 driver 脚本（`/isaac-sim/python.sh <driver.py>`，读 `ISAAC_LIVESTREAM=2` 开 stream）或一次性 `/usr/local/bin/runheadless-host-config.sh` 送进去；streaming 起来后 web-viewer 连 `:5173`。使用 `just docker run -t <stage> -d` 启动。

### Headless：启动 Isaac 并跑一个场景

`example/` 的 camera_bot 场景以 headless 运行，发布一个 ROS 2 camera topic 并订阅 `/cmd_vel`。容器的工作目录是 repo root（mount 在 `~/work`），所以脚本路径都相对于 repo。以下流程已在 Isaac Sim 6.2.0（RTX 5090）验证：

```bash
just docker build -t headless
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; ROS_DOMAIN_ID=77 EXAMPLE_TICK_BUDGET=100000 exec /isaac-sim/python.sh example/sim/example_driver.py'
# prints [CAMERA GRAPH OK] and [BOOT OK] in about 30 s

# In a second terminal: the camera topic, from a sibling ROS 2 container on the same domain
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=77 ros:humble bash -c \
  'source /opt/ros/humble/setup.bash && ros2 topic echo --once /camera_bot/camera/color/image_raw sensor_msgs/msg/Image --field header'
# frame_id: camera_bot_camera_color_optical_frame

just docker stop
```

示例刻意跑在私有 ROS domain（`77`）上。共用的 host 可能有其他 `/cmd_vel` publisher 在默认的 domain 0，它们也会驱动这台机器人。任选一个没人用的 domain（0 到 101），两端用同一个 `ROS_DOMAIN_ID`。

**第一次启动时，camera topic 大约会在 `[BOOT OK]` 之后 2 分钟才出现。** camera publisher 要等第一个 frame render 完才会出现，而 cache 为空时 renderer 要先编译 shader。在一次冷启动中，topic 在 `[BOOT OK]` 之后 1 分 52 秒出现，`ros2 topic echo --once` 再过 2 秒返回。用那次留下的 cache 再跑，topic 在 `[BOOT OK]` 之后 3 秒内就在。等待的不是 DDS discovery：Isaac 在发布时，新开的 sibling container 立刻就能看到 topic。想要看它何时出现、而不是干等 `echo`：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=77 ros:humble bash -c \
  'source /opt/ros/humble/setup.bash &&
   until ros2 topic list | grep -q image_raw; do sleep 1; done &&
   ros2 topic hz /camera_bot/camera/color/image_raw'
# average rate: ~30
```

不设 `EXAMPLE_TICK_BUDGET` 的话，driver 会在 1800 次 update（headless 下约 2 分钟）后自行停止并打印 `[EXIT CLEAN]`。Kit 会把 session log 写到 host 端的 `isaac-sim/kit/logs/Kit/<app>/<version>/kit_<timestamp>.log`。追最新一份：

```bash
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"
```

对容器跑 `docker logs` 只会看到它 idle 的 main process（`sleep infinity`），看不到你 exec 进去的脚本。

> 带引号 `bash -c '...'` 的指令改走 `./script/exec.sh`，不走 `just docker exec`。在 base v0.42.0 中，`just` recipe 会重新切分参数，导致带引号的指令以及任何 `>` 都在 host 上执行。base 已在 v0.43.0-rc5 修正（base PR #1298），而本 repo 仍 pin 在 v0.42.0（#297）。

### 可以忽略的启动警告

Kit 每次启动都会打印几种不影响运行的警告：

- `OmniHub: ... Hub encountered error. Trying to reconnect to Hub. retry_reason="Hub failed to launch: ..."`，前 2 秒大约 40 行。OmniHub 是 Nucleus asset 的可选本地 cache 服务。它的 helper（`/usr/local/bin/hub`）在 container 内以 `Permission denied` 退出，所以 Kit 直接加载 asset。这里的示例只用本地文件。
- `Extensions config 'extension.toml' doesn't exist '/home/<user>/work/<dir>'`，repo 每个顶层目录一行（约 15 行）。这来自本修正之前 build 的 image：experience 文件的 `extsUser` extension 目录不在 image 里，container user 又无法创建它，Kit 就改去工作目录找 extension。现在 image 会创建这个目录。如果还看到这些警告，用 `just docker build -t <stage>` 重新 build 该 stage。

### 停止 driver 脚本

在互动式 `just docker exec` 中按 Ctrl+C 会送到脚本，脚本的 SIGINT handler 随即关闭 Kit。但如果 exec client 不是 TTY，或者 client 被杀掉（关掉 terminal、`timeout`、CI），信号就到不了脚本，**Kit 会继续在容器里运行**。要可靠地停止，请在启动脚本时记录 PID，如上面范例用 `echo $$ > /tmp/isaac-driver.pid` 那样。然后对该进程的子进程（即 `python.sh` 启动的 Python）送 SIGINT：

```bash
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
```

不要直接用 `pkill -f <script>`。容器以 `pid: host` 运行，这个 pattern 也会匹配到 host 与其他容器里的进程。若要全部停掉，`just docker stop` 会移除这个 checkout 的容器，连同里面运行的 Kit 一起。

### 每个 checkout 一个 image 与一个 compose project

以前同一台 host 上这个 repo 的每个 checkout 都会解析出同一个 image tag（`<hub>/isaac:<stage>`）与同一个 compose project（`<hub>-isaac`）。结果 `just docker build` 会 prune 掉别的 checkout build 的 image，`just docker stop` / `run` 会移除别的 checkout 的 container（上游：[base#1550](https://github.com/ycpss91255-docker/base/issues/1550)、[base#1551](https://github.com/ycpss91255-docker/base/issues/1551)、[base#1552](https://github.com/ycpss91255-docker/base/issues/1552)）。在 base 修好之前：

- `./script/checkout_identity.sh isolate` 会把 `[image] rule_1 = string:isaac-<dir>-<hash>` 写进 gitignored 的 `.setup.conf.local`。image tag、compose project 与 container 名称都跟着它走。`./script/checkout_identity.sh show` 会打印这个 checkout 解析出的名称。
- pre build / run / stop hook 会拒绝对共用名称操作。`ISAAC_ALLOW_SHARED_IDENTITY=1` 可以跳过；CI 的 build 步骤就是这样用。
- `just docker run` 不会重新 build 已存在的 image（base#1552）。pull 新变更后，先 `just docker build -t <stage>` 再 `just docker run -t <stage>`。
- 有一个 image 仍然共用：每次 build 也会 build lint/bats 工具 image `test-tools:<base 版本>`（目前是 `test-tools:v0.42.0`），名称只由 pin 住的 base 版本决定。host 上所有 pin 同一个 base 版本的 checkout 与 repo 都写同一个 tag，所以别的 checkout 可能正在 build 时不要删它。`just docker build --clean-tools` 会替所有人把它删掉。它来自 base 的 `build.sh`，上游追踪在 [base#1551](https://github.com/ycpss91255-docker/base/issues/1551)。
- isolate 之前启动的 container 还留在共用 project 里。用 `docker compose -p <hub>-isaac ps -a` 列出，按名称停掉自己的。`ISAAC_ALLOW_SHARED_IDENTITY=1 just docker stop` 会停掉整个共用 project，包含别的 checkout 的 container。

## 连接 WebRTC livestream

Isaac Sim 6.2.0 用 NVCF（`omni.services.livestream.nvcf`）livestream 协议。可以用桌面 client 或浏览器 viewer 连接：

1. 从 [NVIDIA 文档 — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/6.2.0/installation/manual_livestream_clients.html) 下载 **Isaac Sim WebRTC Streaming Client**。请使用 NVIDIA 文档在该处列出、对应你 Isaac Sim 版本的 client 版本。
2. `stream` 运行时，启动 client，输入 Server: `<server-ip>`（同机用 `localhost`，远端用 server 的 LAN IP）。**不要加 `:8011` 或任何 port 后缀** — client 自己会选 signaling / data port；加 port 后缀会走错 path、看到黑画面。
3. 按 Connect。首次 shader compile 需 1–3 分钟 viewport 才会出画面。

### Browser-based viewer (omniverse_web_viewer)

[`omniverse_web_viewer`](https://github.com/ycpss91255-docker/omniverse_web_viewer) repo 提供浏览器 client，以 sidecar 容器运行。作为 submodule 放在本 repo 的 `web_viewer/`。

```bash
# 首次：初始化 submodule + 创建 per-host config
git submodule update --init --recursive web_viewer
cp config/host.yaml.example config/host.yaml
# 编辑 config/host.yaml：把 network.public_ip 填这台机器的 LAN IP

# 启动 idle stream 容器 + host.yaml + web-viewer。
# post-run hook（base #440）把 host.yaml copy 进去并启动 viewer。
just docker run -t stream -d

# 把 Isaac Sim 启进容器 -- 一个明确的步骤（run = infra，
# exec = workload）。可以跑 driver script：
just docker exec -t stream /isaac-sim/python.sh <driver.py>
# ...或者，no-driver 快速 stream，用 livestream wrapper：
#   just docker exec -t stream /usr/local/bin/runheadless-host-config.sh

# Watch Isaac Sim load: Kit's session log on the host (docker logs only
# shows the container's idle main process)
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"

# 打开 Chrome -> http://<host-ip>:5173
# 直接进入实时串流（stream-only 自动启动，不显示 UI Option 选择界面）

# 停掉所有东西（post-stop hook 会移除 web-viewer）
just docker stop
```

`config/host.yaml` 是 gitignored、per-machine。它的 `network.public_ip` 会 mount 进两个 container：Isaac 端由 `runheadless-host-config.sh` 读取并转成 Kit `publicEndpointAddress` 参数；web-viewer 端由 entrypoint 读取设成 `SIGNALING_SERVER`。

post-run hook 同时也把 `network.public_ip` 当 `SIGNALING_SERVER` env 传给 viewer container — defense in depth，当本机 cache 的 viewer image 早于 `omniverse_web_viewer#12`（读 `/etc/host.yaml` 的 entrypoint）时仍能拿到正确 host IP。`web_viewer/` submodule pointer 升级后请手动 rebuild `owv:runtime` 拉取新 entrypoint。

要求：Chrome 或 Chromium（Firefox 不兼容）。每个运行中的 Isaac Sim 只能有一个交互式 client。

注意：

- streaming kit app 同时 listen 在 `8011`（NVCF signaling，FastAPI/uvicorn）、`49100`（self-host WebRTC）与 `8211`（kit API / streaming viewer）。WebRTC Streaming Client 会自己选对的，**不要写 port**
- **同时只能一个 client 连**（NVIDIA 限制）。第二个连接会被拒绝
- `setup.conf` 已开 `network_mode: host`，容器内 listen 的 port = host 的 port。Host 防火墙要放行 `8011/tcp` 跟 `49100/tcp`（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` 必须含 `video` — 否则 nvidia-container-runtime 不 mount NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`），server 连得上但画面 encode 不出来 → 黑画面。当前 `setup.conf` 已加
- Server 端确认 listener：`ss -tln | grep -E ':8011|:49100'` 应看到两个 `LISTEN`

### 确定性 stream-source producer（GHCR image，isaac#223）

给 CI 与浏览器版视觉 e2e（[`omniverse_web_viewer#48`](https://github.com/ycpss91255-docker/omniverse_web_viewer/issues/48)，由 Tier B browser-frames smoke isaac#173 消费）用的一个可 pull、pin 版号的 producer image，不需要开一个桌面 Isaac session 就能提供*保证非全黑*的 WebRTC 来源。开机时它渲染一个确定性的空但打光的场景 — dome + distant key light 打在 12×12 棋盘格地板上，相机取景在 `eye=[15,-15,11]` — 并永久 livestream，所以浏览器随时连上都看到可重现的画面。整个场景以程序化方式生成（无外部 asset），image 自给自足。

- **Image**：`ghcr.io/ycpss91255-docker/isaac-stream-source:<tag>`（pin 的 immutable tag — 非 `:latest`）。由 `producer` Dockerfile stage build。
- **Driver**：`src/script/stream_source_producer.py`，baked 在 `/opt/isaac-producer/stream_source_producer.py`，由 image `CMD` 启动。
- **发布**：只走 `Publish Stream-Source Producer (GHCR)` workflow 手动触发（`workflow_dispatch`，input `tag`，默认 `0.0.1`）。没有 push/tag trigger，所以 merge 不会自动发布。

运行：

```bash
# --network=host 让容器的 WebRTC listen port = host 的。
# PUBLIC_IP 是本机 LAN IP（远端浏览器要拨的）；
# ISAAC_SIGNAL_PORT 覆写默认 signaling port（49100）。
docker run --rm --network=host --gpus all \
  -e PUBLIC_IP=<host-lan-ip> \
  -e ISAAC_SIGNAL_PORT=49100 \
  ghcr.io/ycpss91255-docker/isaac-stream-source:0.0.2

# 然后用浏览器 / omniverse_web_viewer 连 <host-lan-ip>（见上）。
```

目前还没有从 Isaac Sim 6.2.0 发布的 producer image。最新的是 `0.0.2`，建在 6.0.1 上，所以下表到此为止。发布方式是手动对 publish workflow 做 `workflow_dispatch`，表格会依 image 本身的 label 更新。

### 版本与 Isaac Sim 对应

producer image 的版号单纯递增，不编码 Isaac Sim 版本。要知道某颗 image 建在哪个 Isaac Sim 上，直接问那颗 image。

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

必要条件：NVIDIA GPU runtime（`--gpus all`）做 NVENC 编码、`--network=host`、非 localhost client 需要 `PUBLIC_IP`。`ISAAC_SIGNAL_PORT` 可选（默认 `49100`）。driver 也接受 `--public-ip` / `--port` / `--run-seconds N`（`N>0` 界定 smoke run；默认永久运行）。

## ROS 2 bridge（内置，build-time distro）

Isaac Sim 6.2.0 在 `/isaac-sim/exts/isaacsim.ros2.core/{humble,jazzy}/` 内置 Humble 与 Jazzy 两套 ROS 2 lib（5.1 时放在 `isaacsim.ros2.bridge/`；6.0 把单一 bridge ext 拆成 `isaacsim.ros2.core` + `isaacsim.ros2.nodes` 等），两者都是 Python 3.12 rclpy，与 kit 内嵌 interpreter 对齐。**本 image 在 build time 把 distro hard-bake 进去** — 透过 `setup.conf [build] arg_N=ROS_DISTRO=<value>` 注入（默认 `humble`，与 CoreSAM 对齐）。

Bridge extension 由 base `IsaacDriver` 在 Kit BOOT 阶段启用（`BOOT_EXTENSIONS` -> `--enable isaacsim.ros2.bridge` kit args），这在 Isaac Sim 6.x 下是 headless camera -> ROS 2 publish 的必要条件（isaac#248；6.2.0 再验证：runtime 启用仍会关掉 app）。driver 路径不需要额外 launch flag。

Env wiring 写在 `setup.conf [environment]`（distro-agnostic）：

| 变量 | 值 | 原因 |
|-----|-------|-----|
| `ROS_DOMAIN_ID` | `0` | small-team default; bump if multiple users share the host |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | explicit FastDDS, no inherit from host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile (cross-container DDS reliable, no SHM flakiness) |

### Distro 选择（build-time、hard-baked）

Dockerfile 内 `ARG ROS_DISTRO=humble`，由 `setup.conf [build]` 串进来。Build time 时该值写入 `/etc/isaac/ros-distro`，并把 `script/isaac-ros-env-wrapper.sh` 装到 `/usr/local/bin/`。`headless` / `stream` stage 把 `ENTRYPOINT` 设成该 wrapper，每次 container 起来都从 baked file 无条件 re-export `ROS_DISTRO` 与 `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.core/${ROS_DISTRO}/lib` — 因此 production path 上 runtime 的 `-e ROS_DISTRO=...` flag 不会生效。

`devel` stage 透过 Dockerfile `ENV` 做 soft-bake（互动 shell 默认带这两个值；developer 可 `export ROS_DISTRO=...` 临时实验）。

切到 jazzy：

```bash
just docker setup remove build.arg "ROS_DISTRO=humble"
just docker setup add build.arg "ROS_DISTRO=jazzy"
just docker build           # 用新 ARG 重 build（只重 build 受影响 layer，~10s）
just docker run -t headless -d
```

jazzy path 与 Isaac 在 24.04 上的 auto-default 对齐（LTS until 2029）— 已知坑：jazzy on noble 有 Python 3.11/3.12 混用与 Nav2 path 粗糙问题，仍在 NVIDIA 论坛追踪中。本 repo 尚未在 Isaac Sim 6.2.0 上重新验证 jazzy path；humble 是已验证的默认值。

### 验证 cross-container DDS

跑 `just docker run -t headless -d`（已带 humble override env）并用 WebRTC client 连上后，开 Script Editor → File → Open → `~/work/src/script/ros2_test_pub.py`（即 repo 的 `src/script/`，mount 在容器内的位置）→ Run。脚本会自动按 Play（publisher 只在 timeline 播放时触发），开始在 `/isaac/test` 发布 `std_msgs/String "hello N"`。

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

### Standalone Python workflow（Script Editor 替代方案）

`src/script/` 放有 M1 / M2 demo 的 in-kit Script Editor 版本与 standalone 版本。standalone 版本透过 `SimulationApp` 启动自己的 Kit，并依 stage 的 `ISAAC_LIVESTREAM` 决定模式（`headless` 为 0，`stream` 为 2）。`cmd_vel_planar_standalone.py` 一律以 headless 跑 Kit，因为在同一个 standalone process 里同时开 livestream 与 ROS 2 bridge 曾让 Kit crash（IsaacSim#228）。每个 standalone 脚本都接受 `--run-seconds N`，遇到任何错误都 exit 1（以前是 exit 0）。

| In-kit（Script Editor → File → Open → Run） | Standalone（`just docker exec -t headless /isaac-sim/python.sh src/script/<name>`） | 6.2.0 验证结果（headless） |
|---|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py`：每秒在 `/isaac/test` 发布一次 | `ros2 topic hz` 1.000 |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py`：打印每则 `/host/test` 讯息 | 3/3 收到 |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py`：固定 `CMD_VX/VY/WZ` 平面移动 | x +0.5 m/s，z 维持 0 |
| （无 in-kit 版本） | `cmd_vel_planar_standalone.py`：订阅 `/cmd_vel`（geometry_msgs/Twist）并让 OpenBase 在平面上移动 | 0 指令时静止，`linear.x: 0.5` 时 x +0.5 m/s，z 维持 0 |

使用 pattern：

```bash
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; exec /isaac-sim/python.sh src/script/<name>_standalone.py'
# stop it (see "Stopping a driver script"):
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
just docker stop                           # cleanup
```

共用的 host 上，ROS domain 0 可能有其他 `/cmd_vel` publisher，它们也会让 OpenBase 移动。给你的 run 一个私有 domain，例如 `bash -c 'ROS_DOMAIN_ID=77 exec /isaac-sim/python.sh ...'`，相邻容器也要带同样的 `-e ROS_DOMAIN_ID=77`。

## Cache 路径

所有 Isaac Sim runtime state 都持久化在 host 端的 `${WS_PATH}/isaac-sim/`。`WS_PATH` 解析为 repo root，所以就是你 checkout 里的 `isaac-sim/`。该目录已 gitignored，并由 `.dockerignore` 排除在 docker build context 之外：

| Host | Container | 用途 |
|------|-----------|------|
| `isaac-sim/kit/cache` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/kit/data` | `/isaac-sim/kit/data` | Kit app data（`user.config.json`、pipapi envs）|
| `isaac-sim/kit/logs` | `/isaac-sim/kit/logs` | Kit app logs |
| `isaac-sim/ov/cache` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache（主要是 shader 编译产物）|
| `isaac-sim/ov/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/ov/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/nvidia/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/nvidia/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents（USD scenes 等）|

2026-05-21 以前的 layout（`cache/{kit,ov,pip,glcache,computecache}`、flat `logs/`、flat `data/`)会在升版后第一次跑 `./script/init_isaac_dirs.sh` 自动 migrate 到新的 namespaced path(issue #21 fix-A）。已累积的 shader / pip / compute cache 透过 mv 保留。

当 `isaac-sim/documents/Kit/shared/screenshots` 尚不存在时，Kit 会以 mode 000 创建它。`init_isaac_dirs.sh` 会预先以 0755 创建，并修复已是 mode 000 的目录。

容器不回报 health status（`HEALTHCHECK NONE`）。NGC base image 的 check 会在 Kit log 里 grep `App is loaded`，但这些容器按设计是没有 Kit 的 idle 状态，所以每一个都会被标成 `unhealthy`。

首次 headless 启动需 1–3 分钟编译 shader；之后启动 cache hit `< 30 秒`。

## 容器 User

容器以对齐 host UID 的非 root user 跑（`USER_NAME` 从 `.env` 读取，默认 UID 1000）。该 user 被加进 image 的 `isaac-sim` group，可读取 `/isaac-sim/*`（mode `0750`）。通过 `/home/${USER_NAME}/work`（mount 到 host `${WS_PATH}`）写的文件保留 host 端 owner，无需 `chown`。

## EULA

`ACCEPT_EULA=Y` 与 `PRIVACY_CONSENT=Y` 通过 `setup.conf [environment]` 注入。注意：Isaac Sim 6.x 用 `OMNI_ENV_PRIVACY_CONSENT` 读取 privacy consent（此名称自 5.1 起采用，跟 5.1 之前的版本不同）；目前设的 `PRIVACY_CONSENT=Y` 无害但实际无作用，要 telemetry opt-in 请另设正确的变量。

## Smoke Tests

详见 [doc/test/TEST.md](test/TEST.md)。

## Python 测试工具链（devel-test 阶段）

`devel-test` 阶段内置 `pytest`、`pyyaml`、`pytest-cov`，安装在 Isaac Sim 自带的 Python 环境（`/isaac-sim/python.sh`）里，让 consumer repos 可以在容器内跑 Python unit / integration test。runtime `devel` 阶段不装这些依赖，保持精简 — 测试工具只在 `devel-test` 才付出大小成本。

用法：

```bash
just docker build -t test                                                 # 构建 devel-test 阶段 (compose service `test`)
just docker run -t test -- /isaac-sim/python.sh -m pytest test/unit/
just docker run -t test -- /isaac-sim/python.sh -m pytest --cov=<pkg> test/
```

系统的 `python3` 无法安装这些套件（Isaac base image 的 PEP 668 拦截 `pip`）— 一律走 `/isaac-sim/python.sh -m pytest ...`，不要用 `pytest ...`。

GPU integration test（需要 Isaac Sim 真正启动，例如 camera → ROS 2 headless smoke，#127）走 `test` compose service；该 service 的 NVIDIA GPU reservation 来自 `setup.conf` 的 `[stage:devel-test]` override（`deploy.gpu_mode = force`，base #493）：

```bash
just docker run -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_camera_ros2_headless.py
```

判定标准是 stdout marker 行（`[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]`），不是 return code — Kit 的 `app.close` 会调用 `_exit(0)`。详见 [doc/test/TEST.md](test/TEST.md)。
