"""OpenBase 2D 平面移動 — /cmd_vel 訂閱 standalone 版

跟 cmd_vel_planar_move.py 相同邏輯，但用 SimulationApp + 主迴圈，不依賴
Script Editor。透過 /isaac-sim/python.sh 直接啟動，Ctrl+C 乾淨退出。

用法 (容器內):
    /isaac-sim/python.sh /home/yunchien/work/src/script/cmd_vel_planar_standalone.py

或透過 ./run.sh -t standalone wrapper (M2 加 standalone stage 後):
    ./run.sh -t standalone src/script/cmd_vel_planar_standalone.py

從容器外推 cmd_vel (與 cmd_vel_planar_move.py 相同):
    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 \\
        -v <repo>/config/ros2/fastdds.xml:/isaac-sim/fastdds.xml:ro \\
        -e FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml \\
        ros:humble bash -c 'source /opt/ros/humble/setup.bash &&
            ros2 topic pub /cmd_vel geometry_msgs/Twist \\
                "{linear: {x: 0.5}}" -r 10'
"""

import os
import signal
import sys

# SimulationApp must be the first instantiation — all kit / omni / rclpy
# imports must come AFTER, otherwise modules resolve before kit's plugin
# manager registers them and binding errors result.
from isaacsim import SimulationApp


# NOTE: livestream=2 (WebRTC) intentionally OFF. Isaac Sim 5.1 has a
# known crash when `omni.kit.livestream.webrtc` + `isaacsim.ros2.bridge`
# extensions are loaded in the same standalone process (random segfault
# ~2s after bridge startup; see isaac-sim/IsaacSim#228 +
# https://forums.developer.nvidia.com/t/.../327272). The crash is in
# carb plugin init; no upstream fix as of 2026-05. We trade away the
# in-process WebRTC viewport for stability. Visual verification of the
# stage during cmd_vel testing should use a separate viewer:
#   - In-kit Script Editor via `./run.sh -t headless -d` (no rclpy in
#     that kit process), open same USD, watch base move via streamed
#     viewport; cmd_vel commands routed through ROS Action Graph or
#     a separate published topic.
#   - Or `./run.sh -t gui -d` X11 native window.
# `headless: True` keeps SimulationApp fully off-screen — no renderer
# windowing, no livestream plugin loaded — safe to combine with rclpy.
APP = SimulationApp({
    "headless": True,
    "renderer": "RaytracedLighting",
})

# SimulationApp installs its own SIGINT handler that swallows Ctrl+C, so
# Python's KeyboardInterrupt never fires from the main while-loop.
# Override with our own flag-setting handler AFTER SimulationApp init —
# the main loop checks _SHOULD_QUIT each tick and breaks out cleanly.
_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[cmd_vel] SIGINT/SIGTERM — requesting shutdown", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# Imports below depend on the kit app being alive.
import numpy as np  # noqa: E402

import omni.kit.app  # noqa: E402
import omni.kit.commands  # noqa: E402
import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402
from isaacsim.core.api import World  # noqa: E402
from isaacsim.core.prims import SingleRigidPrim  # noqa: E402
from pxr import UsdLux, UsdPhysics  # noqa: E402

# Standalone python.sh uses `isaacsim.exp.base.python.kit` experience which
# does NOT auto-load the ROS 2 bridge extension (unlike the default
# `isaacsim.exp.full.kit` used in Script Editor). Bundled rclpy lives at
# /isaac-sim/exts/isaacsim.ros2.bridge/<distro>/rclpy/ and is only added
# to PYTHONPATH when the bridge extension actually starts. Enable it
# before importing rclpy or the import resolves to "ModuleNotFoundError".
from isaacsim.core.utils.extensions import enable_extension  # noqa: E402
enable_extension("isaacsim.ros2.bridge")

import rclpy  # noqa: E402
from geometry_msgs.msg import Twist  # noqa: E402
from rclpy.node import Node  # noqa: E402
from rclpy.signals import SignalHandlerOptions  # noqa: E402


USD_PATH = "/home/yunchien/work/src/model/usd/robot/openbase/openbase.usda"
TOPIC = "/cmd_vel"
NODE_NAME = "cmd_vel_planar_subscriber"
REPORT_EVERY = 60
WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")


