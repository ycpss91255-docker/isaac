"""ROS 2 bridge smoke (publisher side) — standalone SimulationApp.

Publishes std_msgs/String to /isaac/test at ~1 Hz from a standalone Isaac
Sim process. Unlike the in-kit Script Editor variant (ros2_test_pub.py),
this script drives the kit update loop itself via APP.update() inside a
main while-loop, so no manual timeline play is required — SimulationApp's
update loop drives sim time on its own.

The ROS 2 bridge extension `isaacsim.ros2.bridge` auto-loads via the
default kit experience (isaacsim.exp.full inherited by full.streaming),
so `import rclpy` resolves to Isaac's bundled Python 3.11 rclpy. No
external `source /opt/ros/humble/setup.bash` needed.

Usage (inside container):
    ./exec.sh -t standalone /isaac-sim/python.sh \\
        /home/yunchien/work/src/script/ros2_test_pub_standalone.py

Ctrl+C cleanly exits (SIGINT/SIGTERM handler sets a flag that the main
loop checks each tick).

Cross-validate from a sibling docker container:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
                 ros2 topic echo /isaac/test --once'
"""

import signal
import sys

# SimulationApp must be the first instantiation — all kit / omni / rclpy
# imports must come AFTER, otherwise modules resolve before kit's plugin
# manager registers them and binding errors result.
from isaacsim import SimulationApp


# livestream=2 → WebRTC streaming (Isaac Sim 5.1 default streaming proto);
# headless=False keeps the renderer alive so WebRTC client can connect to
# localhost:8211/streaming/webrtc-client.
APP = SimulationApp({
    "headless": False,
    "livestream": 2,
    "renderer": "RaytracedLighting",
})

# SimulationApp installs its own SIGINT handler that swallows Ctrl+C, so
# Python's KeyboardInterrupt never fires from the main while-loop.
# Override with our own flag-setting handler AFTER SimulationApp init —
# the main loop checks _SHOULD_QUIT each tick and breaks out cleanly.
_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[ros2_test_pub] SIGINT/SIGTERM — requesting shutdown", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# Standalone python.sh uses `isaacsim.exp.base.python.kit` experience which
# does NOT auto-load the ROS 2 bridge extension (unlike the default
# `isaacsim.exp.full.kit` used in Script Editor). Bundled rclpy lives at
# /isaac-sim/exts/isaacsim.ros2.bridge/<distro>/rclpy/ and is only added
# to PYTHONPATH when the bridge extension actually starts. Enable it
# before importing rclpy or the import resolves to "ModuleNotFoundError".
from isaacsim.core.utils.extensions import enable_extension  # noqa: E402
enable_extension("isaacsim.ros2.bridge")

import rclpy  # noqa: E402
from rclpy.node import Node  # noqa: E402
from std_msgs.msg import String  # noqa: E402


_NODE_NAME = "isaac_test_pub"
_TOPIC = "/isaac/test"
_PUBLISH_EVERY = 60  # ~1 Hz at 60 fps


def _make_node():
    if not rclpy.ok():
        rclpy.init()
    node = Node(_NODE_NAME)
    pub = node.create_publisher(String, _TOPIC, 10)
    return node, pub


def main():
    node, pub = _make_node()
    tick = 0

    print(
        f"[ros2_test_pub] standalone publishing {_TOPIC} every "
        f"{_PUBLISH_EVERY} ticks (~1 Hz); Ctrl+C cleanly exits",
        flush=True,
    )
    print("[ros2_test_pub] verify from sibling container:", flush=True)
    print(
        "  docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\",
        flush=True,
    )
    print("      bash -c 'source /opt/ros/humble/setup.bash && \\", flush=True)
    print("               ros2 topic echo /isaac/test --once'", flush=True)

    try:
        while APP.is_running() and not _SHOULD_QUIT:
            APP.update()
            rclpy.spin_once(node, timeout_sec=0.0)
            tick += 1

            if tick % _PUBLISH_EVERY != 0:
                continue

            msg = String()
            msg.data = f"hello {tick}"
            pub.publish(msg)
    except KeyboardInterrupt:
        print("[ros2_test_pub] KeyboardInterrupt — shutting down", flush=True)
    finally:
        try:
            node.destroy_node()
        except Exception as exc:
            print(f"[ros2_test_pub] destroy_node ignored: {exc}", flush=True)
        rclpy.shutdown()
        APP.close()


if __name__ == "__main__":
    sys.exit(main())
