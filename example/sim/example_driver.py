"""ExampleDriver: the base-repo camera_bot example (isaac#131).

The single runnable example that embodies ROS2-by-default and doubles as
the scaffold template (ADR-0017). A minimal camera-bot -- one chassis
body (`base_link`) plus a camera -- that publishes a ROS 2 camera topic
and consumes `/cmd_vel`.

`ExampleDriver(IsaacDriver)` declares ``SCENE`` (the three-file scene) and
overrides ``run()`` to walk the SCENE-driven lifecycle (ADR-0017 section
9 / PRD A2)::

    SimulationApp(parse_livestream_env(ISAAC_LIVESTREAM))   # first
    install signal handlers (override Kit SIGINT)
    scene = load_scene(SCENE)        # pure: read + merge three files
    stage = get_stage()              # from SimulationApp/World
    build_scene(scene, stage)        # framework Isaac Lab sim_utils adapter
    setup_sensors(scene, stage)      # L3 outbound: camera -> ROS 2
    self.io = setup_ros2_io(scene, stage)  # inbound: /cmd_vel subscribe
    ensure_scene_defaults(stage)     # base: SunLight (skipped, adapter lit)
    play_timeline()
    setup(stage); main(); shutdown(); app.close()

``main()`` reads ``self.io.latest("/cmd_vel")`` each tick and drives the
chassis (the cmd_vel round-trip).

Import-safety (PRD A1 / ADR-0017 section 8): every ``omni`` / ``pxr`` /
``isaacsim`` import is function-local, so importing this module on a host
without Isaac Sim is safe and the pure helpers
(``load_three_file_scene`` / ``expected_*_prim_path`` /
``cmd_vel_to_planar_velocity``) are hosted-unit-testable.

Run inside the Isaac container::

    /isaac-sim/python.sh example/sim/example_driver.py
"""

from __future__ import annotations

import os
import signal
import sys
from pathlib import Path
from typing import Any, Dict, Sequence, Tuple

import yaml

# Resolve sibling framework on the host / in the container mount so
# ``import isaac_devkit`` works whether launched as a script or imported
# by a test. example/sim/example_driver.py -> parents[2] = repo root.
_REPO_ROOT = Path(__file__).resolve().parents[2]
_FRAMEWORK = _REPO_ROOT / "framework"
if str(_FRAMEWORK) not in sys.path:
    sys.path.insert(0, str(_FRAMEWORK))

from isaac_devkit.driver import IsaacDriver, parse_livestream_env  # noqa: E402

# Prim paths build_scene composes the scene under (scene.build_scene
# references the robot USD at /World/Robot).
_ROBOT_PRIM = "/World/Robot"
_CMD_VEL_TOPIC = "/cmd_vel"


# ---------------------------------------------------------------------------
# Pure helpers (host-runnable, no Isaac Sim).
# ---------------------------------------------------------------------------


def load_three_file_scene(scene_path: Any) -> Dict[str, Any]:
    """Load scene.yaml and deep-merge its ``imports`` into one scene dict.

    The three-file scene (ADR-0017 section 4) is ``scene.yaml`` (the
    environment + ``imports`` of the other two) plus ``robot.yaml`` and
    ``object.yaml``. This reads ``scene.yaml``, resolves each ``imports``
    entry relative to the scene file, and shallow-merges the top-level
    keys of each imported fragment into the result (later files win on a
    key clash; the example's fragments hold disjoint keys ``robot`` /
    ``objects``).

    Pure: only filesystem + YAML, no Isaac. The returned dict is the
    shape the framework lifecycle (``build_scene`` / ``setup_sensors`` /
    ``setup_ros2_io``) consumes.

    Args:
        scene_path: Path to ``scene.yaml``.

    Returns:
        The merged scene dict.

    Raises:
        FileNotFoundError: ``scene.yaml`` or an imported fragment is
            missing.
    """
    scene_file = Path(scene_path).expanduser().resolve()
    if not scene_file.exists():
        raise FileNotFoundError(f"scene file not found: {scene_file}")
    with scene_file.open() as f:
        merged: Dict[str, Any] = yaml.safe_load(f) or {}

    imports = merged.pop("imports", []) or []
    for rel in imports:
        frag_path = (scene_file.parent / rel).resolve()
        if not frag_path.exists():
            raise FileNotFoundError(
                f"imported scene fragment not found: {frag_path} "
                f"(from imports entry {rel!r} in {scene_file})"
            )
        with frag_path.open() as f:
            fragment = yaml.safe_load(f) or {}
        for key, value in fragment.items():
            merged[key] = value
    return merged


def expected_robot_prim_path(_scene: Dict[str, Any]) -> str:
    """Return the robot root prim path build_scene composes.

    Pure string computation (the L1 target the GPU assertions in #132
    check). ``build_scene`` references the robot USD under
    ``/World/Robot`` regardless of the robot's name.
    """
    return _ROBOT_PRIM


def expected_base_link_prim_path(scene: Dict[str, Any]) -> str:
    """Return the ``base_link`` prim path under the robot root (pure)."""
    return f"{expected_robot_prim_path(scene)}/base_link"


