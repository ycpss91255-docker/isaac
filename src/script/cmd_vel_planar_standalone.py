"""OpenBase planar move driven by /cmd_vel -- standalone.

Same logic as the in-kit cmd_vel_planar_move.py, driven by SimulationApp +
a main loop instead of the Script Editor. Subscribes geometry_msgs/Twist on
/cmd_vel and writes it to base_link every step (Gazebo planar_move
equivalent: SE(2) motion, wheels bypassed).

Gravity is disabled on base_link (planar_move semantics). With it on, the
per-step velocity write cleared v.z only after PhysX had integrated
gravity, and the base fell through the floor at 0.16 m/s.

Usage (the container's working directory is the repo root, ~/work):

    just docker run -t headless -d
    just docker exec -t headless /isaac-sim/python.sh \\
        src/script/cmd_vel_planar_standalone.py [--run-seconds N]

Kit runs headless here whatever ISAAC_LIVESTREAM says: the WebRTC
livestream + ROS 2 bridge in one standalone process has crashed Kit
(isaac-sim/IsaacSim#228).

Push /cmd_vel from a sibling container. Any other publisher on the same
ROS_DOMAIN_ID also moves the base; use a private domain on a shared host.

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
            ros2 topic pub /cmd_vel geometry_msgs/Twist \\
                "{linear: {x: 0.5}}" -r 10'

Stop: SIGINT / SIGTERM to the Python process (README "Stopping a
standalone script") or --run-seconds N. Exit code 0 on a clean stop, 1 on
any error.
"""

import argparse
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import standalone_common  # noqa: E402

TOPIC = "/cmd_vel"
NODE_NAME = "cmd_vel_planar_subscriber"
REPORT_EVERY = 60

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[cmd_vel] SIGINT/SIGTERM -- requesting shutdown", flush=True)
    _SHOULD_QUIT = True


def _parse_args(argv):
    parser = argparse.ArgumentParser(description="OpenBase /cmd_vel planar move")
    parser.add_argument(
        "--run-seconds",
        type=float,
        default=0.0,
        help="stop after N seconds (default 0 = until signalled)",
    )
    return parser.parse_args(argv)


def main():
    args = _parse_args(sys.argv[1:])

    from isaacsim import SimulationApp

    app = SimulationApp(standalone_common.kit_config("0"))
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    import numpy as np
    from isaacsim.core.api import World
    from isaacsim.core.prims import SingleRigidPrim
    from isaacsim.core.utils.extensions import enable_extension

    standalone_common.setup_openbase_stage(
        app, standalone_common.openbase_usd_path()
    )
    world = World(stage_units_in_meters=1.0)
    world.reset()
    base = SingleRigidPrim(standalone_common.OPENBASE_BASE_LINK)

    enable_extension("isaacsim.ros2.bridge")
    import rclpy
    from geometry_msgs.msg import Twist
    from rclpy.node import Node
    from rclpy.signals import SignalHandlerOptions

    # rclpy must not install its own SIGINT/SIGTERM handlers: combined with
    # Kit's and ours they crashed Kit shortly after the loop started.
    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    node = Node(NODE_NAME)
    cmd = {"vx": 0.0, "vy": 0.0, "wz": 0.0}

    def _on_twist(msg):
        cmd["vx"] = float(msg.linear.x)
        cmd["vy"] = float(msg.linear.y)
        cmd["wz"] = float(msg.angular.z)

    node.create_subscription(Twist, TOPIC, _on_twist, 10)
    deadline = None
    if args.run_seconds > 0:
        deadline = time.monotonic() + args.run_seconds

    print(
        f"[cmd_vel] subscribed {TOPIC}; the base stays put until a Twist "
        "arrives; SIGINT/SIGTERM stops it",
        flush=True,
    )
    step = 0
    try:
        while app.is_running() and not _SHOULD_QUIT:
            if deadline is not None and time.monotonic() >= deadline:
                break
            rclpy.spin_once(node, timeout_sec=0.0)
            base.set_linear_velocity(np.array([cmd["vx"], cmd["vy"], 0.0]))
            base.set_angular_velocity(np.array([0.0, 0.0, cmd["wz"]]))
            world.step(render=True)
            step += 1
            if step % REPORT_EVERY != 0:
                continue
            pos, _orn = base.get_world_pose()
            lin = base.get_linear_velocity()
            ang = base.get_angular_velocity()
            print(
                f"[tick {step:>5}] "
                f"cmd=({cmd['vx']:+.2f},{cmd['vy']:+.2f},w={cmd['wz']:+.2f}) "
                f"pos=({pos[0]:+.2f},{pos[1]:+.2f},{pos[2]:+.2f}) "
                f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
                f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})",
                flush=True,
            )
    finally:
        node.destroy_node()
        rclpy.shutdown()
    print(f"[cmd_vel] stopped after {step} steps", flush=True)
    return 0


if __name__ == "__main__":
    standalone_common.run_and_exit(main)
