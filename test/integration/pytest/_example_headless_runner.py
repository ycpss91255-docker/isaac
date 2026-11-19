"""Kit-side runner for the example GPU integration test (isaac#132, #325).

Not a pytest test (leading underscore so pytest skips collection). Boots
a headless scene around the official Jetbot USD (passed via
``--robot-usd``; fetched by the pytest layer through
``test/test_assets.py``) with no livestream (bypasses IsaacSim#228) and exercises the strong L1-L4 + ``/cmd_vel`` round-trip
assertions the PRD lists (Testing & Acceptance), emitting canonical
marker lines so the pytest layer can assert without depending on the
process exit code (Kit's ``app.close`` calls ``_exit(0)`` and swallows
``sys.exit``).

The runner subclasses the framework ``IsaacDriver`` and walks the same
SCENE-driven lifecycle the removed example driver did (``SimulationApp``
-> signal handlers -> build_scene -> camera -> ros2_io -> defaults ->
play -> setup -> main -> shutdown -> close); ``setup`` / ``main`` make the
integration assertions and print markers. The scene is an in-memory dict
(no ``example/sim/`` files).

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
        --repo-root <repo> --robot-usd <path/to/jetbot.usd>
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
_ROBOT_PRIM = "/World/Robot"
# The Jetbot's articulation body; it has no ``base_link``.
_CHASSIS_PRIM = f"{_ROBOT_PRIM}/chassis"
_CAMERA_TOPIC_PREFIX = "/jetbot/camera"


def _build_scene_dict(robot_usd: str) -> dict:
    """In-memory scene: ground + light + the Jetbot + /cmd_vel subscription."""
    return {
        "environment": {"ground_plane": True},
        "robot": {
            "name": "jetbot",
            "model": robot_usd,  # absolute path bypasses MODEL_PATH search
            "pose": {"xyz": [0.0, 0.0, 0.0], "rpy": [0.0, 0.0, 0.0]},
        },
        "ros2_io": {"subscriptions": [{"topic": _CMD_VEL_TOPIC, "type": "twist"}]},
    }


def _camera_cfg() -> dict:
    """Custom RGB camera mounted on the Jetbot chassis (no external assets)."""
    return {
        "mount": {
            "parent_prim": _CHASSIS_PRIM,
            "pose": {"xyz": [0.1, 0.0, 0.1], "rpy": [0.0, 0.0, 0.0]},
        },
        "sensor": {"category": "camera", "type": "custom"},
        "sensors": [
            {
                "role": "rgb",
                "name": "color",
                "pose": {"xyz": [0.0, 0.0, 0.0], "rpy": [0.0, 0.0, 0.0]},
                "resolution": [1280, 720],
                "fps": 30,
                "hfov": 90.0,
                "vfov": 60.0,
            }
        ],
        "ros": {
            "topic_prefix": _CAMERA_TOPIC_PREFIX,
            "frame_id_prefix": "jetbot_camera",
        },
    }


def _twist_to_planar(linear, angular):
    """Zero-padded ``(vx, vy, wz)`` from a Twist's linear / angular fields."""

    def _at(seq, index):
        try:
            return float(seq[index])
        except (IndexError, TypeError, KeyError):
            return 0.0

    return _at(linear, 0), _at(linear, 1), _at(angular, 2)


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
    parser.add_argument("--robot-usd", required=True)
    args = parser.parse_args()

    # Headless, no livestream: ROS 2 bridge + livestream in one Kit
    # process segfaults randomly (IsaacSim#228). Forced here so the
    # result does not depend on inherited container env.
    os.environ["ISAAC_LIVESTREAM"] = "0"

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))
    robot_usd = str(Path(args.robot_usd).resolve())

    try:
        from isaac_devkit.driver import (  # noqa: E402
            IsaacDriver,
            parse_livestream_env,
        )
        from isaac_devkit.model_import import (  # noqa: E402
            _summarize_prim_records,
        )

        class _ExampleIntegrationDriver(IsaacDriver):
            """Build the Jetbot scene, then probe it in setup() / main()."""

            def __init__(self) -> None:
                super().__init__()
                self.io = None
                self._robot_prim_path = _ROBOT_PRIM

            # -- Lifecycle (the SCENE shape the example driver walked) --

            def run(self) -> None:
                from isaacsim import SimulationApp

                kwargs = parse_livestream_env(
                    os.environ.get("ISAAC_LIVESTREAM")
                )
                self._app = SimulationApp(kwargs)
                signal.signal(signal.SIGINT, self._on_signal)
                signal.signal(signal.SIGTERM, self._on_signal)
                try:
                    import omni.usd

                    scene = _build_scene_dict(robot_usd)
                    stage = omni.usd.get_context().get_stage()
                    from isaac_devkit.scene import build_scene

                    # robot.model is absolute, so repo_root only anchors
                    # the (unused) legacy model/usd fallback.
                    build_scene(scene, stage, repo_root)
                    self._setup_camera(stage)
                    self.io = self._setup_ros2_io(scene)
                    self._ensure_scene_defaults(stage)
                    self._play_timeline()
                    self.setup(stage)
                    self.main()
                    self.shutdown()
                except Exception as exc:  # noqa: BLE001
                    print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
                    raise
                finally:
                    sys.stdout.flush()
                    sys.stderr.flush()
                    self._app.close()

            def _setup_camera(self, stage) -> None:
                from isaac_devkit.sensors import setup_camera

                graph = setup_camera(_camera_cfg(), stage)
                print(f"[CAMERA GRAPH OK] graph={graph}", flush=True)
                self._camera_topic = _CAMERA_TOPIC_PREFIX + "/color/image_raw"

            def _setup_ros2_io(self, scene):
                from isaac_devkit import ros_io

                subs = ros_io.parse_ros2_io_config(scene)
                from isaacsim.core.utils.extensions import enable_extension

                enable_extension("isaacsim.core.nodes")
                enable_extension("isaacsim.ros2.bridge")
                import omni.graph.core as og

                nodes, set_values, connects = ros_io._build_graph_topology(subs)
                (graph, _, _, _) = og.Controller.edit(
                    {
                        "graph_path": ros_io.GRAPH_PATH,
                        "evaluator_name": "execution",
                    },
                    {
                        og.Controller.Keys.CREATE_NODES: nodes,
                        og.Controller.Keys.SET_VALUES: set_values,
                        og.Controller.Keys.CONNECT: connects,
                    },
                )
                og.Controller.evaluate_sync(graph)
                topic_paths = {
                    e["topic"]: ros_io.expected_attr_paths(
                        e["topic"], e["msg_type"]
                    )
                    for e in subs
                }
                return ros_io.RosIo(
                    attr_reader=ros_io._og_attr_reader, topic_paths=topic_paths
                )

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

                base_link_path = _CHASSIS_PRIM
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

                robot_name = _build_scene_dict(robot_usd)["robot"]["name"]
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
                    vx, vy, wz = _twist_to_planar(
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

        _ExampleIntegrationDriver().run()
    except Exception as exc:  # noqa: BLE001
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        raise


if __name__ == "__main__":
    _main()
