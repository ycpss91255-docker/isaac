"""OpenBase L2 kinematic driver — /cmd_vel standalone version.

L2 (ADR-0008) canonical pattern: kinematicEnabled=True on base_link,
driver integrates cmd_vel into pose each tick and writes via
dc.set_rigid_body_pose. No velocity override, no gravity workaround.

Loads openbase_l2.usda (sublayer override on CAD-tracked openbase.usda).

Usage (container):
    cd docker && ./run.sh -t standalone -d
    make exec -- -t standalone /isaac-sim/python.sh \
        /home/yunchien/work/src/script/cmd_vel_planar_standalone_l2.py

Push cmd_vel from outside:
    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 \
        -v <repo>/config/ros2/fastdds.xml:/isaac-sim/fastdds.xml:ro \
        -e FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml \
        ros:humble bash -c 'source /opt/ros/humble/setup.bash &&
            ros2 topic pub /cmd_vel geometry_msgs/Twist \
                "{linear: {x: 0.5}}" -r 10'

Refs: ADR-0008, ycpss91255-docker/isaac#23
"""

import math
import os
import signal
import sys

from isaacsim import SimulationApp

APP = SimulationApp({
    "headless": True,
    "renderer": "RaytracedLighting",
})

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[l2-cmd] SIGINT/SIGTERM — requesting shutdown", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)

import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402
from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
from pxr import Gf, UsdLux, UsdPhysics  # noqa: E402

from isaacsim.core.utils.extensions import enable_extension  # noqa: E402
enable_extension("isaacsim.ros2.bridge")

import rclpy  # noqa: E402
from geometry_msgs.msg import Twist  # noqa: E402
from rclpy.node import Node  # noqa: E402
from rclpy.signals import SignalHandlerOptions  # noqa: E402

USD_PATH = "/home/yunchien/work/src/model/usd/openbase/openbase_l2.usda"
BASE_PRIM = "/open_base/base_link"
TOPIC = "/cmd_vel"
NODE_NAME = "cmd_vel_l2_subscriber"
REPORT_EVERY = 60
DT = 1.0 / 60.0


def _stage_setup():
    if not os.path.exists(USD_PATH):
        raise FileNotFoundError(f"USD not found: {USD_PATH}")
    ctx = omni.usd.get_context()
    if not ctx.open_stage(USD_PATH):
        raise RuntimeError(f"open_stage() returned False for {USD_PATH}")
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        APP.update()
    else:
        raise RuntimeError("stage did not reach OPENED")

    stage = ctx.get_stage()
    print(f"[setup] opened {USD_PATH}", flush=True)

    if not stage.GetPrimAtPath("/World/SunLight").IsValid():
        UsdLux.DistantLight.Define(
            stage, "/World/SunLight"
        ).GetIntensityAttr().Set(3000.0)
        print("[setup] sunlight added", flush=True)

    if not stage.GetPrimAtPath("/World/GroundPlane").IsValid():
        from isaacsim.core.api.objects.ground_plane import GroundPlane as IsaacGroundPlane
        IsaacGroundPlane(prim_path="/World/GroundPlane", z_position=0, size=100)
        print("[setup] ground plane added", flush=True)

    return stage


def _make_ros_node(state):
    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    node = Node(NODE_NAME)

    def _cb(msg):
        state["vx"] = float(msg.linear.x)
        state["vy"] = float(msg.linear.y)
        state["wz"] = float(msg.angular.z)

    node.create_subscription(Twist, TOPIC, _cb, 10)
    return node


def _yaw_to_quat(yaw):
    """Yaw (rad) to quaternion (x, y, z, w) for Z-up."""
    half = yaw * 0.5
    return (0.0, 0.0, math.sin(half), math.cos(half))


def main():
    stage = _stage_setup()
    base_xform = stage.GetPrimAtPath(BASE_PRIM)
    translate_attr = base_xform.GetAttribute("xformOp:translate")
    orient_attr = base_xform.GetAttribute("xformOp:orient")

    iface = dc.acquire_dynamic_control_interface()

    tl = omni.timeline.get_timeline_interface()
    tl.set_end_time(1.0e9)
    tl.play()

    for _ in range(10):
        APP.update()

    handle = iface.get_rigid_body(BASE_PRIM)
    if handle == dc.INVALID_HANDLE:
        raise RuntimeError(f"dc.get_rigid_body({BASE_PRIM}) returned INVALID_HANDLE")

    init_pose = iface.get_rigid_body_pose(handle)
    pose_x = float(init_pose.p[0])
    pose_y = float(init_pose.p[1])
    pose_z = float(init_pose.p[2])
    pose_yaw = 0.0

    cmd = {"vx": 0.0, "vy": 0.0, "wz": 0.0}
    node = _make_ros_node(cmd)

    print(
        f"[l2-cmd] L2 kinematic driver ready on {TOPIC}; Ctrl+C to quit",
        flush=True,
    )

    step = 0
    try:
        while APP.is_running() and not _SHOULD_QUIT:
            rclpy.spin_once(node, timeout_sec=0.0)
            step += 1

            cos_y = math.cos(pose_yaw)
            sin_y = math.sin(pose_yaw)
            pose_x += (cmd["vx"] * cos_y - cmd["vy"] * sin_y) * DT
            pose_y += (cmd["vx"] * sin_y + cmd["vy"] * cos_y) * DT
            pose_yaw += cmd["wz"] * DT

            target = dc.Transform()
            target.p = (pose_x, pose_y, pose_z)
            target.r = _yaw_to_quat(pose_yaw)
            iface.set_rigid_body_pose(handle, target)

            if translate_attr and translate_attr.IsValid():
                translate_attr.Set(Gf.Vec3d(pose_x, pose_y, pose_z))
            if orient_attr and orient_attr.IsValid():
                qx, qy, qz, qw = _yaw_to_quat(pose_yaw)
                orient_attr.Set(Gf.Quatd(qw, Gf.Vec3d(qx, qy, qz)))

            APP.update()

            if step % REPORT_EVERY != 0:
                continue
            actual = iface.get_rigid_body_pose(handle)
            print(
                f"[tick {step:>5}] "
                f"cmd=({cmd['vx']:+.2f},{cmd['vy']:+.2f},w={cmd['wz']:+.2f}) "
                f"pos=({actual.p[0]:+.2f},{actual.p[1]:+.2f},{actual.p[2]:+.2f}) "
                f"yaw={math.degrees(pose_yaw):+.1f}deg",
                flush=True,
            )
    except KeyboardInterrupt:
        print("[l2-cmd] KeyboardInterrupt — shutting down", flush=True)
    finally:
        try:
            node.destroy_node()
        except Exception as exc:
            print(f"[l2-cmd] destroy_node ignored: {exc}", flush=True)
        rclpy.shutdown()
        APP.close()


if __name__ == "__main__":
    sys.exit(main())
