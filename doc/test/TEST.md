# TEST.md

**10 tests** total.

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
| `bundled ROS 2 humble lib is readable (Isaac Sim internal libs path)` | `/isaac-sim/exts/isaacsim.ros2.bridge/humble/lib/librmw_fastrtps_cpp.so` present + readable through `isaac-sim` group |
| `bundled ROS 2 humble rclpy is readable (Python 3.11 binding)` | `/isaac-sim/exts/isaacsim.ros2.bridge/humble/rclpy/rclpy` present, kit-side `import rclpy` resolves here |
