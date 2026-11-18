# Output mode: one global switch, `ros` or `python`

## Status

Accepted (2026-11-18).

Amends ADR-0023 (Python as sole external interface): the ROS 2 output path
is no longer an `rclpy` consumer of the Python API; it is the native
OmniGraph bridge selected by `ISAAC_OUTPUT_MODE=ros`. The module dependency
direction and the import-safety invariant of ADR-0023 stand. Does **not**
supersede ADR-0017 or ADR-0024.

Basis: the owner's direction of 2026-11-18, recorded in isaac#366.

## Context

ADR-0023 made Python the sole external interface and described ROS 2 as a
downstream consumer layer (`isaac_ros2`, Module 2) that imports `isaac_devkit`
and reads data through the Python API. Issue #365 designs that Python output
API (a hub with per-kind callbacks and a GPU-to-CPU copy only for kinds that
have a consumer); issue #366 asked whether the container should offer ROS 2
and Python output at the same time or one at a time.

Evidence collected in #366:

- **Both paths are buildable from one Python entry point** (Revision 2, and
  the prototype run in the "Prototype result" comment): the native path is
  built with `og.Controller.edit` (`IsaacCreateRenderProduct` plus
  `ROS2CameraHelper`, `ROS2PublishJointState`, `ROS2PublishImu`); the Python
  path registers pure-Python readers. In the prototype run, `python` mode
  delivered 600 RGB frames (uint8, 480x640x3) with 0 `isaacsim.ros2.bridge`
  graph nodes, and `ros` mode delivered 317 `Image` messages to a `ros:humble`
  receiver with RELIABLE QoS, and registering a Python callback in `ros` mode
  raised an error. (Single run per mode, one machine.)
