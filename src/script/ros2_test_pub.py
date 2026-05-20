"""ROS 2 bridge smoke (publisher side) — Script Editor in-kit.

Publishes std_msgs/String to /isaac/test at ~1 Hz while the timeline is
playing. ROS 2 publishers are only active during Play — kit auto-plays
at the bottom of this script so there is no manual step.

The ROS 2 bridge extension `isaacsim.ros2.bridge` auto-loads via the
default kit experience (isaacsim.exp.full inherited by full.streaming),
so `import rclpy` resolves to Isaac's bundled Python 3.11 rclpy. No
external `source /opt/ros/humble/setup.bash` needed.

Cross-validate from a sibling docker container:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\
        bash -c 'source /opt/ros/humble/setup.bash &&
                 ros2 topic echo /isaac/test --once'

Re-Run-safe: re-running this file in Script Editor retires the previous
update subscription and node before creating a new one.
"""

import omni.kit.app
import omni.timeline
import rclpy
from rclpy.node import Node
from std_msgs.msg import String


_NODE_NAME = "isaac_test_pub"
_TOPIC = "/isaac/test"
_PUBLISH_EVERY = 60  # ~1 Hz at 60 fps


def _make_node():
    if not rclpy.ok():
        rclpy.init()
    node = Node(_NODE_NAME)
    pub = node.create_publisher(String, _TOPIC, 10)
    return node, pub


_g = globals()

old_state = _g.get("_ros2_test_pub_state")
if old_state is not None:
    try:
        old_state["node"].destroy_node()
    except Exception as exc:
        print(f"[ros2_test_pub] previous node destroy ignored: {exc}")
    _g["_ros2_test_pub_state"] = None

old_sub = _g.get("_ros2_test_pub_sub")
if old_sub is not None:
    _g["_ros2_test_pub_sub"] = None

_node, _pub = _make_node()
# Prefixed name so co-loading sibling smoke scripts (ros2_test_sub.py)
# in the same Script Editor namespace cannot clobber this dict — the
# update subscription's callback below looks `_pub_state` up via the
# kit Python global namespace at every fire, so a name collision would
# break the callback (KeyError on "tick").
_pub_state = {"node": _node, "pub": _pub, "tick": 0}


def _on_pub_post_update(_event):
    _pub_state["tick"] += 1
    rclpy.spin_once(_pub_state["node"], timeout_sec=0.0)
    if _pub_state["tick"] % _PUBLISH_EVERY != 0:
        return
    msg = String()
    msg.data = f"hello {_pub_state['tick']}"
    _pub_state["pub"].publish(msg)


_sub = (
    omni.kit.app.get_app()
    .get_post_update_event_stream()
    .create_subscription_to_pop(_on_pub_post_update, name="ros2_test_pub_tick")
)
_g["_ros2_test_pub_sub"] = _sub
_g["_ros2_test_pub_state"] = _pub_state

_tl = omni.timeline.get_timeline_interface()
_tl.set_end_time(1.0e9)
_tl.play()

print(f"[ros2_test_pub] publishing {_TOPIC} at every {_PUBLISH_EVERY} ticks (~1 Hz)")
print("[ros2_test_pub] verify from sibling container:")
print("  docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \\")
print("      bash -c 'source /opt/ros/humble/setup.bash && \\")
print("               ros2 topic echo /isaac/test --once'")
