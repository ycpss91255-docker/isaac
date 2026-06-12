# example/ros2 -- 应用端 ROS 2 模板

这个目录放的是 base repo ROS 2 示例的**应用端**。Isaac driver
（[`example/sim/`](../sim/)）发布相机图像、并从 `/cmd_vel` 驱动底盘；这里
的包就是消费端的对手方 -- 普通的 ROS 2 节点，跑在另一个 ROS 2 Humble
容器内，**订阅相机**并**发布 `/cmd_vel`**。

这就是「ROS 2 默认双向拓扑」在结构上的体现（ADR-0017 第 6 节）：框架负责
Isaac 端的桥接 wiring；你的应用逻辑写在这边的标准 ROS 2 包里。

提供两种模板让你挑语言：

| 包 | Build type | 语言 | 节点 |
|---|---|---|---|
| [`src/example_app_py`](src/example_app_py/) | `ament_python` | Python | `camera_subscriber`、`cmd_vel_publisher` |
| [`src/example_app_cpp`](src/example_app_cpp/) | `ament_cmake` | C++ | `camera_subscriber`、`cmd_vel_publisher` |

两种模板都「精简但真实」：可被 colcon 构建、`ament_lint` 干净。复制一份、
改名、把节点内容换成你自己的逻辑即可。

## Topic

节点名称与默认 topic 与 Isaac 示例（[`example/sim/`](../sim/)）发布／订阅
的一致，所以两端在同一个 DDS 网络下开箱即连：

| 方向 | Topic | 类型 | 由谁设置 |
|---|---|---|---|
| Isaac -> 应用（inbound） | `/camera_bot/camera/color/image_raw` | `sensor_msgs/Image` | `example/sim/config/sensor/custom.yaml` |
| 应用 -> Isaac（outbound） | `/cmd_vel` | `geometry_msgs/Twist` | `example/sim/scene/scene.yaml` |

## 前置需求

- Docker（示例都在官方 `ros:humble` image 内执行，host 不需要装
  ROS 2）。

## 构建

在本目录（`example/ros2/`）执行：

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble \
  bash -c 'source /opt/ros/humble/setup.bash && colcon build'
```

`colcon` 会在 `src/` 下找到两个包并构建。产物落在 `build/`、`install/`、
`log/`（皆已 gitignore）。

## Lint 与测试

`ament_lint` 通过 `colcon test` 执行（标准 ROS 2 流程）：

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  colcon build &&
  colcon test &&
  colcon test-result --all'
```

干净的执行会报告 `0 errors, 0 failures`（C++ 的 `cppcheck` linter 会被
skip，因为 base image 没有那个可选工具 -- 那是 skip，不是 failure）。

## 对着示例跑

先把 Isaac 示例（见 [`example/sim/`](../sim/)）在一台与本容器共用 DDS
网络的 host 上启动，然后：

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py camera_subscriber'
```

每收到一张相机图像，你会看到一行 `[FRAME OK]` log。在另一个容器发布
运动指令：

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py cmd_vel_publisher'
```

`[CMD_VEL OK]` 各行对应 Isaac driver 收到并应用到底盘的 Twist。C++ 包
用法相同：`ros2 run example_app_cpp camera_subscriber` /
`ros2 run example_app_cpp cmd_vel_publisher`。

完整的 Isaac <-> ament 跨容器往返（节点真的收到 live 的 sim topic）由
GPU 集成测试（#132）断言；这里的模板以 `colcon build` + `ament_lint`
做 hosted 验证，不需要 GPU。

## 改成你自己的

1. 把 `src/example_app_py` 或 `src/example_app_cpp` 复制成你自己的名字。
2. 改包名：目录、`package.xml` 的 `name`，以及（Python）`setup.py` 的
   `package_name` ／内层模块目录，或（C++）`CMakeLists.txt` 的
   `project()`。
3. 把 `camera_topic` ／ `cmd_vel_topic` 参数指向你的 topic（或保留默认值
   来对接示例）。
4. 把节点内容换成你的应用逻辑。

## 许可

Apache-2.0。见 [LICENSE](../../LICENSE)。

## 翻译

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
