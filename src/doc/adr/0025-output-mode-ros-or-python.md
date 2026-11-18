# Output mode: one global switch, `ros` or `python`

## Status

Proposed (2026-11-18).

Records the parts of the owner's 2026-11-18 direction (isaac#366) that are
already decided. One question is still open (see "Open question"); the ADR
moves to Accepted once it is settled. Does **not** supersede ADR-0017,
ADR-0023 or ADR-0024. ADR-0023 is touched only through the open question
below.

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
   point as `python` mode (shown by the prototype run, where the graph was
   built in `isaac`; the placement is the open question above). The `ros`-mode
   GPU smoke test will confirm it in the repo.
6. **No `rclpy` consumer layer.** `python` mode has zero ROS dependency and
   the "Python output plus an `rclpy` consumer in `isaac_ros2`" arrangement
   is cancelled.

## Open question: where does the `ros`-mode OmniGraph wiring live?

Not decided here. The `ros`-mode output graph (and, by extension, the ROS 2
inbound graph of `ros_io`) is built with `og.Controller.edit` from node-type
strings such as `isaacsim.ros2.bridge.ROS2CameraHelper`. No Python module
under `isaacsim.ros2` is imported; OmniGraph resolves the extension at
runtime. ADR-0023 prohibits module-top `rclpy` / `rosidl_*` /
`isaacsim.ros2.*` imports in Module 1 (`isaac_devkit`), allows function-local
`isaacsim.ros2.*` imports only in Module 2 (`isaac_ros2`), and says the files
implementing the bridge must reside in Module 2.

| Option | Where the graph builder lives | Effect on ADR-0023 |
|---|---|---|
| A. In `isaac` | One dedicated module in `isaac_devkit`, no ROS import anywhere (strings only), reached from `setup_output` by a function-local import | By the letter (imports) no breach; by the intent (bridge wiring in Module 2) it needs a narrow amendment of ADR-0023 allowing node-type strings in one module. Single entry point stays inside `isaac`. |
| B. In `isaac_ros2` | `isaac_ros2` provides the graph builder; `isaac` calls it when `ISAAC_OUTPUT_MODE=ros` (optional import, absent in `python` mode) | ADR-0023 stands unchanged (`isaacsim.ros2.*` only in Module 2). `isaac` gains a call-out dependency on a downstream package, so the mode switch in `isaac` needs `isaac_ros2` installed for `ros`, and the dependency direction (Module 2 imports Module 1) needs a defined hook (for example a registered builder) to stay intact. |

The prototype showed both modes are buildable from one Python entry point
under either placement as far as the entry is concerned (the run built the
graph in `isaac`; the B arrangement is UNVERIFIED). This ADR does not choose.

## Consequences

- **#276 / #328 scope.** The ROS 2 output side is the native OmniGraph path
  selected by `ISAAC_OUTPUT_MODE=ros`, not an `rclpy` consumer of the Python
  API. Where that path's builder lives follows the open question; the legacy
  inbound I/O (`ros_io`), sensor publish wiring of layer (c) (`sensor_ros`)
  and `init_rclpy` remain tracked by #276 / #328 (described only; nothing
  changes in other repos). #328 still has to decide where `init_rclpy()` and
  the boot extension list live; with this ADR the boot list is derived from
  the output mode first.
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
