# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 開發環境，以 [`ycpss91255-docker/template`](https://github.com/ycpss91255-docker/template) 為基礎建立。

Image scope 限定 Isaac Sim 本體；ROS 2 bridge、下游應用、其他疊加工具放在相鄰的 docker folder（例如 `isaac-ros/`）。

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

> `run.sh -t {headless|gui}` 快捷功能在 [template issue #215](https://github.com/ycpss91255-docker/template/issues/215) 推進中。落地前先用上述手動 launcher。

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
