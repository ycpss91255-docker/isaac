# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 6.2.0 Docker 開發環境，以 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（前身為 `ycpss91255-docker/template`）為基礎建立。

Image scope 涵蓋 Isaac Sim 本體，加上其內建 ROS 2 bridge 跨容器通訊所需的 env wiring。NVIDIA Isaac Lab 3.0（`v3.0.0`）也一併 baked 進 image，當 scene-spawn backend（`sim_utils` spawner、`UrdfConverter`、`AppLauncher`；ADR-0018）。下游 application node（CoreSAM、AGV bring-up）以及對接 Noetic 的 ROS 1 / ROS 2 bridge 放在相鄰的 docker folder。

本 repo 同時內含 Isaac Sim workspace 內容（driver script、ADR、USD / URDF 模型）於 [`src/`](../src/README.md)；root 的 Dockerfile + base subtree 是執行該 workspace 的開發環境。兩者原本分屬 `ycpss91255-research/isaac` 與 `ycpss91255-docker/isaac`（research wraps docker via submodule），依 [#78](https://github.com/ycpss91255-docker/isaac/issues/78) 合併至此。

## 前置需求

- NVIDIA driver `>= 580`（Isaac Lab 3.0 會裝 CUDA 13 版 PyTorch；NVIDIA 以 595.58.03 測過 Isaac Sim 6.2.0；本 repo 已在 driver 610 驗證）
- GPU `>= RTX 4080`（或同等級），VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- 約 50 GB 空閒空間。build 出來的 image 約 31 GB，其中 20.7 GB 是 NGC base image、約 10 GB 是 Isaac Lab 與工具鏈；其他 stage 共用這些 layer。build 時還需要預留 BuildKit cache 的空間，首次啟動後 cache 目錄會再長 5–10 GB

NGC image（`nvcr.io/nvidia/isaac-sim:6.2.0.1`，即 6.2.0 GA build；為何不用 `:6.2.0` 見 `Dockerfile` `BASE_IMAGE` 註解）公開可拉，不需 `docker login nvcr.io`。

## Quick Start

從剛 clone 下來的 repo 開始，在 repo root 依序執行：

```bash
./script/checkout_identity.sh isolate   # 首次必跑，讓這個 checkout 有自己的 image tag 與 compose project
./script/init_isaac_dirs.sh             # 首次必跑，會執行 ./script/setup.sh apply，並建好 10 個 host-owned cache 目錄
just docker build                       # build devel stage（約 31 GB image，見前置需求）
just docker run                         # 進 devel 容器互動 shell
```

> cache 目錄必須在 container mount 之**前**就存在，且 owner 是你。否則 docker daemon 會以 **root** 身份建立它們，Kit 就無法寫入自己的 cache，接著無法註冊 ROS 2 OmniGraph node（`[Errno 13] ... kit/cache/ogn_generated`），而且仍然以 exit 0 結束。`init_isaac_dirs.sh` 會建立這些目錄，pre-run hook 也會在每次 `just docker run` 之前再跑一次。如果目錄已經是 root 所有，腳本會停下並印出 `chown` 修正指令。

Production stage（兩個 stage 啟動後都 idle — driver 腳本用 exec 送進執行中的 container）：

```bash
just docker run -t headless -d                # pure sim, no streaming (ISAAC_LIVESTREAM=0)
just docker run -t stream -d         # sim + WebRTC streaming (ISAAC_LIVESTREAM=2)
just docker exec -t stream /isaac-sim/python.sh <script>   # run a driver script
```

> 兩個 stage 透過 [base #215](https://github.com/ycpss91255-docker/base/issues/215) auto-emit 為 profile-gated compose service：`headless`（pure sim，`ISAAC_LIVESTREAM=0`）與 `stream`（sim + WebRTC，`ISAAC_LIVESTREAM=2`）。兩者啟動後都 `CMD ["sleep","infinity"]` idle（沒有 `runheadless.sh -v` ENTRYPOINT）— container 持續存活，由你用 `just docker exec -t <stage> <cmd>` 把 driver 腳本（`/isaac-sim/python.sh <driver.py>`，讀 `ISAAC_LIVESTREAM=2` 開 stream）或一次性 `/usr/local/bin/runheadless-host-config.sh` 送進去；streaming 起來後 web-viewer 連 `:5173`。使用 `just docker run -t <stage> -d` 啟動。

### Headless：啟動 Isaac 並跑一個場景

`example/` 的 camera_bot 場景以 headless 執行，會發布 ROS 2 camera topic 並訂閱 `/cmd_vel`。container 的工作目錄是 repo root（mount 在 `~/work`），所以腳本路徑都相對於 repo。以下流程已在 Isaac Sim 6.2.0（RTX 5090）驗證：

```bash
just docker build -t headless
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; EXAMPLE_TICK_BUDGET=100000 exec /isaac-sim/python.sh example/sim/example_driver.py'
# prints [CAMERA GRAPH OK] and [BOOT OK] in about 30 s

# In a second terminal: the camera topic, from a sibling ROS 2 container
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble bash -c \
  'source /opt/ros/humble/setup.bash && ros2 topic echo --once /camera_bot/camera/color/image_raw --field header'
# frame_id: camera_bot_camera_color_optical_frame

just docker stop
```

沒設 `EXAMPLE_TICK_BUDGET` 時，driver 跑完 1800 次 update（headless 約 2 分鐘）後會自行停止並印出 `[EXIT CLEAN]`。Kit 會把 session log 寫到 host 端的 `isaac-sim/kit/logs/Kit/<app>/<version>/kit_<timestamp>.log`。追最新一份：

```bash
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"
```

對 container 下 `docker logs` 只會看到它 idle 的主 process（`sleep infinity`），看不到你 exec 進去的腳本。

> 帶引號 `bash -c '...'` 的指令改走 `./script/exec.sh`，不用 `just docker exec`。在 base v0.42.0 中，`just` recipe 會重新切分參數，導致帶引號的指令與其中的 `>` 在 host 上執行。base 已在 v0.43.0-rc5 修正（base PR #1298），本 repo 目前仍 pin 在 v0.42.0（#297）。

### 停止 driver 腳本

在互動式 `just docker exec` 中按 Ctrl+C 會送到腳本，由它的 SIGINT handler 關閉 Kit。但如果 exec client 不是 TTY，或 client 被殺掉（關掉 terminal、`timeout`、CI），訊號就到不了腳本，**Kit 會繼續在 container 內執行**。要可靠地停止，請在啟動腳本時記下 PID，就像上面範例的 `echo $$ > /tmp/isaac-driver.pid`。然後對該 process 的子 process（也就是 `python.sh` 啟動的 Python）送 SIGINT：

```bash
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
```

不要直接用 `pkill -f <script>`。container 以 `pid: host` 執行，這個 pattern 也會比對到 host 與其他 container 裡的 process。若要全部停掉，`just docker stop` 會移除這個 checkout 的 container，連同裡面執行中的 Kit。

### 每個 checkout 一個 image 與一個 compose project

以前同一台 host 上這個 repo 的每個 checkout 都會解析出同一個 image tag（`<hub>/isaac:<stage>`）與同一個 compose project（`<hub>-isaac`）。結果 `just docker build` 會 prune 掉別的 checkout build 的 image，`just docker stop` / `run` 會移除別的 checkout 的 container（上游：[base#1550](https://github.com/ycpss91255-docker/base/issues/1550)、[base#1551](https://github.com/ycpss91255-docker/base/issues/1551)、[base#1552](https://github.com/ycpss91255-docker/base/issues/1552)）。在 base 修好之前：

- `./script/checkout_identity.sh isolate` 會把 `[image] rule_1 = string:isaac-<dir>-<hash>` 寫進 gitignored 的 `.setup.conf.local`。image tag、compose project 與 container 名稱都跟著它走。`./script/checkout_identity.sh show` 會印出這個 checkout 解析出的名稱。
- pre build / run / stop hook 會拒絕對共用名稱動作。`ISAAC_ALLOW_SHARED_IDENTITY=1` 可以略過；CI 的 build 步驟就是這樣用。
- `just docker run` 不會重 build 已存在的 image（base#1552）。pull 新變更後，先 `just docker build -t <stage>` 再 `just docker run -t <stage>`。
- isolate 之前啟動的 container 還留在共用 project 裡。用 `docker compose -p <hub>-isaac ps -a` 列出，按名稱停掉自己的。`ISAAC_ALLOW_SHARED_IDENTITY=1 just docker stop` 會停掉整個共用 project，包含別的 checkout 的 container。

## 連接 WebRTC livestream

Isaac Sim 6.2.0 用 NVCF（`omni.services.livestream.nvcf`）livestream 協定。可用桌面 client 或瀏覽器 viewer 連線：

1. 從 [NVIDIA 文件 — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/6.2.0/installation/manual_livestream_clients.html) 下載 **Isaac Sim WebRTC Streaming Client**。請使用 NVIDIA 文件在該處列出、對應你 Isaac Sim 版本的 client 版本。
2. `stream` 跑著時，啟動 client，輸入 Server: `<server-ip>`（同機用 `localhost`，遠端用 server 的 LAN IP）。**不要加 `:8011` 或任何 port 後綴** — client 會自己挑 signaling / data port；加 port 後綴會走錯 path、看到黑畫面。
3. 按 Connect。首次 shader compile 需要 1–3 分鐘 viewport 才會出畫面。

### 瀏覽器 viewer (omniverse_web_viewer)

[`omniverse_web_viewer`](https://github.com/ycpss91255-docker/omniverse_web_viewer) repo 提供瀏覽器版 client，以 sidecar 容器形式運行。已作為 submodule 掛在本 repo 的 `web_viewer/`。

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

`config/host.yaml` 是 gitignored、per-machine。它的 `network.public_ip` 會 mount 進兩個 container：Isaac 端由 `runheadless-host-config.sh` 讀取轉成 Kit `publicEndpointAddress` 參數；web-viewer 端由 entrypoint 讀取設成 `SIGNALING_SERVER`。

post-run hook 同時也把 `network.public_ip` 當 `SIGNALING_SERVER` env 傳給 viewer container — defense in depth，當本機 cache 的 viewer image 早於 `omniverse_web_viewer#12`（讀 `/etc/host.yaml` 的 entrypoint）時還能拿到正確的 host IP。`web_viewer/` submodule pointer 升級後請手動 rebuild `owv:runtime` 拉取新 entrypoint。

需求：Chrome 或 Chromium（Firefox 不相容）。每個正在跑的 Isaac Sim 只能同時連一個互動 client。

注意：

- streaming kit app 同時 listen 在 `8011`（NVCF signaling，FastAPI/uvicorn）、`49100`（self-host WebRTC）以及 `8211`（kit API / streaming viewer）。WebRTC Streaming Client 會自己選對的，**不要寫 port**
- **同時只能一個 client 連**（NVIDIA 限制）。第二個連線會被拒
- `setup.conf` 已開 `network_mode: host`，容器內 listen 的 port = host 的 port。Host 防火牆要放行 `8011/tcp` 跟 `49100/tcp`（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` 必須含 `video` — 沒有的話 nvidia-container-runtime 不 mount NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`），server 連得上但畫面 encode 不出來 → 黑畫面。當前 `setup.conf` 已加
- Server 端確認 listener：`ss -tln | grep -E ':8011|:49100'` 應看到兩個 `LISTEN`

### 確定性 stream-source producer（GHCR image，isaac#223）

給 CI 與瀏覽器版視覺 e2e（[`omniverse_web_viewer#48`](https://github.com/ycpss91255-docker/omniverse_web_viewer/issues/48)，由 Tier B browser-frames smoke isaac#173 消費）用的一個可 pull、pin 版號的 producer image，不需要開一個桌面 Isaac session 就能提供*保證非全黑*的 WebRTC 來源。開機時它渲染一個確定性的空但打光的場景 — dome + distant key light 打在 12×12 棋盤格地板上，相機取景在 `eye=[15,-15,11]` — 並永久 livestream，所以瀏覽器隨時連上都看到可重現的畫面。整個場景以程式化方式生成（無外部 asset），image 自給自足。

- **Image**：`ghcr.io/ycpss91255-docker/isaac-stream-source:<tag>`（pin 的 immutable tag — 非 `:latest`）。由 `producer` Dockerfile stage build。
- **Driver**：`src/script/stream_source_producer.py`，baked 在 `/opt/isaac-producer/stream_source_producer.py`，由 image `CMD` 啟動。
- **發佈**：只走 `Publish Stream-Source Producer (GHCR)` workflow 手動觸發（`workflow_dispatch`，input `tag`，預設 `0.0.1`）。沒有 push/tag trigger，所以 merge 不會自動發佈。

執行：

```bash
# --network=host 讓容器的 WebRTC listen port = host 的。
# PUBLIC_IP 是本機 LAN IP（遠端瀏覽器要撥的）；
# ISAAC_SIGNAL_PORT 覆寫預設 signaling port（49100）。
docker run --rm --network=host --gpus all \
  -e PUBLIC_IP=<host-lan-ip> \
  -e ISAAC_SIGNAL_PORT=49100 \
  ghcr.io/ycpss91255-docker/isaac-stream-source:0.0.2

# 然後用瀏覽器 / omniverse_web_viewer 連 <host-lan-ip>（見上）。
```

目前還沒有從 Isaac Sim 6.2.0 發佈的 producer image。最新的是 `0.0.2`，建在 6.0.1 上，所以下表到此為止。發佈方式是手動對 publish workflow 執行 `workflow_dispatch`，表格會依 image 本身的 label 更新。

### 版本與 Isaac Sim 對應

producer image 的版號單純遞增，不編碼 Isaac Sim 版本。要知道某顆 image 建在哪個 Isaac Sim 上，直接問那顆 image。

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

必要條件：NVIDIA GPU runtime（`--gpus all`）做 NVENC 編碼、`--network=host`、非 localhost client 需要 `PUBLIC_IP`。`ISAAC_SIGNAL_PORT` 可選（預設 `49100`）。driver 也接受 `--public-ip` / `--port` / `--run-seconds N`（`N>0` 界定 smoke run；預設永久執行）。

## ROS 2 bridge（內建，build-time distro）

Isaac Sim 6.2.0 在 `/isaac-sim/exts/isaacsim.ros2.core/{humble,jazzy}/` 同時內建 Humble 與 Jazzy 兩套 ROS 2 libraries（5.1 時放在 `isaacsim.ros2.bridge/`；6.0 把單一 bridge ext 拆成 `isaacsim.ros2.core` + `isaacsim.ros2.nodes` 等），皆走 Python 3.12 rclpy，與 kit 內嵌 interpreter 一致。**本 image 在 build-time hard-bake distro 選擇** — 透過 `setup.conf [build] arg_N=ROS_DISTRO=<value>`（預設 `humble`，CoreSAM 對齊）。

Bridge extension 由 base `IsaacDriver` 在 Kit BOOT 階段啟用（`BOOT_EXTENSIONS` -> `--enable isaacsim.ros2.bridge` kit args），這在 Isaac Sim 6.x 下是 headless camera -> ROS 2 publish 的必要條件（isaac#248；6.2.0 再驗證：runtime 啟用仍會關掉 app）。driver 路徑不需要額外 launch flag。

`setup.conf [environment]` 內 distro-agnostic env wiring：

| 變數 | 值 | 用途 |
|------|----|------|
| `ROS_DOMAIN_ID` | `0` | 小團隊預設值；多人共用 host 時調高 |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | 明確指定 FastDDS，不繼承 host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile（跨容器 DDS reliable，避開 SHM flakiness）|

### Distro 選擇（build-time、hard-baked）

Dockerfile 的 `ARG ROS_DISTRO=humble` 接到 `setup.conf [build]`。Build 時值會被寫進 `/etc/isaac/ros-distro`，且 `script/isaac-ros-env-wrapper.sh` 會 install 到 `/usr/local/bin/`。`headless` 與 `stream` 兩個 stage 把 `ENTRYPOINT` 設成這個 wrapper — 每次 container 啟動時 wrapper 從 baked file 讀取並無條件 re-export `ROS_DISTRO` 與 `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.core/${ROS_DISTRO}/lib`，因此 production paths 上的 runtime `-e ROS_DISTRO=...` flag **無效**。

`devel` stage 透過 Dockerfile `ENV` soft-bake 同樣兩個值（互動 shell 預設拿到，devs 仍可 `export ROS_DISTRO=...` 實驗）。

切到 jazzy：

```bash
just docker setup remove build.arg "ROS_DISTRO=humble"
just docker setup add build.arg "ROS_DISTRO=jazzy"
just docker build           # 重 build 帶上新 ARG（只有受影響 layer 重 build，~10s）
just docker run -t headless -d
```

Jazzy 路徑跟 Isaac 24.04 自動預設對齊（LTS 至 2029）— 已知 caveat：jazzy on noble 有 Python 3.11/3.12 混搭與 Nav2 路徑粗糙的問題，目前在 NVIDIA 論壇追蹤中。本 repo 尚未在 Isaac Sim 6.2.0 上重新驗證 jazzy 路徑；humble 是已驗證的預設值。

### 驗證跨容器 DDS

跑 `just docker run -t stream -d`（帶 humble 覆蓋 env）並用 WebRTC client 或瀏覽器 viewer 連線後，打開 Script Editor → File → Open → `~/work/src/script/ros2_test_pub.py`（即 repo 的 `src/script/`，mount 在 container 內的位置）→ Run。腳本會自動按 Play（publisher 只在 timeline 播放時才發），開始往 `/isaac/test` 發 `std_msgs/String "hello N"`。

從同一台 host 的另一個 terminal：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic list &&
             ros2 topic echo /isaac/test --once'
```

預期：topic list 出現 `/isaac/test`，`echo` 印出 hello message。

反向（host → Isaac）測試：在 Script Editor 跑 `ros2_test_sub.py`，從旁邊容器發訊息：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic pub /host/test std_msgs/String "{data: hello-from-host}" --once'
```

Kit terminal 應印出 `[ros2_test_sub] /host/test <- 'hello-from-host'`。

> 跑 jazzy-aligned 的 Isaac instance 時，把兩端都換成 `ros:jazzy` + `/opt/ros/jazzy/setup.bash` — 兩端 distro 必須一致，IDL hash 才能對齊。

### Standalone Python workflow（Script Editor 替代方案）

`src/script/` 同時放 M1 / M2 demo 的 in-kit Script Editor 版本與 standalone 版本。standalone 版本透過 `SimulationApp` 啟動自己的 Kit，並依 stage 的 `ISAAC_LIVESTREAM` 決定模式（`headless` 為 0、`stream` 為 2）。`cmd_vel_planar_standalone.py` 一律以 headless 執行 Kit，因為在同一個 standalone process 裡同時跑 livestream 與 ROS 2 bridge 曾讓 Kit crash（IsaacSim#228）。每支 standalone 腳本都接受 `--run-seconds N`，遇到任何錯誤會以 exit 1 結束（以前是 exit 0）。

| In-kit（Script Editor → File → Open → Run） | Standalone（`just docker exec -t headless /isaac-sim/python.sh src/script/<name>`） | 6.2.0 驗證結果（headless） |
|---|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py`：每秒發布一次 `/isaac/test` | `ros2 topic hz` 1.000 |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py`：印出每則 `/host/test` 訊息 | 3/3 收到 |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py`：以固定 `CMD_VX/VY/WZ` 平面移動 | x +0.5 m/s，z 維持 0 |
| （無 in-kit 版本） | `cmd_vel_planar_standalone.py`：訂閱 `/cmd_vel`（geometry_msgs/Twist）並讓 OpenBase 在平面上移動 | 指令為 0 時靜止，`linear.x: 0.5` 時 x +0.5 m/s，z 維持 0 |

使用 pattern：

```bash
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; exec /isaac-sim/python.sh src/script/<name>_standalone.py'
# stop it (see "Stopping a driver script"):
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
just docker stop                           # cleanup
```

共用 host 上 ROS domain 0 可能有其他 `/cmd_vel` publisher，它們也會讓 OpenBase 移動。請給你的執行一個私有 domain，例如 `bash -c 'ROS_DOMAIN_ID=77 exec /isaac-sim/python.sh ...'`，旁邊的 container 也要帶同樣的 `-e ROS_DOMAIN_ID=77`。

## Cache 路徑

所有 Isaac Sim runtime state 都持久化在 host 端的 `${WS_PATH}/isaac-sim/`。`WS_PATH` 解析為 repo root，所以就是你 checkout 裡的 `isaac-sim/`。它已列入 gitignore，並由 `.dockerignore` 排除在 docker build context 之外：

| Host | Container | 用途 |
|------|-----------|------|
| `isaac-sim/kit/cache` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/kit/data` | `/isaac-sim/kit/data` | Kit app data（`user.config.json`、pipapi envs）|
| `isaac-sim/kit/logs` | `/isaac-sim/kit/logs` | Kit app logs |
| `isaac-sim/ov/cache` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache（主要是 shader 編譯產物）|
| `isaac-sim/ov/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/ov/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/nvidia/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/nvidia/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents（USD scenes 等）|

2026-05-21 以前的 layout（`cache/{kit,ov,pip,glcache,computecache}`、flat `logs/`、flat `data/`)會在升版後第一次跑 `./script/init_isaac_dirs.sh` 自動 migrate 到新的 namespaced path(issue #21 fix-A）。已累積的 shader / pip / compute cache 透過 mv 保留。

`isaac-sim/documents/Kit/shared/screenshots` 不存在時，Kit 會以 mode 000 建立它。`init_isaac_dirs.sh` 會預先以 0755 建立，並修復 mode 000 的目錄。

container 不回報 health 狀態（`HEALTHCHECK NONE`）。NGC base image 的 health check 會在 Kit log 裡 grep `App is loaded`，但這些 container 設計上就是 idle、沒有跑 Kit，所以原本每一個都會被標成 `unhealthy`。

首次 headless 啟動需 1–3 分鐘編譯 shader；之後啟動 cache hit `< 30 秒`。

## 容器 User

容器以對齊 host UID 的非 root user 跑（`USER_NAME` 從 `.env` 讀，預設 UID 1000）。該 user 被加進 image 的 `isaac-sim` group，可讀取 `/isaac-sim/*`（mode `0750`）。透過 `/home/${USER_NAME}/work`（mount 到 host `${WS_PATH}`）寫的檔案會保留 host 端 owner，不需 `chown`。

## EULA

`ACCEPT_EULA=Y` 與 `PRIVACY_CONSENT=Y` 透過 `setup.conf [environment]` 注入。注意：Isaac Sim 6.x 用 `OMNI_ENV_PRIVACY_CONSENT` 讀取 privacy consent（此名稱自 5.1 起採用，跟 5.1 之前的版本不同）；目前設的 `PRIVACY_CONSENT=Y` 無害但實際沒作用，要 telemetry opt-in 請另設正確的變數。

## Smoke Tests

詳見 [doc/test/TEST.md](test/TEST.md)。

## Python 測試工具鏈（devel-test 階段）

`devel-test` 階段內建 `pytest`、`pyyaml`、`pytest-cov`，安裝在 Isaac Sim 自帶的 Python 環境（`/isaac-sim/python.sh`）裡，讓 consumer repos 可以在容器內跑 Python unit / integration test。runtime `devel` 階段不裝這些依賴，保持精簡 — 測試工具只在 `devel-test` 才付出大小成本。

用法：

```bash
just docker build -t devel-test                                     # 建置 devel-test 階段
just docker exec -t devel-test /isaac-sim/python.sh -m pytest test/unit/
just docker exec -t devel-test /isaac-sim/python.sh -m pytest --cov=<pkg> test/
```

系統的 `python3` 無法安裝這些套件（Isaac base image 的 PEP 668 擋 `pip`）— 一律走 `/isaac-sim/python.sh -m pytest ...`，不要用 `pytest ...`。

GPU integration test（需要 Isaac Sim 真的開機，例如 camera → ROS 2 headless smoke，#127）走 `test` compose service；該 service 的 NVIDIA GPU reservation 來自 `setup.conf` 的 `[stage:devel-test]` override（`deploy.gpu_mode = force`，base #493）：

```bash
just docker run -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_camera_ros2_headless.py
```

判定標準是 stdout marker 行（`[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]`），不是 return code — Kit 的 `app.close` 會呼叫 `_exit(0)`。詳見 [doc/test/TEST.md](test/TEST.md)。
