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
cmd_vel publisher node: the app-side driver of the example chassis.

Publishes a geometry_msgs/Twist on /cmd_vel at a fixed rate. This is the
outbound half of the ROS 2 bidirectional topology (ADR-0017 section 6):
the Isaac driver subscribes to /cmd_vel through an OmniGraph Subscribe
node and drives the camera_bot chassis, so commands published here move
the robot in the sim.

Replace make_twist / the timer body with your own control logic. The
linear and angular velocities are launch parameters so you can change the
motion without editing the node.

Run::

    ros2 run example_app_py cmd_vel_publisher
    ros2 run example_app_py cmd_vel_publisher --ros-args -p linear_x:=0.5 -p angular_z:=0.3
"""

from __future__ import annotations

import rclpy
from geometry_msgs.msg import Twist
from rclpy.node import Node

# The topic the base-repo example subscribes to (example/sim/scene/
# scene.yaml: ros2_io.subscriptions - topic /cmd_vel).
DEFAULT_CMD_VEL_TOPIC = "/cmd_vel"


def make_twist(linear_x: float, angular_z: float) -> Twist:
    """
    Build a planar Twist from forward speed and yaw rate.

    Pure helper (no ROS context) so it is unit-testable without a running
    node. Only the planar components are set; the rest stay zero.

    Parameters
    ----------
    linear_x : float
        Forward velocity in metres per second.
    angular_z : float
        Yaw rate in radians per second.

    Returns
    -------
    geometry_msgs.msg.Twist
        A twist carrying the planar command.

    """
    msg = Twist()
    msg.linear.x = float(linear_x)
    msg.angular.z = float(angular_z)
    return msg


class CmdVelPublisher(Node):
    """Publish a constant planar Twist on /cmd_vel at 10 Hz."""

    def __init__(self) -> None:
        """Declare velocity parameters and start the publish timer."""
        super().__init__("cmd_vel_publisher")
        self.declare_parameter("cmd_vel_topic", DEFAULT_CMD_VEL_TOPIC)
        self.declare_parameter("linear_x", 0.5)
        self.declare_parameter("angular_z", 0.3)
        topic = (
            self.get_parameter("cmd_vel_topic")
            .get_parameter_value()
            .string_value
        )
        self.publisher = self.create_publisher(Twist, topic, 10)
        self.timer = self.create_timer(0.1, self.on_timer)
        self.tick_count = 0
        self.get_logger().info(f"publishing on {topic}")

    def on_timer(self) -> None:
        """Publish one Twist built from the current parameter values."""
        linear_x = (
            self.get_parameter("linear_x").get_parameter_value().double_value
        )
        angular_z = (
            self.get_parameter("angular_z").get_parameter_value().double_value
        )
        self.publisher.publish(make_twist(linear_x, angular_z))
        self.tick_count += 1
        self.get_logger().info(
            f"[CMD_VEL OK] #{self.tick_count} "
            f"linear_x={linear_x} angular_z={angular_z}"
        )


def main(args: list[str] | None = None) -> None:
    """Spin the cmd_vel publisher node until interrupted."""
    rclpy.init(args=args)
    node = CmdVelPublisher()
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
