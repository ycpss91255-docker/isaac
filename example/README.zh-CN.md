# example/ -- base repo 的可运行示例（onboarding 导览）

这个目录是 base repo 附带的单一可运行示例，同时兼任 scaffold 模板
（ADR-0017）。新手或 agent 拿到的就是它：从零跑到一个 live camera topic，
再换成自己的机器人，**全程不需要读 framework 源码**。

- [`sim/`](sim/) -- Isaac 端：`camera_bot` URDF、三档 scene、per-sensor 的
  `custom.yaml`，以及 `example_driver.py`（发布 camera stream、用 `/cmd_vel`
  驱动底盘）。
- [`ros2/`](ros2/) -- 应用端：订阅 camera 并发布 `/cmd_vel` 的最小 ROS 2
  包。见 [`ros2/README.zh-CN.md`](ros2/README.zh-CN.md)。

## Onboarding 导览（M5 路径）

Onboarding 成功的衡量标准是：scaffold 一个 workspace、跑起来、换机器人、
换 sensor —— 全部只靠改这个 `example/` 内的文件，绝不靠读 `framework/`
源码。下面三个任务正是 agent-proxy gate 所验的内容
（`doc/onboarding/agent-proxy-gate.md`）。

### 1. 第一条 topic（scaffold -> run）

Scaffold 一个 consumer workspace；base 示例已预填进 `src/isaac/`，开箱即跑：

```bash
script/new-workspace.sh my-robot-ws
cd my-robot-ws
just setup && just build && just run
```

`just run` 启动 example driver；camera topic
`/camera_bot/camera/color/image_raw` 会出现。从另一个 ROS 2 container 确认：

```bash
docker run --rm --net=host ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  ros2 topic echo --once /camera_bot/camera/color/image_raw'
```

第一条 frame 就是 M1「time-to-first-topic」里程碑。

### 2. 换 URDF（换成自己的机器人）

机器人模型是 [`sim/model/camera_bot.urdf`](sim/model/camera_bot.urdf)
（两个 link：`base_link` 底盘 + `camera_link` 挂载点）。要换成另一个最小
机器人：

1. 把你的 URDF 放进 `sim/model/<your_robot>.urdf`。保留一个 `base_link`
   （会随 `/cmd_vel` 移动的本体）以及一个可挂 camera 的 link。
2. 把它重新 import 成 USD 一次（importer 跑在自己的 SimulationApp，所以
   输出 USD 会 commit）：`just import-model sim/model/<your_robot>.urdf`。
3. 把 [`sim/scene/robot.yaml`](sim/scene/robot.yaml) 指向新模型：设定
   `source_urdf` 与 `model` 为你的文件，`robot.name` 为你的机器人名称。

再 `just run` 一次 —— 你的机器人启动，camera topic 照样发布。

### 3. 换 sensor（in scope）

camera 由 per-sensor YAML
[`sim/config/sensor/custom.yaml`](sim/config/sensor/custom.yaml) 设定。
以下都是 in-scope 的修改 —— 改文件、重跑，不碰任何 framework 代码：

- **分辨率 / fps**：改 `sensors[0].resolution`（例如 `[640, 480]`）或
  `sensors[0].fps`。
- **Topic override**：改 `ros.topic_prefix`（发布的 topic 与 `ros2/` 内对应
  的 subscriber 都会跟着变）。
- **加第二颗 camera**：在 `sensors:` 底下再 append 一个 entry，给新的
  `name` 与自己的 `resolution` / `fov`；每个 entry 各产生一个
  `UsdGeom.Camera` 与各自的 image topic。

## 超出范围 / 尚未实现

schema 形状从第一天就锁死，但 framework 只实现示例用到的子集（ADR-0017，
决策 C：「接口冻结、实现渐进」）。加 **lidar** 或 **imu** sensor 是一个
**刻意的 out-of-scope 边界**：host 端的 YAML 校验会接受这些 category，但
Isaac 端的 build path 会 **raise `NotImplementedError`**，直到真有需求才补。
这是设计如此、不是 bug —— 它就是上面 in-scope sensor swap 的明确边界。

| Sensor swap | 状态 |
|---|---|
| camera 分辨率 / fps / topic override / 第二颗 camera | in scope（现在就能用） |
| **lidar** / **imu** sensor category | **out of scope -- raise `NotImplementedError`** |
| ZED X 立体（`type: zed`） | out of scope -- raise `NotImplementedError`（需要 Stereolabs extension） |

如果你需要 lidar 或 imu，那是一个 framework feature request（开 issue），
不是 onboarding 期间靠改 `framework/` 源码就该解掉的事。

## License

Apache-2.0。见 [LICENSE](../LICENSE)。

## 翻译

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
