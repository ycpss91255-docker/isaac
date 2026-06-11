"""Kit-side runner for the example GPU integration test (isaac#132).

Not a pytest test (leading underscore so pytest skips collection). Boots
the #131 ``ExampleDriver`` headless (no livestream -- bypasses
IsaacSim#228) and exercises the strong L1-L4 + ``/cmd_vel`` round-trip
assertions the PRD lists (Testing & Acceptance), emitting canonical
marker lines so the pytest layer can assert without depending on the
process exit code (Kit's ``app.close`` calls ``_exit(0)`` and swallows
``sys.exit``).

Rather than run the example driver's unattended ``main()`` loop, this
runner subclasses ``ExampleDriver`` and overrides the subclass hooks to
probe the live stage in place: the full SCENE-driven lifecycle
(``SimulationApp`` -> signal handlers -> build_scene -> setup_sensors ->
setup_ros2_io -> defaults -> play -> setup -> main -> shutdown -> close)
still runs through the framework, but ``setup`` / ``main`` make the
integration assertions and print markers.

Marker lines (the pytest layer asserts on these)::

    [KIT LOG] path=...              Kit log file (CUDA/Vulkan init lines)
    [CUDA OK] devices=N             libcuda cuInit + device count
    [BOOT OK]                       SimulationApp + scene built, hooks reached
    [L1 BASE_LINK OK] path=... valid=True rigidbody=True
    [L1 COUNTS OK] links=N joints=N
    [L1 URDF DIFF OK] prim_diff=0 joint_diff=0 root=...
    [L1 URDF DIFF FAIL] ...         actual != URDF-parse-expected
    [CAMERA GRAPH OK] graph=...     setup_camera built the OmniGraph chain
    [L3 CAMERA OK] topic=... frame_id=... width=... height=... count=N
    [L3 CAMERA MISSING] ...         budget exhausted without a frame
    [ROS_IO NONE OK]                latest() is None before any publish
    [CMD_VEL ROUNDTRIP OK] seq=N vx=.. vy=.. wz=..
    [CMD_VEL ROUNDTRIP MISSING] ... budget exhausted without echo
    [SIGINT SHUTDOWN OK]            injected SIGINT -> shutdown() ran
    [EXIT CLEAN]                    lifecycle completed without raising
    [RAISED] ...                    exception escaped the lifecycle

CLI::

    /isaac-sim/python.sh _example_headless_runner.py \\
        --repo-root <repo>
"""

import argparse
import ctypes
import os
import signal
import sys
from pathlib import Path

# Ticks of app.update() to wait for the first camera frame after the
# graph is built, and to wait for the published /cmd_vel echo to reach
# the OmniGraph subscribe attribute. The render product + SDG pipeline
# and the ROS 2 bridge warm up within a few dozen ticks once shaders are
# compiled; the budget covers first-run shader-compilation stalls.
_FRAME_BUDGET_TICKS = 1800
_CMD_VEL_BUDGET_TICKS = 600

_CMD_VEL_TOPIC = "/cmd_vel"


