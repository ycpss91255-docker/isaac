# ROS 2 Bridge Pub/Sub 煙霧測試

> 跨容器 DDS 通不通的最小驗證：Isaac 容器內 publisher / subscriber 各跑一次，
> 從第二個 `ros:humble` sibling container 對接 `ros2 topic echo` / `ros2 topic pub`。
> 不依賴 OpenBase USD、不需要 Action Graph，純粹確認 `isaacsim.ros2.bridge`
> 在當前環境（image / fastdds.xml / `ROS_DOMAIN_ID`）能跨 container 走通。

---

## 為什麼用 Script Editor 不用 standalone

| 路徑 | 載入方式 | 穩定性 |
|------|---------|------|
| **Script Editor（建議）** | `./run.sh -t headless -d` 起 kit (`runheadless.sh -v` → `isaacsim.exp.full.streaming.kit`)，bridge 由 kit experience 預載 | M1 已驗，跨 container DDS 通 |
| Standalone `python.sh` | `isaacsim.exp.base.python.kit` 不預載 bridge，要 Python `enable_extension(...)` 後手動拉起 | Isaac Sim 5.1 已知 bug ([IsaacSim#228](https://github.com/isaac-sim/IsaacSim/issues/228))：bridge + livestream 同 process 約 2 秒後 random segfault |

底下流程一律走 Script Editor 路徑。Standalone 版本（`ros2_test_pub_standalone.py` / `ros2_test_sub_standalone.py`）留檔做為 6.0 升級後的對照樣本，**5.1 不要當主驗證路徑**。

---

## 前置條件

- `isaac_ws/src/docker/` 已 `./build.sh` 過，image 含 `config/ros2/fastdds.xml`
- Host 已可拉 `ros:humble` image（首次跑 `docker pull ros:humble` 暖一下）
- Docker daemon 跑得起來，`docker ps` OK
- 沒有別的 process 占用 ROS_DOMAIN_ID=0（多人共用 server 時需要協調）

確認 docker repo `setup.conf [environment]` 已含三 key（M1 已加，後續不需動）：

```
env_3 = ROS_DOMAIN_ID=0
env_4 = RMW_IMPLEMENTATION=rmw_fastrtps_cpp
env_7 = FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml
```

---

## Step 1 — 起 Isaac headless 容器

```bash
cd isaac_ws/src/docker
./stop.sh                  # 確保乾淨環境
./run.sh -t headless -d    # 背景啟 isaac kit + WebRTC 8211
```

`-t headless` 用 `runheadless.sh -v`（experience 內含 bridge 預載）；`-d` 背景跑，
不接管當前 terminal。

啟動後 WebRTC client 連 `localhost:8211/streaming/webrtc-client` 可看到空 stage
（這是 Script Editor 入口）。

---

## Step 2 — 載入 publisher（Isaac → sibling）

WebRTC client 內：

1. 上方選單 **Window → Script Editor** 開 Script Editor
2. **File → Open** 選 `/home/yunchien/work/src/script/ros2_test_pub.py`
3. **Ctrl+Enter** 跑（或選單 **Run**）

Script Editor 主控台應出現：

```
[ros2_test_pub] publishing /isaac/test at every 60 ticks (~1 Hz)
[ros2_test_pub] verify from sibling container:
  ...
```

Script 內已自動 `timeline.play()`，不需要手按播放鍵。

> Re-Run safe — 同一 file 重複 Ctrl+Enter 會先回收舊 node / 舊 update subscription
> 再起新的，不會殘留多個 publisher。

---

## Step 3 — Sibling container `ros2 topic echo`

另開一個 host terminal：

```bash
docker run --rm --net=host --ipc=host \
    -e ROS_DOMAIN_ID=0 \
    -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    -v "$(pwd)/isaac_ws/src/docker/config/ros2/fastdds.xml:/fastdds.xml:ro" \
    -e FASTRTPS_DEFAULT_PROFILES_FILE=/fastdds.xml \
    ros:humble bash -c '
        source /opt/ros/humble/setup.bash
        ros2 topic list
        ros2 topic echo /isaac/test --once
    '
```

預期：

```
/isaac/test
/parameter_events
/rosout
---
data: hello 60
---
```

確認到 `/isaac/test` 與 `hello N` 訊息即通過 publisher 方向。

---

## Step 4 — 載入 subscriber（sibling → Isaac）

回 Script Editor：

1. **File → Open** 選 `/home/yunchien/work/src/script/ros2_test_sub.py`
2. **Ctrl+Enter**

Script Editor 主控台會出現：

```
[ros2_test_sub] subscribed to /host/test; pub from sibling container:
  ...
```

> `ros2_test_sub.py` 跟 `ros2_test_pub.py` 用不同 `_g["_ros2_test_*_state"]` key，
> **兩個 script 可同時跑在同一個 Script Editor 內**，不會互相清掉對方狀態。

---

## Step 5 — Sibling container `ros2 topic pub`

```bash
docker run --rm --net=host --ipc=host \
    -e ROS_DOMAIN_ID=0 \
    -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    -v "$(pwd)/isaac_ws/src/docker/config/ros2/fastdds.xml:/fastdds.xml:ro" \
    -e FASTRTPS_DEFAULT_PROFILES_FILE=/fastdds.xml \
    ros:humble bash -c '
        source /opt/ros/humble/setup.bash
        ros2 topic pub /host/test std_msgs/String "{data: hello-from-host}" --once
    '
```

Isaac Script Editor 主控台預期跳出：

```
[ros2_test_sub] /host/test <- 'hello-from-host'
```

到此 sub 方向也通。

---

## Step 6 — 收尾

Script Editor 內：

- 各自 `Ctrl+Enter` 重跑 `ros2_test_pub.py` / `ros2_test_sub.py` 一次即停舊 instance（內建 cleanup）
- 或直接停 kit：terminal 跑 `./stop.sh`

---

## 通過標準

- [ ] Step 3 sibling `ros2 topic list` 看得到 `/isaac/test`
- [ ] Step 3 sibling `ros2 topic echo /isaac/test --once` 印出 `data: hello N`
- [ ] Step 5 sibling pub 後 Isaac Script Editor 主控台印出 `[ros2_test_sub] /host/test <- 'hello-from-host'`
- [ ] 任一方向看不到 → 進 Troubleshooting

---

## Troubleshooting

| 症狀 | 可能原因 | 處理 |
|------|---------|------|
| `ros2 topic list` 完全沒有 `/isaac/test` | (a) Script Editor 沒按 Ctrl+Enter / Run；(b) `ROS_DOMAIN_ID` 不一致；(c) sibling 沒 `--net=host` | Step 2 重跑、檢查 `docker inspect <isaac-container> -f '{{.Config.Env}}' \| tr ' ' '\n' \| grep ROS`、確認 sibling 命令行有 `--net=host --ipc=host` |
| `ros2 topic list` 有 `/isaac/test`，但 `echo` 卡住沒輸出 | FastDDS SHM transport 跨 container 不穩 | 確認 sibling 有 mount fastdds.xml + `FASTRTPS_DEFAULT_PROFILES_FILE` 指向 mount path（Step 3 / 5 命令範本已含） |
| Isaac Script Editor 主控台 import 失敗 `ModuleNotFoundError: No module named 'rclpy'` | bridge 沒被 experience 預載（不該發生於 `runheadless.sh -v` 路徑） | 確認用 `./run.sh -t headless`，不是 `python.sh`；檢查 `./exec.sh -t headless cat /isaac-sim/apps/isaacsim.exp.full.streaming.kit \| grep ros2.bridge` |
| Isaac Script Editor 主控台 `[Error] [carb]` 載 bridge 失敗 | image 構建異常 / bundled libs 缺檔 | `./exec.sh -t headless ls /isaac-sim/exts/isaacsim.ros2.bridge/humble/` 應看到 `rclpy` / `lib` 等目錄；不全則 `./build.sh --no-cache` 重建 |
| Step 5 sibling pub 後 Script Editor 沒印 callback | (a) Script 沒按 Run；(b) topic name typo；(c) QoS mismatch | re-Run `ros2_test_sub.py`、確認 sibling pub 與 sub 都是 `/host/test`、`ros2 topic info /host/test -v` 看 QoS（默認 reliable+volatile 對得上） |

---

## 參考

- M1 plan：`.claude/plans/isaac-ws-src-docker-docker-iterative-prism.md`（Plan mode 紀錄）
- Action Graph 後續流程：`./action_graph_setup.md`（cmd_vel → OpenBase 移動）
- ROS 2 env 預設：`isaac_ws/src/docker/README.md` 的 ROS 2 environment 表
- FastDDS UDPv4-only profile：`isaac_ws/src/docker/config/ros2/fastdds.xml`
- Standalone 版本（5.1 不穩，留 6.0 對照）：
  - `isaac_ws/src/script/ros2_test_pub_standalone.py`
  - `isaac_ws/src/script/ros2_test_sub_standalone.py`
- Upstream bug：[IsaacSim#228](https://github.com/isaac-sim/IsaacSim/issues/228) bridge + livestream race
