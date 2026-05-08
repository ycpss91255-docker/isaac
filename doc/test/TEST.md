# TEST.md

**18 tests** total.

## test/smoke/docker_env.bats (3)

| Test | Description |
|------|-------------|
| `entrypoint.sh is installed and executable` | Entrypoint check |
| `bash is available on PATH` | Shell sanity |
| `fastdds.xml is baked at /isaac-sim/fastdds.xml and world-readable` | Fast DDS profile (UDPv4-only) shipped by this repo's Dockerfile, content sanity-checked for `useBuiltinTransports=false` |

## test/smoke/isaac_smoke.bats (7)

| Test | Description |
|------|-------------|
| `isaac-sim launchers exist and are executable` | `/isaac-sim/runheadless.sh` and `/isaac-sim/runapp.sh` both `0755` |
| `isaac-sim ships Python 3.11 in /isaac-sim/kit/python/bin/python3` | Isolated Python interpreter exists and reports `3.11` |
| `runtime user is host-aligned (not root, not isaac-sim default)` | Container user is the host-UID-aligned `USER_NAME`, not the image default `isaac-sim` (UID 1234) |
| `runtime user is in isaac-sim group (can read /isaac-sim/* mode 0750)` | Group membership unlocks read/exec on Isaac Sim binaries |
| `HOME is writable` | `${HOME}` is owned by the runtime user — required for cache / logs / Documents writes |
| `bundled ROS 2 humble + jazzy libs are both readable` | `librmw_fastrtps_cpp.so` present under both `humble/lib/` and `jazzy/lib/` — image carries both distros; the headless / gui shim picks one via `ARG ROS_DISTRO` |
| `bundled ROS 2 humble + jazzy rclpy are both readable (Python 3.11)` | `rclpy/` Python bindings present under both distros; kit-side `import rclpy` resolves to whichever the bridge extension activates |

## test/smoke/isaac_ros_env_wrapper.bats (8)

| Test | Description |
|------|-------------|
| `wrapper exists and is executable` | `/usr/local/bin/isaac-ros-env-wrapper.sh` 0755 |
| `/etc/isaac/ros-distro is baked with humble (default ARG)` | Const file written from `ARG ROS_DISTRO` at build time |
| `wrapper exports ROS_DISTRO from /etc/isaac/ros-distro` | Wrapper reads file and exports |
| `wrapper exports LD_LIBRARY_PATH derived from ROS_DISTRO` | Wrapper exports `/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` |
| `wrapper hard-overrides runtime ROS_DISTRO env` | `ROS_DISTRO=jazzy ./wrapper bash -c 'echo ROS_DISTRO'` still prints `humble` — runtime `-e` ineffective on headless / gui |
| `wrapper passes args verbatim to wrapped command` | `./wrapper echo arg1 arg2 arg3` → `arg1 arg2 arg3` |
| `devel stage ENV ROS_DISTRO is baked (soft)` | Devel interactive shell sees `ROS_DISTRO=humble` from Dockerfile `ENV` |
| `devel stage ENV LD_LIBRARY_PATH points to baked humble lib` | Same — `ENV LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` interpolated at build time |