def _cuda_device_count() -> int:
    """Functional CUDA probe via the driver API (no torch dependency)."""
    cuda = ctypes.CDLL("libcuda.so.1")
    rc = cuda.cuInit(0)
    if rc != 0:
        raise RuntimeError(f"cuInit failed: rc={rc}")
    count = ctypes.c_int(0)
    rc = cuda.cuDeviceGetCount(ctypes.byref(count))
    if rc != 0:
        raise RuntimeError(f"cuDeviceGetCount failed: rc={rc}")
    return count.value


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    args = parser.parse_args()

    # Headless, no livestream: ROS 2 bridge + livestream in one Kit
    # process segfaults randomly (IsaacSim#228). Forced here so the
    # result does not depend on inherited container env.
    os.environ["ISAAC_LIVESTREAM"] = "0"

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))
    example_dir = repo_root / "example" / "sim"
    if str(example_dir) not in sys.path:
        sys.path.insert(0, str(example_dir))

    try:
        from example_driver import (  # noqa: E402
            ExampleDriver,
            _CMD_VEL_TOPIC as DRIVER_CMD_VEL_TOPIC,
        )
        from isaac_devkit.model_import import (  # noqa: E402
            _summarize_prim_records,
        )

        class _ExampleIntegrationDriver(ExampleDriver):
            """Probe the live example scene in setup() / main()."""

            def setup(self, stage) -> None:
                import carb.settings

                log_path = carb.settings.get_settings().get("/log/file")
                print(f"[KIT LOG] path={log_path}", flush=True)
                print(f"[CUDA OK] devices={_cuda_device_count()}", flush=True)
                self._stage = stage
                print("[BOOT OK]", flush=True)

                self._assert_l1(stage)
                self._setup_camera_probe()
                self._setup_cmd_vel_publisher()

            # -- L1: model/structure assertions ----------------------

            def _assert_l1(self, stage) -> None:
                from pxr import Usd, UsdPhysics

                base_link_path = f"{self._robot_prim_path}/base_link"
                base_link = stage.GetPrimAtPath(base_link_path)
                valid = bool(base_link.IsValid())
                has_rb = bool(
                    valid and base_link.HasAPI(UsdPhysics.RigidBodyAPI)
                )
                print(
                    f"[L1 BASE_LINK OK] path={base_link_path} "
                    f"valid={valid} rigidbody={has_rb}",
                    flush=True,
                )

                # Fold the live committed-USD robot subtree into a
                # PrimSummary with the same pure summarizer the unit tests
                # exercise, then report the OBSERVED link/joint structure.
                # The robot reference roots at /World/Robot; re-root to
                # /<robot_name> so the records line up with the importer's
                # own /<robot_name> rooting (the URDF->USD diff=0 contract
                # is asserted separately by a subprocess re-import in
                # test_example_gpu_integration.py, the proven
                # test_model_import.py pattern -- it cannot run here
                # because importing in-process needs a second
                # SimulationApp).
                robot_root = stage.GetPrimAtPath(self._robot_prim_path)
                records = []
                for prim in Usd.PrimRange(robot_root):
                    path = str(prim.GetPath())
                    if path == self._robot_prim_path:
                        continue
                    records.append((path, prim.GetTypeName()))

                from example_driver import load_three_file_scene

                scene = load_three_file_scene(
                    repo_root / ExampleDriver.SCENE
                )
                robot_name = scene["robot"].get("name", "camera_bot")
                expected_root = f"/{robot_name}"
                prefix_len = len(self._robot_prim_path)
                rerooted = [
                    (expected_root + path[prefix_len:], type_name)
                    for path, type_name in records
                ]
                rerooted.insert(0, (expected_root, "Xform"))

                actual = _summarize_prim_records(rerooted, usd_path="")
                print(
                    f"[L1 COUNTS OK] links={len(actual.link_paths)} "
                    f"joints={actual.joint_count} root={actual.root_prim}",
                    flush=True,
                )

            # -- L3: camera subscribe probe (in-process rclpy) --------

            def _setup_camera_probe(self) -> None:
                self._cam_topic = getattr(self, "_camera_topic", None)
                self._frames = 0
                self._first_frame = None
                if not self._cam_topic:
                    return

                self.init_rclpy()
                import rclpy
                from rclpy.qos import (
                    HistoryPolicy,
                    QoSProfile,
                    ReliabilityPolicy,
                )
                from sensor_msgs.msg import Image

                self._node = rclpy.create_node("example_integration_probe")

                def _on_image(msg) -> None:
                    self._frames += 1
                    if self._first_frame is None:
                        self._first_frame = (
                            msg.header.frame_id,
                            msg.width,
                            msg.height,
                        )

                self._cam_sub = self._node.create_subscription(
                    Image,
                    self._cam_topic,
                    _on_image,
                    QoSProfile(
                        depth=1,
                        history=HistoryPolicy.KEEP_LAST,
                        reliability=ReliabilityPolicy.BEST_EFFORT,
                    ),
                )

            # -- cmd_vel round-trip publisher -------------------------

            def _setup_cmd_vel_publisher(self) -> None:
                # latest() must be None before any /cmd_vel is published.
                pre = self.io.latest(_CMD_VEL_TOPIC)
                if pre is None:
                    print("[ROS_IO NONE OK]", flush=True)
                else:
                    print(
                        f"[ROS_IO NONE FAIL] unexpected pre-publish msg={pre}",
                        flush=True,
                    )

                import rclpy
                from geometry_msgs.msg import Twist

                if getattr(self, "_node", None) is None:
                    self._node = rclpy.create_node("example_integration_probe")
                self._cmd_vel_pub = self._node.create_publisher(
                    Twist, _CMD_VEL_TOPIC, 10
                )
                self._sent_vx = 0.42
                self._sent_wz = 0.21

            def main(self) -> None:
                import rclpy

                # Phase 1: wait for a camera frame.
                ticks = 0
                while (
                    not self._should_quit
                    and self._app.is_running()
                    and ticks < _FRAME_BUDGET_TICKS
                ):
                    self._app.update()
                    rclpy.spin_once(self._node, timeout_sec=0.0)
                    ticks += 1
                    if self._frames >= 1:
                        break

                if self._first_frame is not None:
                    frame_id, width, height = self._first_frame
                    print(
                        f"[L3 CAMERA OK] topic={self._cam_topic} "
                        f"frame_id={frame_id} width={width} "
                        f"height={height} count={self._frames}",
                        flush=True,
                    )
                else:
                    print(
                        f"[L3 CAMERA MISSING] waited_ticks={ticks}",
                        flush=True,
                    )

                # Phase 2: publish one /cmd_vel and confirm io.latest()
                # echoes its content within budget (the round-trip).
                from geometry_msgs.msg import Twist

                twist = Twist()
                twist.linear.x = self._sent_vx
                twist.angular.z = self._sent_wz

                echoed = None
                cmd_ticks = 0
                while (
                    not self._should_quit
                    and self._app.is_running()
                    and cmd_ticks < _CMD_VEL_BUDGET_TICKS
                ):
                    self._cmd_vel_pub.publish(twist)
                    self._app.update()
                    rclpy.spin_once(self._node, timeout_sec=0.0)
                    cmd_ticks += 1
                    msg = self.io.latest(_CMD_VEL_TOPIC)
                    if msg is not None:
                        echoed = msg
                        break

                if echoed is not None:
                    from example_driver import cmd_vel_to_planar_velocity

                    vx, vy, wz = cmd_vel_to_planar_velocity(
                        echoed.fields.get("linear", ()),
                        echoed.fields.get("angular", ()),
                    )
                    print(
                        f"[CMD_VEL ROUNDTRIP OK] seq={echoed.seq} "
                        f"vx={vx} vy={vy} wz={wz}",
                        flush=True,
                    )
                else:
                    print(
                        "[CMD_VEL ROUNDTRIP MISSING] "
                        f"waited_ticks={cmd_ticks}",
                        flush=True,
                    )

                # Phase 3: inject SIGINT and confirm the lifecycle still
                # runs shutdown() (marker-line acceptance, ADR-0017 sec 7).
                # _on_signal flips _should_quit; the framework run() calls
                # shutdown() after main() returns.
                self._on_signal(signal.SIGINT, None)

            def shutdown(self) -> None:
                if self._should_quit:
                    print("[SIGINT SHUTDOWN OK]", flush=True)
                try:
                    if getattr(self, "_node", None) is not None:
                        self._node.destroy_node()
                    import rclpy

                    rclpy.try_shutdown()
                finally:
                    print("[EXIT CLEAN]", flush=True)

        # Keep the driver's cmd_vel topic constant in sync (guards against
        # the example renaming the topic without updating this probe).
        assert DRIVER_CMD_VEL_TOPIC == _CMD_VEL_TOPIC

        _ExampleIntegrationDriver().run()
    except Exception as exc:  # noqa: BLE001
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        raise


if __name__ == "__main__":
    _main()
