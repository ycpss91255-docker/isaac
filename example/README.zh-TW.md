# example/ -- base repo 的可執行範例（onboarding 導覽）

這個目錄是 base repo 附帶的單一可執行範例，同時兼任 scaffold 模板
（ADR-0017）。新手或 agent 拿到的就是它：從零跑到一個 live camera topic，
再換成自己的機器人，**全程不需要讀 framework 原碼**。

- [`sim/`](sim/) -- Isaac 端：`camera_bot` URDF、三檔 scene、per-sensor 的
  `custom.yaml`，以及 `example_driver.py`（發佈 camera stream、用 `/cmd_vel`
  驅動底盤）。
- [`ros2/`](ros2/) -- 應用端：訂閱 camera 並發佈 `/cmd_vel` 的最小 ROS 2
  套件。見 [`ros2/README.zh-TW.md`](ros2/README.zh-TW.md)。

## Onboarding 導覽（M5 路徑）

Onboarding 成功的衡量標準是：scaffold 一個 workspace、跑起來、換機器人、
換 sensor —— 全部只靠改這個 `example/` 內的檔案，絕不靠讀 `framework/`
原碼。底下三個任務正是 agent-proxy gate 所驗的內容
（`doc/onboarding/agent-proxy-gate.md`）。

### 1. 第一筆 topic（scaffold -> run）

Scaffold 一個 consumer workspace；base 範例已預填進 `src/isaac/`，開箱即跑：

```bash
script/new-workspace.sh my-robot-ws
cd my-robot-ws
just setup && just build && just run
```

`just run` 啟動 example driver；camera topic
`/camera_bot/camera/color/image_raw` 會出現。從另一個 ROS 2 container 確認：

```bash
docker run --rm --net=host ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  ros2 topic echo --once /camera_bot/camera/color/image_raw'
```

第一筆 frame 就是 M1「time-to-first-topic」里程碑。

### 2. 換 URDF（換成自己的機器人）

機器人模型是 [`sim/model/camera_bot.urdf`](sim/model/camera_bot.urdf)
（兩個 link：`base_link` 底盤 + `camera_link` 掛載點）。要換成另一個最小
機器人：

1. 把你的 URDF 放進 `sim/model/<your_robot>.urdf`。保留一個 `base_link`
   （會隨 `/cmd_vel` 移動的本體）以及一個可掛 camera 的 link。
2. 把它重新 import 成 USD 一次（importer 跑在自己的 SimulationApp，所以
   輸出 USD 會 commit）：`just import-model sim/model/<your_robot>.urdf`。
3. 把 [`sim/scene/robot.yaml`](sim/scene/robot.yaml) 指向新模型：設定
   `source_urdf` 與 `model` 為你的檔案，`robot.name` 為你的機器人名稱。

再 `just run` 一次 —— 你的機器人啟動，camera topic 照樣發佈。

### 3. 換 sensor（in scope）

camera 由 per-sensor YAML
[`sim/config/sensor/custom.yaml`](sim/config/sensor/custom.yaml) 設定。
以下都是 in-scope 的修改 —— 改檔案、重跑，不碰任何 framework 程式碼：

- **解析度 / fps**：改 `sensors[0].resolution`（例如 `[640, 480]`）或
  `sensors[0].fps`。
- **Topic override**：改 `ros.topic_prefix`（發佈的 topic 與 `ros2/` 內對應
  的 subscriber 都會跟著變）。
- **加第二顆 camera**：在 `sensors:` 底下再 append 一個 entry，給新的
  `name` 與自己的 `resolution` / `fov`；每個 entry 各產生一個
  `UsdGeom.Camera` 與各自的 image topic。

## 超出範圍 / 尚未實作

schema 形狀從第一天就鎖死，但 framework 只實作範例用到的子集（ADR-0017，
決策 C：「介面凍結、實作漸進」）。加 **lidar** 或 **imu** sensor 是一個
**刻意的 out-of-scope 邊界**：host 端的 YAML 驗證會接受這些 category，但
Isaac 端的 build path 會 **raise `NotImplementedError`**，直到真有需求才補。
這是設計如此、不是 bug —— 它就是上面 in-scope sensor swap 的明確邊界。

| Sensor swap | 狀態 |
|---|---|
| camera 解析度 / fps / topic override / 第二顆 camera | in scope（現在就能用） |
| **lidar** / **imu** sensor category | **out of scope -- raise `NotImplementedError`** |
| ZED X 立體（`type: zed`） | out of scope -- raise `NotImplementedError`（需要 Stereolabs extension） |

如果你需要 lidar 或 imu，那是一個 framework feature request（開 issue），
不是 onboarding 期間靠改 `framework/` 原碼就該解掉的事。

## License

Apache-2.0。見 [LICENSE](../LICENSE)。

## 翻譯

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
