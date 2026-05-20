# Action Graph 一次性 GUI 設定 — cmd_vel 控制 OpenBase

> **DEPRECATED(2026-05-20 起)**:本 Action Graph 路徑在 Isaac Sim 5.1 standalone + bridge ext 組合下會 segfault(見下方 bisection 表),已不採用。實際採用過的替代路徑是 in-kit Script Editor(見 ADR-0002),那條也已在 2026-05-20 被 standalone-with-livestream(ADR-0005)取代。
> 本文件保留當歷史 / segfault 偵測紀錄,**不要再依此 SOP 設定**。新 driver 一律走 `standalone_livestream_workflow.md`。

---

> 本文件記錄**一次性** GUI 操作流程，把 `/cmd_vel` ROS 2 訂閱接到 OpenBase 模型的速度控制。
> 流程完成後 USD 內就包含 Action Graph，**之後日常使用不需要 GUI、不需要 Script Editor**。

---

## 為什麼需要一次性 GUI

### 背景

Isaac Sim 5.1 在 standalone `python.sh` 流程下，**同 process 同時啟用 `isaacsim.ros2.bridge` extension 與載入 USD 時會 random segfault**（典型在 bridge ext 啟動後 ~2 秒）。

實測 bisection（本專案 `isaac_ws/src/script/diag_*.py` + smoke）：

| 組合 | 結果 |
|------|------|
| 純 USD load + APP.update loop | 90s+ 穩定 |
| USD + `omni.isaac.dynamic_control` (set rigid velocity) | 90s+ 穩定 |
| USD + rclpy (Python 內 ros 訂閱) | ~2s crash |
| USD + Action Graph 內含 ROS2SubscribeTwist | ~2s crash |

任何「standalone python.sh + bridge ext + non-trivial USD」組合都炸。

### 為什麼 `./run.sh -t headless -d` 不撞

`./run.sh -t headless -d` 跑的是 `runheadless.sh -v`，**不是** `python.sh` 啟動腳本。它載入 `isaacsim.exp.full.streaming.kit` experience 檔，這個 experience 把 bridge 列在預載清單 — kit 從一開始就把 bridge 拉起來，跟 USD load 順序對得上，**不撞**。

M1 階段 `ros2_test_pub.py` / `ros2_test_sub.py` 走 Script Editor 在這條 kit 上跑，跨 container DDS 都通，就是同一條穩定路徑。

### 解法策略

把 ROS 2 訂閱 + 速度套用邏輯**寫進 USD 的 Action Graph**：

- Bridge 由 kit experience 啟動（穩定路徑）
- Graph 跑在 kit C++ pipeline，**不需要任何 Python 在 standalone 啟動 bridge**
- 日常 run 只要 `./run.sh -t headless -d`，零 GUI 互動

代價：Action Graph 第一次需要在 GUI 內手拉 + 存進 USD。**僅一次**。

### NVIDIA 官方背書

「Action Graph 寫進 USD」**不是 workaround，是 NVIDIA 自己對 Isaac Sim ROS 2 整合的推薦做法**：

#### 1. NVIDIA 官方 sample `Carter_ROS.usd`

Isaac Sim 內建的 Carter 機器人 ROS 2 範例 USD（`Isaac/Samples/ROS2/Robots/Carter_ROS.usd`），**完整的 cmd_vel 訂閱 + telemetry 發佈 + sensor publisher 整套 Action Graph 都已預先存在 USD 內**。

證據在 Isaac Sim source 內的測試 helper：

```python
# /isaac-sim/exts/isaacsim.ros2.bridge/isaacsim/ros2/bridge/tests/common.py
async def add_carter_ros(assets_root_path, prim_path="/Carter"):
    add_reference_to_stage(
        assets_root_path + "/Isaac/Samples/ROS2/Robots/Carter_ROS.usd",
        prim_path,
    )
    # ... (僅做 reference add，不做任何節點建立)
```

NVIDIA 的測試套件直接 `add_reference_to_stage` 載入這個 USD，**不需要任何 Python 端建 graph**。整個 ROS 2 訂閱 / 發佈鏈條都已經 baked-in。NVIDIA 內部測試走的就是「pre-built USD + 加進 stage」這條路。