- **Performance does not decide it at 640x480** (the "Round 2 result
  (cam_640)" comment, n=3 per cell, rate limit removed): per-step cost over
  the no-output baseline is +0.60 ms for native ROS and +0.73 ms for pure
  Python uncapped; both hold 30 Hz and 60 Hz with 5.8 ms to 22 ms of p95
  headroom. Larger images and a 200 Hz joint-state/IMU case are unmeasured in
  round 2 (Revision 3). The choice is therefore made on who consumes the data,
  not on speed.
- The layered alternative (Python API plus an own `rclpy` node) was measured
  in round 1 and gets no further work; the owner chose the two modes only.

Round-2 data: https://github.com/ycpss91255-docker/isaac/issues/366#issuecomment-6977277788

## Decision

1. **Exclusive switch: adopted.** One variable, `ISAAC_OUTPUT_MODE`, with the
   values `python` or `ros`, selects exactly one output path for the whole
   container. There is no `both` mode.
   - `ros`: the native Isaac OmniGraph ROS 2 bridge publishes the topics.
     Python receives no data; registering a Python callback raises a clear
     error.
   - `python`: the Python output API (#365) delivers the data. No ROS node is
     created and no ROS runtime is needed.
   - The "Python output plus an `rclpy` consumer layer" arrangement is no
     longer required.
2. **Default `python`**, applied in code when the variable is unset
   (`framework/isaac_devkit/output_mode.py`, `resolve_output_mode`). Any other
   value, including wrong case, empty and `both`, raises `ValueError` naming
   the offending value and the allowed set. No silent fallback.
3. **Config carrier.** The mode is service runtime behaviour, not Docker
   infrastructure, so it belongs in base's env pair: `env.toml` (committed,
   table `[environment]`) with `env.local.toml` (operator, gitignored) as the
   override. It reaches the container as the environment variable through
   base's generated `.env` / `.env.local` and compose `env_file`. The code
   default means the key need not be set anywhere.
   - isaac is pinned to base v0.42.0, whose `env.toml` / `env.local.toml`
     reader is not landed (base#1168). Until isaac adopts a base release that
     ships it (the same dependency as #338), the only supported override is
     the gitignored `.env` overlay, `ISAAC_OUTPUT_MODE=ros`. Do not define the
     key in `.setup.conf` `[environment]` (section-replaced by
     `.setup.conf.local`).
   - Whether an `.env` overlay value overrides a baked value on v0.42.0 is
     UNVERIFIED; avoided by not defining the key in `.setup.conf`.
4. **Boot ordering for `ros` mode.** The `isaacsim.ros2.bridge` extension has
   to be loaded with `--enable` before Kit starts; enabling it later is not
   supported. So the single entry point reads `ISAAC_OUTPUT_MODE` first, and
   only then decides which extensions to enable at boot (the existing
   `IsaacDriver.BOOT_EXTENSIONS` / `boot_extension_kit_args` path). In
   `python` mode the bridge extension is not required. Until #328 moves the
   boot extensions out of `isaac_devkit`, the legacy default list that already
   contains `isaacsim.ros2.bridge` is unchanged, so existing ROS 2 users are
   not broken by the new default.
5. **Single entry point.** `ros` mode is built from the same Python entry
   point as `python` mode (`IsaacDriver` calling `setup_output`); this was
   shown by the prototype run and is covered by the `ros`-mode GPU smoke test.
   No separate "ros mode needs a separate entry" path is needed.

## Ruling on ADR-0023: `isaacsim.ros2.*` node-type strings in `isaac`

ADR-0023 prohibits module-top `import rclpy`, `import rosidl_*` and any
`isaacsim.ros2.*` import in Module 1, allows function-local `isaacsim.ros2.*`
imports only in Module 2 files, and says "the files implementing that bridge
must reside in Module 2".

The `ros`-mode graph names node types such as
`isaacsim.ros2.bridge.ROS2CameraHelper` as **strings** passed to
`og.Controller.edit`. No Python module under `isaacsim.ros2` is imported,
function-locally or otherwise; the extension is resolved by OmniGraph at
runtime. The tests that enforce the invariant
(`test_no_module_top_isaac_import.py`, `test_no_ros_import_in_devkit.py`,
`test_import_safety.py`) inspect imports and still pass.

Ruling:

- **By the letter** (imports), the strings do not breach ADR-0023.
- **By the intent** (the bridge wiring files live in Module 2), they do touch
  the boundary, because the strings are bridge wiring. Strict reading would
  put the `ros`-mode graph builder in `isaac_ros2`, which would force the
  entry point to depend on a downstream package to honour a mode switch that
  the owner placed in `isaac`.
- **Amendment to ADR-0023** (narrow): Module 1 may contain the native-ROS
  output graph builder for `ISAAC_OUTPUT_MODE=ros`, subject to all of:
  1. it lives in a single dedicated module, so it can later move to
     `isaac_ros2` as a file move (the `setup_output` entry reaches it through
     a function-local import);
  2. no ROS package is imported anywhere in Module 1, at module top or inside
     a function: no `rclpy`, `rosidl_*`, `builtin_interfaces` or
     `isaacsim.ros2.*` import. Node-type names appear only as strings;
  3. the existing module-top import guards keep running unchanged.
  The rest of ADR-0023 (dependency direction, `isaac_devkit` has no ROS
  runtime dependency, the legacy `ros_io` / `sensor_ros` / `init_rclpy`
  moves) is unchanged. The legacy ROS 2 pieces in `isaac_devkit` are not
  gated by `ISAAC_OUTPUT_MODE`; their removal stays with #276 / #328.

## Consequences

- **#276 scope.** The "ROS 2 wiring moves out of `isaac_devkit`" work is
  restated: the output side of ROS 2 is the native OmniGraph path selected by
  `ISAAC_OUTPUT_MODE=ros`, not an `rclpy` consumer of the Python API. What
  still moves to `isaac_ros2` is the legacy inbound I/O (`ros_io`), the sensor
  publish wiring of layer (c) (`sensor_ros`) and the `init_rclpy` helper.
- **#328 handoff.** `isaac_ros2` keeps owning the ROS 2 inbound side and may
  take the output graph builder module when it runs standalone. #328 still has
  to decide where `init_rclpy()` and the boot extension list live; with this
  ADR the boot list is derived from the output mode first.
- **No `rclpy` needed for output in either mode.** `python` mode has no ROS
  dependency at all; `ros` mode uses the bridge extension, not `rclpy`.
- **Operations.** A receiver of `ros` mode output should use RELIABLE QoS and
  the UDPv4-only Fast DDS profile (`config/ros2/fastdds.xml`, #367).
- **Verification.** Per-mode behaviour is guarded by GPU integration tests
  (`test_output_mode_python_gpu.py`, `test_output_mode_ros_gpu.py`) and the
  resolver by hosted unit tests, instead of citing the benchmark as the
  long-term guard. The step-time guard (300 steps after warm-up, p95 below
  33.3 ms at 30 Hz) is part of those GPU tests.
- **Known limits.** Propagation of the variable through the official
  `just docker` flow, and the `.env` overlay override on v0.42.0, are
  UNVERIFIED. Round 2 covered only `cam_640`.

## References

- #365 -- Python output API; #366 -- this decision; #367 -- operations notes.
- #276, #328 -- extraction of the ROS 2 layer into `isaac_ros2`.
- #338 -- `setup.local.toml` and base v0.43.0 adoption.
- base ADR-00000037 (env pair), base#1168 (env reader).
- ADR-0017 sections 6 and 8, ADR-0023, ADR-0024.
