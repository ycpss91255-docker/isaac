"""ROS 2 bridge smoke (publisher side) -- standalone SimulationApp.

Publishes std_msgs/String "hello N" to /isaac/test once per second (wall
clock) from a standalone Isaac Sim process. Unlike the in-kit Script Editor
variant (ros2_test_pub.py), this script drives the Kit update loop itself,
so no manual timeline play is required.

Kit follows the container's ISAAC_LIVESTREAM (0 in the `headless` stage,
2 = WebRTC in the `stream` stage).

Usage (the container's working directory is the repo root, ~/work):

    just docker run -t headless -d
    just docker exec -t headless /isaac-sim/python.sh \\
        src/script/ros2_test_pub_standalone.py [--run-seconds N]

Stop: SIGINT / SIGTERM to the Python process (README "Stopping a
standalone script"), or --run-seconds N. Exit code 0 on a clean stop,
1 on any error.

Cross-validate from a sibling container:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
                 ros2 topic echo /isaac/test --once'
"""

import argparse
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import standalone_common  # noqa: E402

_NODE_NAME = "isaac_test_pub"
_TOPIC = "/isaac/test"
_PERIOD_S = 1.0

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[ros2_test_pub] SIGINT/SIGTERM -- requesting shutdown", flush=True)
    _SHOULD_QUIT = True


def _parse_args(argv):
    parser = argparse.ArgumentParser(description="ROS 2 publisher smoke")
    parser.add_argument(
        "--run-seconds",
        type=float,
        default=0.0,
        help="stop after N seconds (default 0 = until signalled)",
    )
    return parser.parse_args(argv)


def main():
    args = _parse_args(sys.argv[1:])

    # SimulationApp must be the first Isaac construction; every kit / omni /
    # rclpy import comes after it.
    from isaacsim import SimulationApp

    app = SimulationApp(
        standalone_common.kit_config(os.environ.get("ISAAC_LIVESTREAM"))
    )
    # SimulationApp installs its own SIGINT handler that swallows Ctrl+C;
    # replace it with a flag the loop checks every update.
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    # The python.sh experience does not auto-load the ROS 2 bridge, and the
    # bundled rclpy is only importable once the bridge has started.
    from isaacsim.core.utils.extensions import enable_extension

    enable_extension("isaacsim.ros2.bridge")

    import rclpy
    from rclpy.node import Node
    from std_msgs.msg import String

    if not rclpy.ok():
        rclpy.init()
    node = Node(_NODE_NAME)
    pub = node.create_publisher(String, _TOPIC, 10)
    timer = standalone_common.PeriodicTimer(_PERIOD_S)
    deadline = None
    if args.run_seconds > 0:
        deadline = time.monotonic() + args.run_seconds

    print(
        f"[ros2_test_pub] publishing {_TOPIC} every {_PERIOD_S:g} s; "
        "SIGINT/SIGTERM stops it",
        flush=True,
    )
    count = 0
    try:
        while app.is_running() and not _SHOULD_QUIT:
            if deadline is not None and time.monotonic() >= deadline:
                break
            app.update()
            rclpy.spin_once(node, timeout_sec=0.0)
            if not timer.due():
                continue
            count += 1
            msg = String()
            msg.data = f"hello {count}"
            pub.publish(msg)
    finally:
        node.destroy_node()
        rclpy.shutdown()
    print(f"[ros2_test_pub] published {count} messages; exiting", flush=True)
    return 0


if __name__ == "__main__":
    standalone_common.run_and_exit(main)