我們的本流程做的事情完全一樣，只是針對 OpenBase 做一次：把 cmd_vel 訂閱 + base velocity 套用的 graph 烤進 `openbase.usda`，之後 `./run.sh -t headless -d` 載入跟 NVIDIA 載 Carter_ROS.usd 同一個 pattern。

#### 2. Isaac Sim 6.0 官方 standalone tutorial 也走 OmniGraph

[Isaac Sim 6.0 ROS 2 Bridge in Standalone Workflow](https://docs.isaacsim.omniverse.nvidia.com/6.0.0/ros2_tutorials/tutorial_ros2_python.html) 把 ROS 2 pub / sub 的「per-frame 觸發」全部用 OnImpulseEvent OmniGraph 節點處理：

> *"Standalone scripting requires explicit control of the publisher / subscriber execution frequency. Use OnImpulseEvent OmniGraph nodes to manually control execution."*

NVIDIA 在 6.0 文件直接告訴 standalone user：**不要在 Python while-loop 裡 spin rclpy；用 OmniGraph 節點驅動**。

我們現在做的「graph baked into USD + 純 `./run.sh -t headless -d` 載入跑」是 6.0 標準 pattern 的 5.1 對應實現 — graph 烤進 USD（5.1 階段沒程式化建 graph 的乾淨 API），run-time 跟 6.0 一樣是 kit C++ pipeline 跑 graph。

#### 3. Action Graph 是 Isaac Sim 官方的多 backend 訊息整合機制

Isaac Sim 預先提供的 **30+ 個 ROS 2 OmniGraph nodes**（`/isaac-sim/exts/isaacsim.ros2.bridge/.../nodes/*.ogn`）涵蓋：

- `ROS2SubscribeTwist` / `ROS2SubscribePointCloud` / `ROS2SubscribeImage` / `ROS2SubscribeJointState` / ...
- `ROS2PublishOdometry` / `ROS2PublishTransformTree` / `ROS2PublishImage` / `ROS2PublishCameraInfo` / ...

這個節點庫不是「給開發者方便用的選項之一」— Isaac Sim 官方文件、官方範例（Carter / Nova Carter / Franka / 各類 robot ROS 整合範例）**全部走這條 OmniGraph 路徑**。Python 端直 import rclpy 在 standalone 跑事實上是 unsupported pattern（解釋了上游為什麼長期不修這 crash race）。

#### 結論

我們選的 graph-into-USD 路徑：

1. **是 NVIDIA 自己內建範例的同一做法**（Carter_ROS.usd 證據）
2. **是 6.0 standalone tutorial 明文規定的 pattern**（OnImpulseEvent OmniGraph）
3. **是 Isaac Sim ROS 2 整合的官方架構**（30+ 個 node 為證）

短期內 5.1 沒乾淨的程式化 graph builder API，需要一次性 GUI 完成 graph 編輯這步 — 但這條路本身**完全在 NVIDIA 推薦範圍內**，不是不得已的 workaround。

### Isaac Sim 6.0 追蹤

Isaac Sim 6.0 已把 `isaacsim.ros2.bridge` 拆成 4 個 extension（`core`/`nodes`/`ui`/`examples`），standalone tutorial 也改成 OnImpulseEvent OmniGraph 架構 — NVIDIA 等於承認 5.1 這條路是死路。

**6.0 目前限制**：Early Developer Release，要從 GitHub source build；binaries / pip / pre-built container 還沒上 nvcr.io。GA 時間未公告。

GA 後可重評：升 6.0 → 拿掉本 MD 的 GUI 步驟 → 改純腳本路徑。本 MD 屆時可刪除。

---

## 前置條件

1. **isaac docker image 已 build**：

   ```bash
   cd isaac_ws/src/docker
   ./build.sh
   ```

2. **OpenBase USD 已產出**：

   ```bash
   ls isaac_ws/src/model/usd/openbase/openbase.usda
   # 不存在的話:
   ./run.sh -t standalone -d
   ./exec.sh -t standalone /isaac-sim/python.sh \
       /home/yunchien/work/src/script/import_urdf.py \
       --no-fix-base \
       /home/yunchien/work/src/model/urdf/openbase/openbase_minimal.urdf \
       /home/yunchien/work/src/model/usd/openbase/openbase.usda
   ./stop.sh
   ```

   > 預設用 `openbase_minimal.urdf`（單一 base_link rigid body），cmd_vel 直接寫 base velocity。完整 articulation (`openbase.urdf` 32 link) 需要額外的 HolonomicController + ArticulationController 節點鏈，本 MD 暫不涵蓋（B-Phase 真要 mecanum 物理時再補）。

3. **host 上有可推 `/cmd_vel` 的 ROS 2 環境**（一個 `ros:humble` sibling container 即可，本 MD 後段提供）

---

## 一次性 GUI 設定流程

### Step 1 — 啟 headless kit

```bash
cd isaac_ws/src/docker
./stop.sh                 # 收掉殘留
./run.sh -t headless -d   # 啟 runheadless.sh -v
docker ps | grep headless # 確認 Up
```

預期：`yunchien-isaac-headless` Up。kit 跟 bridge extension 都載完約需 30-60 秒。

![kit 啟動完成](image/01_kit_started.png)

### Step 2 — 連 WebRTC client

從 browser 開：

```
http://localhost:8211/streaming/webrtc-client
```

Server 欄填 `localhost`（**不加** `:8011` 或任何 port 後綴）。Click **Connect**。

首次連線可能要 1-3 分鐘編 shader，之後 viewport 才會渲染出來。

![WebRTC 連線成功](image/02_webrtc_connected.png)

### Step 3 — 開 OpenBase USD

在 kit GUI：

1. **File → Open**
2. 路徑輸入：`/home/yunchien/work/src/model/usd/openbase/openbase.usda`
3. 載入完 viewport 應該看到 OpenBase 模型（一塊圓形平台 STL mesh）

> 如果 viewport 黑暗 / 看不到物體：Stage 應該已經有 mesh prim 但沒燈光。先做 Step 3.1 + 3.2 補燈跟地板。

![USD 載入完成](image/03_open_usd.png)

#### Step 3.1 — 加燈

**Create → Lights → Distant Light**

新增 `/World/DistantLight` 後在 Property panel 設 `Intensity = 3000`。

![加 Distant Light](image/03a_add_light.png)

#### Step 3.2 — 加地板

**Create → Physics → Ground Plane** 或

**Window → Physics → Physics Inspector → Add Ground Plane**

新增 `/World/GroundPlane`，自動帶 CollisionAPI。OpenBase 在物理開始後會掉到地板上停住。

![加 Ground Plane](image/03b_add_ground.png)

### Step 4 — 開 Action Graph 編輯器

**Window → Visual Scripting → Action Graph**

底部會跳出 Action Graph 編輯面板。

![Visual Scripting menu](image/04_visual_scripting_menu.png)

### Step 5 — 建立新 Graph

在 Action Graph 面板：

1. Click **New Action Graph**
2. 命名為 `CmdVelGraph`（可改）
3. 確認 graph prim 出現在 Stage 樹的 `/World/ActionGraph` 或類似路徑

![Action Graph 建立完成](image/05_action_graph_created.png)

### Step 6 — 加節點

在 Action Graph 編輯面板，**右鍵 → Create Node**（或拖 Library 中的節點到 canvas）。

依序加 4 個節點：

1. **On Playback Tick** — `omni.graph.action.OnPlaybackTick`（執行流入口；每 frame 觸發）
2. **ROS2 Subscribe Twist** — `isaacsim.ros2.bridge.ROS2SubscribeTwist`（訂閱 `/cmd_vel`，輸出 linear + angular vec3）
3. **Write Prim Attribute** (x2 — 一個寫 linear velocity，一個寫 angular velocity)

![加 ROS2 Subscribe Twist](image/06_add_subscribe_twist.png)

![加 Write Prim Attribute × 2](image/07_add_write_prim_attribute.png)

### Step 7 — 設定節點 inputs

#### Step 7.1 — ROS2 Subscribe Twist

- **inputs:topicName** = `/cmd_vel`
- inputs:queueSize = `10`（預設）
- 其餘留預設

![ROS2 Subscribe Twist 設 topic 名稱](image/07a_topic_name.png)

#### Step 7.2 — Write Prim Attribute (linear)

- **inputs:primPath** = `/open_base/base_link`
- **inputs:name** = `physics:velocity`（UsdPhysics RigidBodyAPI 標準屬性名；如不存在改試 `physxRigidBody:linearVelocity`）
- inputs:usdWriteBack = `True`（預設）

#### Step 7.3 — Write Prim Attribute (angular)

- **inputs:primPath** = `/open_base/base_link`
- **inputs:name** = `physics:angularVelocity`（若上面用 `physxRigidBody:*`，這裡用 `physxRigidBody:angularVelocity`）

![Write Prim Attribute 兩個節點設好](image/07b_write_attrs_set.png)

### Step 8 — 連線

拖 output → input 連接 4 條線：

| 來源 | 目標 |
|------|------|
| `OnPlaybackTick.outputs:tick` | `ROS2SubscribeTwist.inputs:execIn` |
| `OnPlaybackTick.outputs:tick` | `WritePrim(linear).inputs:execIn` |
| `OnPlaybackTick.outputs:tick` | `WritePrim(angular).inputs:execIn` |
| `ROS2SubscribeTwist.outputs:linearVelocity` | `WritePrim(linear).inputs:value` |
| `ROS2SubscribeTwist.outputs:angularVelocity` | `WritePrim(angular).inputs:value` |

> tick 同時 fan-out 到 3 個 execIn（On Playback Tick → 三個下游節點），確保每 frame 訂閱 + 寫兩個 attribute 都會跑。

![完整連線圖](image/08_nodes_connected.png)

### Step 9 — 存 USD

**File → Save**（直接覆寫原 `openbase.usda`）。

> Save 過程會把 Action Graph、light、ground plane 都序列化進 USD 檔。Save 完用 `cat openbase.usda | head -40` 應該看到新增的 graph prim 結構（`def OmniGraph` 或類似）。

![存 USD](image/09_save_usd.png)

### Step 10 — 驗證 graph 跑

#### Step 10.1 — 重啟 container

```bash
cd isaac_ws/src/docker
./stop.sh
./run.sh -t headless -d
```

#### Step 10.2 — Browser 連 WebRTC

`http://localhost:8211/streaming/webrtc-client` → Connect

#### Step 10.3 — Stage 載入後按 Play

WebRTC client viewport 上方有 **▶ Play** 按鈕（或 Spacebar）。按下 → physics 開始模擬。

OpenBase 應該掉到 GroundPlane 上停住。沒有任何 cmd_vel 進來時 base 不動。

#### Step 10.4 — 從 host 推 `/cmd_vel`

另開 terminal：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 \
    -v /home/yunchien/workspace/coreSAM_ws/isaac_ws/src/docker/config/ros2/fastdds.xml:/isaac-sim/fastdds.xml:ro \
    -e FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml \
    ros:humble bash -c 'source /opt/ros/humble/setup.bash && \
        ros2 topic pub /cmd_vel geometry_msgs/Twist "{linear: {x: 0.5}}" -r 10'
```

WebRTC viewport 內 OpenBase 應該開始沿 +x 方向移動，速度約 0.5 m/s。

![teleop 中 OpenBase 移動](image/10_verify_running.png)

#### Step 10.5 — 真實 teleop_twist_keyboard

替代固定 pub，跑互動式 teleop：

```bash
docker run --rm -it --net=host --ipc=host -e ROS_DOMAIN_ID=0 \
    -v /home/yunchien/workspace/coreSAM_ws/isaac_ws/src/docker/config/ros2/fastdds.xml:/isaac-sim/fastdds.xml:ro \
    -e FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml \
    ros:humble bash -c 'apt update && apt install -y ros-humble-teleop-twist-keyboard && \
        source /opt/ros/humble/setup.bash && \
        ros2 run teleop_twist_keyboard teleop_twist_keyboard'
```

按方向鍵控 OpenBase，WebRTC viewport 同步動。

---

## 日常使用流程（不需 GUI、不需 Script Editor）

```bash
cd isaac_ws/src/docker

# 起 kit（已含 graph 在 USD 內）
./run.sh -t headless -d

# WebRTC client 連 localhost:8211 (純觀察, 也可不連)

# 在另外 terminal 推 cmd_vel 或跑 teleop（同上 Step 10.4 / 10.5）

# 收尾
./stop.sh
```

---

## 重做時機

需要重跑本 MD 的 GUI 流程的場景：

1. **重 gen OpenBase USD** — `import_urdf.py` 跑出來的 USD 不含 graph，需要重新依本流程烤
2. **改 graph 結構** — 加新 ROS 2 topic、改 controller、改節點連線
3. **OpenBase URDF 改了 link / joint** — 影響 prim path，Write Prim Attribute 的 target 要重設
4. **升 Isaac Sim 版本** — 6.0 GA 後可全面 migrate 走純腳本路徑，**本 MD 可廢棄**

---

## 參考資料

### 上游 bug 證據

- [IsaacSim issue #228 — ros2 examples in isaacsim with nvidia brev](https://github.com/isaac-sim/IsaacSim/issues/228) — `omni.kit.livestream.webrtc` + `isaacsim.ros2.bridge` 同 process segfault
- [Forum 327272 — ROS2 Bridge Startup Failed on Isaac Sim App Template](https://forums.developer.nvidia.com/t/ros2-bridge-startup-failed-on-isaac-sim-app-template/327272)
- [Forum 349495 — Cannot properly load isaacsim.ros2.bridge extension from standalone script](https://forums.developer.nvidia.com/t/cannot-properly-load-isaacsim-ros2-bridge-extension-from-standalone-script/349495) — glibc malloc corruption during bridge load
- [Forum 369700 — Cannot start IsaacSim 5.1.0 because Ros2 Bridge](https://forums.developer.nvidia.com/t/cannot-start-isaacsim-5-1-0-because-ros2-bridge/369700) — driver 595 不相容（我們 580 不中招但 bridge 問題未解）
- [Forum 370034 — How do I run IsaacSim via python script with ros2 bridge enabled](https://forums.developer.nvidia.com/t/how-do-i-run-isaacsim-via-python-script-with-ros2-bridge-enabled/370034)
- [IsaacLab issue #2870 — Unable to load rclpy in IsaacLab 2.2 with IsaacSim 5 rc3](https://github.com/isaac-sim/IsaacLab/issues/2870)

### Isaac Sim 官方文件

- [Isaac Sim 5.1 ROS 2 Installation](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/install_ros.html)
- [Isaac Sim 5.1 Known Issues](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/overview/known_issues.html)
- [Isaac Sim 6.0 ROS 2 Bridge in Standalone Workflow](https://docs.isaacsim.omniverse.nvidia.com/6.0.0/ros2_tutorials/tutorial_ros2_python.html) — 6.0 的 OnImpulseEvent 替代架構
- [Isaac Sim Release Notes (latest)](https://docs.isaacsim.omniverse.nvidia.com/latest/overview/release_notes.html)

### 內部診斷紀錄

本流程設計依據：

- `isaac_ws/src/script/diag_usd_loop.py` — USD load + APP.update 純跑 90s 穩定
- `isaac_ws/src/script/diag_graph_bridge.py` — 加入 bridge ext + Action Graph 於 standalone 後 ~2s crash 重現
- `isaac_ws/src/script/cmd_vel_planar_standalone.py` — 嘗試 6+ 種 standalone 路徑（dc / SingleRigidPrim / World / signal handler 抑制 / warmup loop），全 random crash
- `isaac_ws/src/script/move_openbase_planar_standalone.py` — 純 dc + USD（無 ROS）90s 穩定，證 PhysX / USD load 本身沒問題

結論：crash 鎖在 standalone python.sh ↔ isaacsim.ros2.bridge ↔ USD 三者交互，**只能繞、不能修**（短期內）。
