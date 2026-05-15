# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 開發環境，以 [`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（前身為 `ycpss91255-docker/template`）為基礎建立。

Image scope 涵蓋 Isaac Sim 本體，加上其內建 ROS 2 bridge 跨容器通訊所需的 env wiring。下游 application node（CoreSAM、AGV bring-up）以及對接 Noetic 的 ROS 1 / ROS 2 bridge 放在相鄰的 docker folder。

## 前置需求

- NVIDIA driver `>= 580.65.06`（Isaac Sim 5.1 最低需求）
- GPU `>= RTX 4080`（或同等級），VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- 約 20 GB 空閒空間給 NGC image；首次啟動後 cache 會再長 5–10 GB

NGC image（`nvcr.io/nvidia/isaac-sim:5.1.0`）公開可拉，不需 `docker login nvcr.io`。

## Quick Start

> **首次必跑：** `./build.sh` **之前**先跑 `./script/init_isaac_dirs.sh`。沒跑的話 docker daemon 會以 **root** 身份 mkdir cache mount 點，導致容器內非 root user 無法寫入，Isaac Sim 啟動失敗。

```bash
./script/init_isaac_dirs.sh   # 首次必跑，建好 8 個 host-owned cache 目錄
./build.sh                    # build devel stage（約 16 GB image）
./run.sh                      # 進 devel 容器互動 shell
```

容器內：

```bash
/isaac-sim/runheadless.sh -v   # WebRTC livestream — 用 Isaac Sim WebRTC Streaming Client 連（見下）
/isaac-sim/runapp.sh           # 本機 GUI（需要 X11；host 端先跑 `xhost +local:docker`）
```

