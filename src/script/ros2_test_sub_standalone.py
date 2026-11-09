"""ROS 2 bridge smoke (subscriber side) -- standalone SimulationApp.

Subscribes to /host/test (std_msgs/String) and prints each received
message. Same behaviour as the in-kit Script Editor variant
(ros2_test_sub.py), but driven by SimulationApp + a main loop so it can be
launched directly from python.sh.

Kit follows the container's ISAAC_LIVESTREAM (0 in the `headless` stage,
2 = WebRTC in the `stream` stage).

Usage (the container's working directory is the repo root, ~/work):

    just docker run -t headless -d
    just docker exec -t headless /isaac-sim/python.sh \\
        src/script/ros2_test_sub_standalone.py [--run-seconds N]

Stop: SIGINT / SIGTERM to the Python process (README "Stopping a
standalone script"), or --run-seconds N. Exit code 0 on a clean stop,
1 on any error.

Drive a message from a sibling container:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
                 ros2 topic pub /host/test std_msgs/String \\
                     "{data: hello-from-host}" --once'
"""

import argparse
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import standalone_common  # noqa: E402

NODE_NAME = "isaac_test_sub"
TOPIC = "/host/test"

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[ros2_test_sub] SIGINT/SIGTERM -- requesting shutdown", flush=True)
    _SHOULD_QUIT = True


def _parse_args(argv):
    parser = argparse.ArgumentParser(description="ROS 2 subscriber smoke")
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

    app = SimulationApp(
        standalone_common.kit_config(os.environ.get("ISAAC_LIVESTREAM"))
    )
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    import omni.timeline
    from isaacsim.core.utils.extensions import enable_extension

    enable_extension("isaacsim.ros2.bridge")

    import rclpy
    from rclpy.node import Node
    from std_msgs.msg import String

    rclpy.init()
    node = Node(NODE_NAME)

    def _callback(msg):
        print(f"[ros2_test_sub] {TOPIC} <- {msg.data!r}", flush=True)

    node.create_subscription(String, TOPIC, _callback, 10)

    timeline = omni.timeline.get_timeline_interface()
    timeline.set_end_time(1.0e9)
    timeline.play()
    deadline = None
    if args.run_seconds > 0:
        deadline = time.monotonic() + args.run_seconds

    print(
        f"[ros2_test_sub] subscribed to {TOPIC}; SIGINT/SIGTERM stops it",
        flush=True,
    )
    try:
        while app.is_running() and not _SHOULD_QUIT:
            if deadline is not None and time.monotonic() >= deadline:
                break
            app.update()
            rclpy.spin_once(node, timeout_sec=0.0)
    finally:
        node.destroy_node()
        rclpy.shutdown()
    print("[ros2_test_sub] exiting", flush=True)
    return 0


if __name__ == "__main__":
    standalone_common.run_and_exit(main)