def cmd_vel_to_planar_velocity(
    linear: Sequence[float], angular: Sequence[float]
) -> Tuple[float, float, float]:
    """Map a Twist (linear, angular) to a planar ``(vx, vy, wz)`` command.

    Pure controller for the camera_bot's planar chassis: forward/strafe
    linear velocity plus yaw rate. Short or scalar inputs are zero-padded
    so a partially-populated OmniGraph attribute read still yields a full
    3-vector.

    Args:
        linear: Linear velocity components (x, y, z); only x, y are used.
        angular: Angular velocity components (x, y, z); only z (yaw) used.

    Returns:
        ``(vx, vy, wz)`` -- forward, strafe, yaw-rate.
    """
    def _at(seq: Sequence[float], index: int) -> float:
        try:
            return float(seq[index])
        except (IndexError, TypeError, KeyError):
            return 0.0

    return _at(linear, 0), _at(linear, 1), _at(angular, 2)


# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------


class ExampleDriver(IsaacDriver):
    """The camera_bot example driver (ADR-0017 running example).

    ``SCENE`` points at the three-file scene; ``run()`` walks the
    SCENE-driven lifecycle. Subclass hooks ``setup`` / ``main`` /
    ``shutdown`` are overridden below to wire the camera ROS 2 subscriber
    is not needed (the camera publishes via OmniGraph); ``main`` reads
    ``self.io.latest("/cmd_vel")`` and drives the chassis.
    """

    # Repo-relative three-file scene entry (resolved against the repo
    # root the framework anchors on).
    SCENE = "example/sim/scene/scene.yaml"

    def __init__(self) -> None:
        super().__init__()
        self.io: Any = None
        self._robot_prim_path: str = _ROBOT_PRIM
        self._ticks: int = 0
        self._cmd_count: int = 0

    # -- Lifecycle (overrides IsaacDriver.run to the SCENE shape) ---------

    def run(self) -> None:
        """Walk the SCENE-driven lifecycle (ADR-0017 section 9 / PRD A2).

        Order matters: ``SimulationApp`` must be the first Isaac Sim
        construction; the signal handler override comes after (Kit
        installs its own SIGINT during construction). The seams
        (``_load_scene`` / ``_get_stage`` / ``_build_scene`` / ... ) are
        separate methods so the lifecycle ORDER is spy-verifiable hosted
        without Isaac.
        """
        from isaacsim import SimulationApp

        kwargs = parse_livestream_env(os.environ.get("ISAAC_LIVESTREAM"))
        self._app = SimulationApp(kwargs)

        signal.signal(signal.SIGINT, self._on_signal)
        signal.signal(signal.SIGTERM, self._on_signal)

        try:
            scene = self._load_scene()
            stage = self._get_stage()
            self._build_scene(scene, stage)
            self._setup_sensors(scene, stage)
            self.io = self._setup_ros2_io(scene, stage)
            self._ensure_scene_defaults(stage)
            self._play_timeline()
            self.setup(stage)
            self.main()
            self.shutdown()
        except Exception as exc:  # noqa: BLE001
            # app.close() (the finally) calls _exit(0) and swallows the
            # traceback, so surface the failure on stdout first (the
            # marker-line acceptance convention, ADR-0017 section 7).
            print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
            raise
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            self._app.close()

    # -- Lifecycle seams (Isaac-side; function-local imports) ------------

    def _load_scene(self) -> Dict[str, Any]:
        """Read + merge the three-file scene (pure)."""
        scene_path = _REPO_ROOT / self.SCENE
        return load_three_file_scene(scene_path)

    def _get_stage(self) -> Any:
        """Return the live USD stage from the Kit context."""
        import omni.usd

        return omni.usd.get_context().get_stage()

    def _build_scene(self, scene: Dict[str, Any], stage: Any) -> None:
        """Spawn the scene via the framework Isaac Lab adapter (#154).

        Delegates to ``isaac_devkit.scene.build_scene`` -- the
        ``to_isaaclab_cfg`` -> ``sim_utils`` cfg -> ``cfg.func()`` spawn
        path (ADR-0018 decisions 1, 3). The example no longer carries its
        own raw-``pxr`` ``DefinePrim`` / ``GetReferences().AddReference``
        spawn: the adapter spawns the environment ground + light, the
        robot USD at ``/World/Robot`` (referencing
        ``camera_bot.usd`` whose ``defaultPrim`` is ``/camera_bot``), and
        each object instance under ``/World/Objects``. ``base_link`` then
        resolves at ``/World/Robot/base_link`` so the camera placement's
        ``parent_prim`` resolves.

        ``repo_root`` is ``<repo>/example/sim`` -- the example's model
        paths resolve there (``resolve_model_path`` tolerates the robot
        entry's ``model/usd/``-prefixed value). The adapter's own sensor
        tail fires only for TOP-LEVEL ``scene.sensors`` (the example has
        none -- its camera placement is nested under
        ``scene.robot.sensors`` and is wired by ``_setup_sensors``), so
        there is no double sensor setup.
        """
        from isaac_devkit.scene import build_scene

        example_root = _REPO_ROOT / "example" / "sim"
        build_scene(scene, stage, example_root)

    def _setup_sensors(self, scene: Dict[str, Any], stage: Any) -> None:
        """Build the camera publish chain (L3 outbound, proven path).

        Uses the per-sensor YAML at the placement's ``config`` (the v1
        path #127 proved): a ``custom`` camera = local UsdGeom.Camera
        prims, no external assets, wired to a ROS 2 publish OmniGraph.
        """
        from isaac_devkit.sensors import load_config, setup_camera

        for placement in scene["robot"].get("sensors", []):
            cfg_rel = placement["config"]
            cfg_abs = _REPO_ROOT / "example" / "sim" / cfg_rel
            cfg = load_config(cfg_abs)
            graph = setup_camera(cfg, stage)
            print(f"[CAMERA GRAPH OK] graph={graph}", flush=True)
            self._camera_topic = (
                cfg["ros"]["topic_prefix"].rstrip("/") + "/color/image_raw"
            )

    def _setup_ros2_io(self, scene: Dict[str, Any], stage: Any) -> Any:
        """Wire the /cmd_vel OmniGraph subscribe chain and return a RosIo.

        Builds ``OnPlaybackTick -> ROS2SubscribeTwist -> Counter`` per the
        ``ros2_io.subscriptions`` config using ros_io's pure topology
        helper, then constructs a ``RosIo`` over the live OmniGraph
        attribute reader. (The framework's ``setup_ros2_io`` reserves this
        wiring for #131; the example lands it here against a live stage.)
        """
        from isaac_devkit import ros_io

        subscriptions = ros_io.parse_ros2_io_config(scene)
        if not subscriptions:
            return ros_io.RosIo(attr_reader=ros_io._fail_reader, topic_paths={})

        from isaacsim.core.utils.extensions import enable_extension

        enable_extension("isaacsim.core.nodes")
        enable_extension("isaacsim.ros2.bridge")

        import omni.graph.core as og

        nodes, set_values, connects = ros_io._build_graph_topology(
            subscriptions
        )
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
            entry["topic"]: ros_io.expected_attr_paths(
                entry["topic"], entry["msg_type"]
            )
            for entry in subscriptions
        }
        return ros_io.RosIo(
            attr_reader=ros_io._og_attr_reader, topic_paths=topic_paths
        )

    def _play_timeline(self) -> None:
        """Set an effectively-infinite end time and start the timeline."""
        import omni.timeline

        timeline = omni.timeline.get_timeline_interface()
        timeline.set_end_time(1e10)
        timeline.play()
        for _ in range(10):
            self._app.update()

    # -- Subclass hooks --------------------------------------------------

    def setup(self, stage: Any) -> None:
        """Post-setup boot marker (after the camera + cmd_vel are wired)."""
        self._stage = stage
        print("[BOOT OK]", flush=True)

    def main(self) -> None:
        """Tick the sim; drive the chassis from /cmd_vel each tick.

        Non-blocking: ``self.io.latest("/cmd_vel")`` returns the newest
        unreported Twist (or None). On a fresh command, map it to a planar
        velocity and apply it to the chassis rigid body. A bounded tick
        budget keeps the example a self-terminating smoke when launched
        unattended; Ctrl+C (``_should_quit``) also breaks out.
        """
        budget = int(os.environ.get("EXAMPLE_TICK_BUDGET", "1800"))
        while (
            not self._should_quit
            and self._app.is_running()
            and self._ticks < budget
        ):
            self._app.update()
            self._ticks += 1
            msg = self.io.latest(_CMD_VEL_TOPIC)
            if msg is not None:
                self._cmd_count += 1
                vx, vy, wz = cmd_vel_to_planar_velocity(
                    msg.fields.get("linear", ()),
                    msg.fields.get("angular", ()),
                )
                self._drive_chassis(vx, vy, wz)
                print(
                    f"[CMD_VEL OK] seq={msg.seq} vx={vx} vy={vy} wz={wz}",
                    flush=True,
                )

    def _drive_chassis(self, vx: float, vy: float, wz: float) -> None:
        """Apply a planar velocity to the chassis rigid body (Isaac-side).

        Sets the base_link rigid body's linear velocity. Yaw-rate control
        on the kinematic chassis is left to the forklift application
        (controller abstraction deferred until a third robot, ADR-0017
        section 6 -- Rule of Three).
        """
        from pxr import Gf, UsdPhysics

        base_link = self._stage.GetPrimAtPath(
            f"{self._robot_prim_path}/base_link"
        )
        if not base_link.IsValid():
            return
        rb = UsdPhysics.RigidBodyAPI(base_link)
        if rb:
            rb.CreateVelocityAttr().Set(Gf.Vec3f(float(vx), float(vy), 0.0))

    def shutdown(self) -> None:
        """Pre-close marker; the framework finally-block calls app.close."""
        print(
            f"[CMD_VEL SUMMARY] commands={self._cmd_count} ticks={self._ticks}",
            flush=True,
        )
        print("[EXIT CLEAN]", flush=True)


if __name__ == "__main__":
    ExampleDriver().run()
