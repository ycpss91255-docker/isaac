# example/ros2 -- app-side ROS 2 templates

This directory holds the **app side** of the base-repo ROS 2 example. The
Isaac driver in [`example/sim/`](../sim/) publishes a camera stream and
drives a chassis from `/cmd_vel`; the packages here are the consumer-side
counterpart -- ordinary ROS 2 nodes you run in a sibling ROS 2 Humble
container that **subscribe to the camera** and **publish `/cmd_vel`**.

This is the ROS 2-by-default bidirectional topology embodied structurally
(ADR-0017 section 6): the framework owns the bridge wiring on the Isaac
side; your application logic lives in standard ROS 2 packages over here.

Two templates are provided so you can pick your language:

| Package | Build type | Language | Nodes |
|---|---|---|---|
| [`src/example_app_py`](src/example_app_py/) | `ament_python` | Python | `camera_subscriber`, `cmd_vel_publisher` |
| [`src/example_app_cpp`](src/example_app_cpp/) | `ament_cmake` | C++ | `camera_subscriber`, `cmd_vel_publisher` |

Both templates are minimal but real: colcon-buildable and `ament_lint`-clean.
Copy one, rename it, and replace the node bodies with your own logic.

## Topics

The node names and default topics match what the Isaac example
[`example/sim/`](../sim/) publishes / subscribes, so the two sides connect
out of the box on a shared DDS network:

| Direction | Topic | Type | Set by |
|---|---|---|---|
| Isaac -> app (inbound) | `/camera_bot/camera/color/image_raw` | `sensor_msgs/Image` | `example/sim/config/sensor/custom.yaml` |
| app -> Isaac (outbound) | `/cmd_vel` | `geometry_msgs/Twist` | `example/sim/scene/scene.yaml` |

## Prerequisites

- Docker (the example is exercised inside the official `ros:humble` image;
  you do not need a host ROS 2 install).

## Build

Run from this directory (`example/ros2/`):

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble \
  bash -c 'source /opt/ros/humble/setup.bash && colcon build'
```

`colcon` discovers both packages under `src/` and builds them. Artifacts
land in `build/`, `install/`, `log/` (all gitignored).

## Lint and test

`ament_lint` runs through `colcon test` (the standard ROS 2 path):

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  colcon build &&
  colcon test &&
  colcon test-result --all'
```

A clean run reports `0 errors, 0 failures` (the C++ `cppcheck` linter is
skipped because the optional tool is not in the base image -- that is a
skip, not a failure).

## Run against the example

Bring up the Isaac example (see [`example/sim/`](../sim/)) on a host that
shares a DDS network with this container, then:

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py camera_subscriber'
```

You should see one `[FRAME OK]` log line per received camera frame. In
another container, publish motion:

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py cmd_vel_publisher'
```

The `[CMD_VEL OK]` lines correspond to Twists the Isaac driver receives and
applies to the chassis. The C++ package is identical:
`ros2 run example_app_cpp camera_subscriber` /
`ros2 run example_app_cpp cmd_vel_publisher`.

The full Isaac <-> ament cross-container round-trip (a node actually
receiving the live sim topic) is asserted by the GPU integration test
(#132); the templates here are verified hosted with `colcon build` +
`ament_lint`, no GPU required.

## Make it yours

1. Copy `src/example_app_py` or `src/example_app_cpp` to your own name.
2. Rename the package: the directory, the `name` in `package.xml`, and
   (Python) `package_name` in `setup.py` / the inner module directory, or
   (C++) `project()` in `CMakeLists.txt`.
3. Point the `camera_topic` / `cmd_vel_topic` parameters at your topics
   (or keep the defaults to talk to the example).
4. Replace the node bodies with your application logic.

## License

Apache-2.0. See [LICENSE](../../LICENSE).

## Translations

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
