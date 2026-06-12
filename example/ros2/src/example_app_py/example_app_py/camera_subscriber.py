# Copyright 2026 cyc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Camera subscriber node: the app-side consumer of the example camera.

Subscribes to the camera topic the base-repo Isaac example publishes
(/camera_bot/camera/color/image_raw, sensor_msgs/Image) and logs a
one-line summary per frame. This is the inbound half of the ROS 2
bidirectional topology (ADR-0017 section 6): the Isaac driver publishes
the camera stream through an OmniGraph chain, and this sibling ament node
-- running in a standard ROS 2 Humble container -- receives it.

Replace on_image with your own perception logic. The topic name is a
launch parameter (camera_topic) so you can point it at a different stream
without editing the node.

Run::

    ros2 run example_app_py camera_subscriber
    ros2 run example_app_py camera_subscriber --ros-args -p camera_topic:=/my/topic
"""

from __future__ import annotations

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image

# The topic the base-repo example publishes (example/sim/config/sensor/
# custom.yaml: topic_prefix /camera_bot/camera + /color/image_raw).
DEFAULT_CAMERA_TOPIC = "/camera_bot/camera/color/image_raw"


def describe_image(msg: Image) -> str:
    """
    Return a one-line human-readable summary of an Image message.

    Pure helper (no ROS context needed) so it is unit-testable without a
    running node.

    Parameters
    ----------
    msg : sensor_msgs.msg.Image
        The received image message.

    Returns
    -------
    str
        A summary string with resolution, encoding, and frame id.

    """
    return (
        f"frame {msg.width}x{msg.height} encoding={msg.encoding} "
        f"frame_id={msg.header.frame_id}"
    )


class CameraSubscriber(Node):
    """Subscribe to the example camera topic and log each frame."""

    def __init__(self) -> None:
        """Declare the camera_topic parameter and create the subscription."""
        super().__init__("camera_subscriber")
        self.declare_parameter("camera_topic", DEFAULT_CAMERA_TOPIC)
        topic = (
            self.get_parameter("camera_topic")
            .get_parameter_value()
            .string_value
        )
        self.subscription = self.create_subscription(
            Image, topic, self.on_image, 10
        )
        self.frame_count = 0
        self.get_logger().info(f"subscribed to {topic}")

    def on_image(self, msg: Image) -> None:
        """Count and log one received frame."""
        self.frame_count += 1
        self.get_logger().info(
            f"[FRAME OK] #{self.frame_count} {describe_image(msg)}"
        )


def main(args: list[str] | None = None) -> None:
    """Spin the camera subscriber node until interrupted."""
    rclpy.init(args=args)
    node = CameraSubscriber()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