> 三個 stage 透過 [base #215](https://github.com/ycpss91255-docker/base/issues/215) auto-emit 為 profile-gated compose service：`headless`（ENTRYPOINT `runheadless.sh -v`，WebRTC livestream）、`gui`（ENTRYPOINT `runapp.sh`，X11）、`standalone`（無 ENTRYPOINT，idle — 搭配 `./exec.sh -t standalone /isaac-sim/python.sh <script>` 跑 standalone Python workflow，腳本內 `SimulationApp({"livestream": 2})` 啟自己的 kit + WebRTC server）。使用 `./run.sh -t <stage> -d`。上面的手動 launcher 仍可用於 ad-hoc 情境。

## 連接 WebRTC livestream

Isaac Sim 5.1 用 NVCF（`omni.services.livestream.nvcf`）livestream 協定，**舊版的瀏覽器 viewer 已移除**，只能用桌面 client 連：

1. 從 [NVIDIA 文件 — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html) 下載 **Isaac Sim WebRTC Streaming Client (1.1.5)**。1.1.5 是 5.1 的最新版。
2. 容器內 `runheadless.sh -v` 跑著時，啟動 client，輸入 Server: `<server-ip>`（同機用 `localhost`，遠端用 server 的 LAN IP）。**不要加 `:8011` 或任何 port 後綴** — client 會自己挑 signaling / data port；加 port 後綴會走錯 path、看到黑畫面。
3. 按 Connect。首次 shader compile 需要 1–3 分鐘 viewport 才會出畫面。

注意：

- streaming kit app 同時 listen 在 `8011`（NVCF signaling，FastAPI/uvicorn）跟 `49100`（self-host WebRTC）。1.1.5 client 會自己選對的，**不要寫 port**
- **同時只能一個 client 連**（NVIDIA 限制）。第二個連線會被拒
- `setup.conf` 已開 `network_mode: host`，容器內 listen 的 port = host 的 port。Host 防火牆要放行 `8011/tcp` 跟 `49100/tcp`（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` 必須含 `video` — 沒有的話 nvidia-container-runtime 不 mount NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`），server 連得上但畫面 encode 不出來 → 黑畫面。當前 `setup.conf` 已加
- Server 端確認 listener：`ss -tln | grep -E ':8011|:49100'` 應看到兩個 `LISTEN`

## ROS 2 bridge（內建，build-time distro）

Isaac Sim 5.1 在 `/isaac-sim/exts/isaacsim.ros2.bridge/{humble,jazzy}/` 同時內建 Humble 與 Jazzy 兩套 ROS 2 libraries，皆走 Python 3.11 rclpy，與 kit 內嵌 interpreter 一致。**本 image 在 build-time hard-bake distro 選擇** — 透過 `setup.conf [build] arg_N=ROS_DISTRO=<value>`（預設 `humble`，CoreSAM 對齊）。

Bridge extension `isaacsim.ros2.bridge` 透過預設 kit experience（`isaacsim.exp.full.kit` → `isaac.startup.ros_bridge_extension`）自動載入。`runheadless.sh` / `runapp.sh` 不需要加 `--enable` flag。

`setup.conf [environment]` 內 distro-agnostic env wiring：

| 變數 | 值 | 用途 |
|------|----|------|
| `ROS_DOMAIN_ID` | `0` | 小團隊預設值；多人共用 host 時調高 |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | 明確指定 FastDDS，不繼承 host |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4-only profile（跨容器 DDS reliable，避開 SHM flakiness）|

### Distro 選擇（build-time、hard-baked）

Dockerfile 的 `ARG ROS_DISTRO=humble` 接到 `setup.conf [build]`。Build 時值會被寫進 `/etc/isaac/ros-distro`，且 `script/isaac-ros-env-wrapper.sh` 會 install 到 `/usr/local/bin/`。`headless` 與 `gui` 兩個 stage 把 `ENTRYPOINT` 設成這個 wrapper — 每次 container 啟動時 wrapper 從 baked file 讀取並無條件 re-export `ROS_DISTRO` 與 `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib`，因此 production paths 上的 runtime `-e ROS_DISTRO=...` flag **無效**。

`devel` stage 透過 Dockerfile `ENV` soft-bake 同樣兩個值（互動 shell 預設拿到，devs 仍可 `export ROS_DISTRO=...` 實驗）。

切到 jazzy：

```bash
./setup.sh remove build.arg "ROS_DISTRO=humble"
./setup.sh add build.arg "ROS_DISTRO=jazzy"
./build.sh           # 重 build 帶上新 ARG（只有受影響 layer 重 build，~10s）
./run.sh -t headless -d
```

Jazzy 路徑跟 Isaac 24.04 自動預設對齊（LTS 至 2029）— 已知 caveat：jazzy on noble 有 Python 3.11/3.12 混搭與 Nav2 路徑粗糙的問題，目前在 NVIDIA 論壇追蹤中，預期在 Isaac Sim 6.0 修順。

### 驗證跨容器 DDS

跑 `./run.sh -t headless -d`（帶 humble 覆蓋 env）並用 WebRTC client 連線後，打開 Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run。腳本會自動按 Play（publisher 只在 timeline 播放時才發），開始往 `/isaac/test` 發 `std_msgs/String "hello N"`。

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

`isaac_ws/src/script/` 同時放 in-kit Script Editor 版本與 standalone 版本（透過 `SimulationApp({"livestream": 2})` 啟自己的 kit）。standalone 走 `./run.sh -t standalone` + `./exec.sh -t standalone /isaac-sim/python.sh <script>` — Ctrl+C 透過 SIGINT handler 乾淨退出，不需要 Script Editor UI。

| In-kit（Script Editor → File → Open → Run） | Standalone（`./exec.sh -t standalone /isaac-sim/python.sh <path>`） |
|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py` |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py` |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py` |
| （無 in-kit 版本） | `cmd_vel_planar_standalone.py` — 訂閱 `/cmd_vel` (geometry_msgs/Twist) → OpenBase 平面移動 |

使用 pattern：

```bash
./run.sh -t standalone -d   # idle kit 容器（沒 runheadless ENTRYPOINT）
./exec.sh -t standalone /isaac-sim/python.sh /home/yunchien/work/src/script/<name>_standalone.py
# Browser: localhost:8211/streaming/webrtc-client 看 stage
# 在 exec session 按 Ctrl+C 乾淨殺 script，容器仍 idle
./stop.sh                   # 收尾
```

`headless` 與 `standalone` stage **不能同時跑** — 兩個都 bind WebRTC port 8211。每次選一個。

## Cache 路徑

所有 Isaac Sim runtime state 都持久化在 host 端的 `${WS_PATH}/isaac-sim/`（即 `isaac_ws/isaac-sim/`）：

| Host | Container | 用途 |
|------|-----------|------|
| `isaac-sim/cache/kit` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/cache/ov` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache（主要是 shader 編譯產物）|
| `isaac-sim/cache/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/cache/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/cache/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents（USD scenes 等）|

首次 headless 啟動需 1–3 分鐘編譯 shader；之後啟動 cache hit `< 30 秒`。

## 容器 User

容器以對齊 host UID 的非 root user 跑（`USER_NAME` 從 `.env` 讀，預設 UID 1000）。該 user 被加進 image 的 `isaac-sim` group，可讀取 `/isaac-sim/*`（mode `0750`）。透過 `/home/${USER_NAME}/work`（mount 到 host `${WS_PATH}`）寫的檔案會保留 host 端 owner，不需 `chown`。

## EULA

`ACCEPT_EULA=Y` 與 `PRIVACY_CONSENT=Y` 透過 `setup.conf [environment]` 注入。注意：Isaac Sim 5.1 改用 `OMNI_ENV_PRIVACY_CONSENT` 讀取 privacy consent（環境變數名稱跟舊版不同）；目前設的 `PRIVACY_CONSENT=Y` 無害但實際沒作用，要 telemetry opt-in 請另設正確的變數。

## Smoke Tests

詳見 [doc/test/TEST.md](test/TEST.md)。