def _stage_setup():
    # Fail fast on missing USD — otherwise the OPENED-spin below loops
    # forever silently (open_stage returns False, state stays CLOSED,
    # `Failed to open` is only an `[Error]` log line, not an exception).
    if not os.path.exists(USD_PATH):
        raise FileNotFoundError(
            f"USD not found: {USD_PATH}\n"
            f"Generate it from URDF first:\n"
            f"  /isaac-sim/python.sh /home/yunchien/work/src/script/import_urdf.py \\\n"
            f"      /home/yunchien/work/src/model/urdf/robot/openbase/openbase_minimal.urdf \\\n"
            f"      {USD_PATH}"
        )
    # In standalone mode `ctx.open_stage(path)` is async — returns True
    # immediately when the load *starts*, then transitions OPENING ->
    # OPENED. Touching `ctx.get_stage()` before OPENED returns None and
    # the next GetPrimAtPath crashes with AttributeError. Spin kit's
    # update loop until the stage state transitions to OPENED before
    # reading the stage. Returns False on permission / parse errors —
    # caller should treat that as fatal (not spin forever).
    ctx = omni.usd.get_context()
    if not ctx.open_stage(USD_PATH):
        raise RuntimeError(f"open_stage() returned False for {USD_PATH}")
    timeout_ticks = 600  # ~10s at 60 fps, USD parse should be way faster
    for _ in range(timeout_ticks):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        APP.update()
    else:
        raise RuntimeError(
            f"stage did not transition to OPENED within {timeout_ticks} ticks"
        )
    stage = ctx.get_stage()
    print(f"[setup] opened {USD_PATH}", flush=True)

    if not stage.GetPrimAtPath("/World/SunLight").IsValid():
        UsdLux.DistantLight.Define(
            stage, "/World/SunLight"
        ).GetIntensityAttr().Set(3000.0)
        print("[setup] sunlight added", flush=True)

    if not stage.GetPrimAtPath("/World/GroundPlane").IsValid():
        omni.kit.commands.execute(
            "CreateMeshPrimWithDefaultXform",
            prim_type="Plane",
            prim_path="/World/GroundPlane",
        )
        g = stage.GetPrimAtPath("/World/GroundPlane")
        g.GetAttribute("xformOp:scale").Set((100, 100, 1))
        UsdPhysics.CollisionAPI.Apply(g)
        print("[setup] ground plane added", flush=True)

    for prim in stage.Traverse():
        if prim.GetName() in WHEELS:
            drive = UsdPhysics.DriveAPI.Get(prim, "angular")
            drive.GetStiffnessAttr().Set(0.0)
            drive.GetDampingAttr().Set(0.0)
            drive.GetTargetVelocityAttr().Set(0.0)
            print(f"[setup] {prim.GetName()}: drive disabled", flush=True)


def _make_ros_node(state):
    # SignalHandlerOptions.NO — rclpy default installs SIGINT/SIGTERM
    # handlers; combined with kit's own handlers + our _signal_handler
    # (set after SimulationApp init), the 3-way conflict crashes kit
    # ~2s after entering the update loop on this USD+dc+rclpy combo.
    # Standalone bisection: USD-only loop (no rclpy/no dc) survives 90s+;
    # USD+dc (move_openbase) survives 90s+; USD+rclpy+dc cmd_vel crashes.
    # Telling rclpy to install no handlers leaves only our flag-handler
    # active, no conflict.
    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    node = Node(NODE_NAME)

    def _cb(msg):
        state["cmd_vel"]["vx"] = float(msg.linear.x)
        state["cmd_vel"]["vy"] = float(msg.linear.y)
        state["cmd_vel"]["wz"] = float(msg.angular.z)

    node.create_subscription(Twist, TOPIC, _cb, 10)
    return node


def main():
    _stage_setup()

    state = {
        "cmd_vel": {"vx": 0.0, "vy": 0.0, "wz": 0.0},
        "step": 0,
    }
    # Use isaacsim.core.api.World + SingleRigidPrim (replaces deprecated
    # omni.isaac.dynamic_control). Bisection found dc + rclpy + USD races
    # crash kit ~2s after isaacsim.ros2.bridge starts. World owns physics
    # init in production-grade path and avoids the crash combo.
    world = World(stage_units_in_meters=1.0)
    world.reset()
    base = SingleRigidPrim("/open_base/base_link")

    node = _make_ros_node(state)

    print(
        f"[cmd_vel] standalone subscribed {TOPIC}; "
        "Ctrl+C 乾淨退出。base 不會動，直到推 /cmd_vel",
        flush=True,
    )

    try:
        while APP.is_running() and not _SHOULD_QUIT:
            rclpy.spin_once(node, timeout_sec=0.0)
            state["step"] += 1

            cv = state["cmd_vel"]
            base.set_linear_velocity(np.array([cv["vx"], cv["vy"], 0.0]))
            base.set_angular_velocity(np.array([0.0, 0.0, cv["wz"]]))

            world.step(render=True)

            if state["step"] % REPORT_EVERY != 0:
                continue
            pos, _orn = base.get_world_pose()
            lin = base.get_linear_velocity()
            ang = base.get_angular_velocity()
            print(
                f"[tick {state['step']:>5}] "
                f"cmd=({cv['vx']:+.2f},{cv['vy']:+.2f},w={cv['wz']:+.2f}) "
                f"pos=({pos[0]:+.2f},{pos[1]:+.2f},{pos[2]:+.2f}) "
                f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
                f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})",
                flush=True,
            )
    except KeyboardInterrupt:
        print("[cmd_vel] KeyboardInterrupt — shutting down", flush=True)
    finally:
        try:
            node.destroy_node()
        except Exception as exc:
            print(f"[cmd_vel] destroy_node ignored: {exc}", flush=True)
        rclpy.shutdown()
        APP.close()


if __name__ == "__main__":
    sys.exit(main())
