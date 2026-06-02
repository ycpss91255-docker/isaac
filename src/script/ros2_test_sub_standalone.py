"""ROS 2 bridge smoke (subscriber side) — SimulationApp standalone.

Subscribes to /host/test (std_msgs/String) and prints each received
message. Same behaviour as the in-kit Script Editor variant
(ros2_test_sub.py), but driven by SimulationApp + a main while-loop so
it can be launched directly from python.sh without the Script Editor.

The bridge extension auto-loads via isaacsim.exp.full's [settings]
block, so `import rclpy` resolves to Isaac's bundled Python 3.11 rclpy
without sourcing external ROS 2.

用法 (容器內):
    ./exec.sh -t standalone /isaac-sim/python.sh \\
        /home/yunchien/work/src/script/ros2_test_sub_standalone.py

Ctrl+C 乾淨退出。

Drive a message from a sibling docker container:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
                 ros2 topic pub /host/test std_msgs/String \\
                     "{data: hello-from-host}" --once'
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
    print("[ros2_test_sub] SIGINT/SIGTERM — requesting shutdown", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# Imports below depend on the kit app being alive.
import omni.timeline  # noqa: E402

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


NODE_NAME = "isaac_test_sub"
TOPIC = "/host/test"


def _make_ros_node():
    rclpy.init()
    node = Node(NODE_NAME)

    def _callback(msg):
        print(f"[ros2_test_sub] {TOPIC} <- {msg.data!r}", flush=True)

    node.create_subscription(String, TOPIC, _callback, 10)
    return node


def main():
    node = _make_ros_node()

    tl = omni.timeline.get_timeline_interface()
    tl.set_end_time(1.0e9)
    tl.play()

    print(
        f"[ros2_test_sub] standalone subscribed to {TOPIC}; "
        "Ctrl+C 乾淨退出。",
        flush=True,
    )
    print("[ros2_test_sub] drive from sibling container:", flush=True)
    print(
        "  docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\",
        flush=True,
    )
    print("      bash -c 'source /opt/ros/humble/setup.bash && \\", flush=True)
    print("               ros2 topic pub /host/test std_msgs/String \\", flush=True)
    print("                   \"{data: hello-from-host}\" --once'", flush=True)

    try:
        while APP.is_running() and not _SHOULD_QUIT:
            APP.update()
            rclpy.spin_once(node, timeout_sec=0.0)
    except KeyboardInterrupt:
        print("[ros2_test_sub] KeyboardInterrupt — shutting down", flush=True)
    finally:
        try:
            node.destroy_node()
        except Exception as exc:
            print(f"[ros2_test_sub] destroy_node ignored: {exc}", flush=True)
        rclpy.shutdown()
        APP.close()


if __name__ == "__main__":
    sys.exit(main())
