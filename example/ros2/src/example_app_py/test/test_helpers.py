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
"""Unit tests for the pure helpers (no ROS context required)."""

from example_app_py.camera_subscriber import (
    DEFAULT_CAMERA_TOPIC,
    describe_image,
)
from example_app_py.cmd_vel_publisher import (
    DEFAULT_CMD_VEL_TOPIC,
    make_twist,
)
from geometry_msgs.msg import Twist
from sensor_msgs.msg import Image


def test_default_topics_match_the_example() -> None:
    """The defaults match the topics example/sim publishes / subscribes."""
    assert DEFAULT_CAMERA_TOPIC == "/camera_bot/camera/color/image_raw"
    assert DEFAULT_CMD_VEL_TOPIC == "/cmd_vel"


def test_describe_image_summarises_resolution_and_frame() -> None:
    """describe_image renders width, height, encoding and frame id."""
    msg = Image()
    msg.width = 1280
    msg.height = 720
    msg.encoding = "rgb8"
    msg.header.frame_id = "camera_bot_camera_color_optical_frame"
    summary = describe_image(msg)
    assert "1280x720" in summary
    assert "rgb8" in summary
    assert "camera_bot_camera_color_optical_frame" in summary


def test_make_twist_sets_only_planar_components() -> None:
    """make_twist sets linear.x and angular.z, leaving the rest zero."""
    twist = make_twist(0.5, 0.3)
    assert isinstance(twist, Twist)
    assert twist.linear.x == 0.5
    assert twist.angular.z == 0.3
    assert twist.linear.y == 0.0
    assert twist.linear.z == 0.0
    assert twist.angular.x == 0.0
    assert twist.angular.y == 0.0
