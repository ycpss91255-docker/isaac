"""ROS 2 bridge smoke (subscriber side) — Script Editor in-kit.

Subscribes to /host/test (std_msgs/String) and prints each message to
the kit terminal. ROS 2 subscriptions are only active while the
timeline is playing — kit auto-plays at the bottom of this script.

The bridge extension auto-loads via isaacsim.exp.full's [settings]
block, so `import rclpy` resolves to Isaac's bundled Python 3.11
rclpy without sourcing external ROS 2.

Drive a message from a sibling docker container:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
                 ros2 topic pub /host/test std_msgs/String \\
                     "{data: hello-from-host}" --once'

Re-Run-safe: previous subscription / node are retired before new ones
are created.
"""

import omni.kit.app
import omni.timeline
import rclpy
from rclpy.node import Node
from std_msgs.msg import String


_NODE_NAME = "isaac_test_sub"
_TOPIC = "/host/test"


def _make_node():
    if not rclpy.ok():
        rclpy.init()
    node = Node(_NODE_NAME)

    def _callback(msg):
        print(f"[ros2_test_sub] {_TOPIC} <- {msg.data!r}")

    sub = node.create_subscription(String, _TOPIC, _callback, 10)
    return node, sub


_g = globals()

old_state = _g.get("_ros2_test_sub_state")
if old_state is not None:
    try:
        old_state["node"].destroy_node()
    except Exception as exc:
        print(f"[ros2_test_sub] previous node destroy ignored: {exc}")
    _g["_ros2_test_sub_state"] = None

old_tick = _g.get("_ros2_test_sub_tick")
if old_tick is not None:
    _g["_ros2_test_sub_tick"] = None

_node, _sub_handle = _make_node()
# Prefixed name so co-loading sibling smoke scripts (ros2_test_pub.py)
# in the same Script Editor namespace cannot clobber this dict — the
# update subscription's callback below looks `_sub_state` up via the
# kit Python global namespace at every fire, so a name collision would
# silently break callbacks. Matches the `_pub_state` convention in
# ros2_test_pub.py.
_sub_state = {"node": _node, "sub": _sub_handle}


def _on_sub_post_update(_event):
    rclpy.spin_once(_sub_state["node"], timeout_sec=0.0)


_tick = (
    omni.kit.app.get_app()
    .get_post_update_event_stream()
    .create_subscription_to_pop(_on_sub_post_update, name="ros2_test_sub_tick")
)
_g["_ros2_test_sub_tick"] = _tick
_g["_ros2_test_sub_state"] = _sub_state

_tl = omni.timeline.get_timeline_interface()
_tl.set_end_time(1.0e9)
_tl.play()

print(f"[ros2_test_sub] subscribed to {_TOPIC}; messages will print here")
print("[ros2_test_sub] drive from sibling container:")
print("  docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\")
print("      bash -c 'source /opt/ros/humble/setup.bash && \\")
print("               ros2 topic pub /host/test std_msgs/String \\")
print("                   \"{data: hello-from-host}\" --once'")
