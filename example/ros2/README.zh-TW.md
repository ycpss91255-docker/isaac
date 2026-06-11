# example/ros2 -- 應用端 ROS 2 範本

這個目錄放的是 base repo ROS 2 範例的**應用端**。Isaac driver
（[`example/sim/`](../sim/)）發布相機影像、並從 `/cmd_vel` 驅動底盤；這裡
的套件就是消費端的對手方 -- 一般的 ROS 2 節點，跑在另一個 ROS 2 Humble
容器內，**訂閱相機**並**發布 `/cmd_vel`**。

這就是「ROS 2 預設雙向拓樸」在結構上的體現（ADR-0017 第 6 節）：框架負責
Isaac 端的橋接 wiring；你的應用邏輯寫在這邊的標準 ROS 2 套件裡。

提供兩種範本讓你挑語言：

| 套件 | Build type | 語言 | 節點 |
|---|---|---|---|
| [`src/example_app_py`](src/example_app_py/) | `ament_python` | Python | `camera_subscriber`、`cmd_vel_publisher` |
| [`src/example_app_cpp`](src/example_app_cpp/) | `ament_cmake` | C++ | `camera_subscriber`、`cmd_vel_publisher` |

兩種範本都「精簡但真實」：可被 colcon 建置、`ament_lint` 乾淨。複製一份、
改名、把節點內容換成你自己的邏輯即可。

## Topic

節點名稱與預設 topic 與 Isaac 範例（[`example/sim/`](../sim/)）發布／訂閱
的一致，所以兩端在同一個 DDS 網路下開箱即連：

| 方向 | Topic | 型別 | 由誰設定 |
|---|---|---|---|
| Isaac -> 應用（inbound） | `/camera_bot/camera/color/image_raw` | `sensor_msgs/Image` | `example/sim/config/sensor/custom.yaml` |
| 應用 -> Isaac（outbound） | `/cmd_vel` | `geometry_msgs/Twist` | `example/sim/scene/scene.yaml` |

## 前置需求

- Docker（範例都在官方 `ros:humble` image 內執行，host 不需要裝
  ROS 2）。

## 建置

在本目錄（`example/ros2/`）執行：

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble \
  bash -c 'source /opt/ros/humble/setup.bash && colcon build'
```

`colcon` 會在 `src/` 下找到兩個套件並建置。產物落在 `build/`、`install/`、
`log/`（皆已 gitignore）。

## Lint 與測試

`ament_lint` 透過 `colcon test` 執行（標準 ROS 2 流程）：

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  colcon build &&
  colcon test &&
  colcon test-result --all'
```

乾淨的執行會回報 `0 errors, 0 failures`（C++ 的 `cppcheck` linter 會被
skip，因為 base image 沒有那個選用工具 -- 那是 skip，不是 failure）。

## 對著範例跑

先把 Isaac 範例（見 [`example/sim/`](../sim/)）在一台與本容器共用 DDS
網路的 host 上啟動，然後：

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py camera_subscriber'
```

每收到一張相機影像，你會看到一行 `[FRAME OK]` log。在另一個容器發布
運動指令：

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py cmd_vel_publisher'
```

`[CMD_VEL OK]` 各行對應 Isaac driver 收到並套用到底盤的 Twist。C++ 套件
用法相同：`ros2 run example_app_cpp camera_subscriber` /
`ros2 run example_app_cpp cmd_vel_publisher`。

完整的 Isaac <-> ament 跨容器來回（節點真的收到 live 的 sim topic）由
GPU 整合測試（#132）斷言；這裡的範本以 `colcon build` + `ament_lint`
做 hosted 驗證，不需要 GPU。

## 改成你自己的

1. 把 `src/example_app_py` 或 `src/example_app_cpp` 複製成你自己的名字。
2. 改套件名：目錄、`package.xml` 的 `name`，以及（Python）`setup.py` 的
   `package_name` ／內層模組目錄，或（C++）`CMakeLists.txt` 的
   `project()`。
3. 把 `camera_topic` ／ `cmd_vel_topic` 參數指向你的 topic（或保留預設值
   來對接範例）。
4. 把節點內容換成你的應用邏輯。

## 授權

Apache-2.0。見 [LICENSE](../../LICENSE)。

## 翻譯

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
