// Copyright 2026 cyc
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Camera subscriber node: the app-side consumer of the example camera.
//
// Subscribes to the camera topic the base-repo Isaac example publishes
// (/camera_bot/camera/color/image_raw, sensor_msgs/Image) and logs a
// one-line summary per frame. This is the inbound half of the ROS 2
// bidirectional topology (ADR-0017 section 6). Replace the callback body
// with your perception logic; the topic is a parameter so you can point
// it at a different stream without editing the node.

#include <memory>
#include <string>

#include "rclcpp/rclcpp.hpp"
#include "sensor_msgs/msg/image.hpp"

namespace
{
// The topic the base-repo example publishes (example/sim/config/sensor/
// custom.yaml: topic_prefix /camera_bot/camera + /color/image_raw).
constexpr char kDefaultCameraTopic[] =
  "/camera_bot/camera/color/image_raw";
}  // namespace

class CameraSubscriber : public rclcpp::Node
{
public:
  CameraSubscriber()
  : Node("camera_subscriber"), frame_count_(0)
  {
    const std::string topic =
      this->declare_parameter<std::string>(
      "camera_topic",
      kDefaultCameraTopic);
    subscription_ = this->create_subscription<sensor_msgs::msg::Image>(
      topic, 10,
      std::bind(&CameraSubscriber::OnImage, this, std::placeholders::_1));
    RCLCPP_INFO(this->get_logger(), "subscribed to %s", topic.c_str());
  }

private:
  void OnImage(const sensor_msgs::msg::Image::SharedPtr msg)
  {
    ++frame_count_;
    RCLCPP_INFO(
      this->get_logger(),
      "[FRAME OK] #%zu frame %ux%u encoding=%s frame_id=%s",
      frame_count_, msg->width, msg->height, msg->encoding.c_str(),
      msg->header.frame_id.c_str());
  }

  rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr subscription_;
  std::size_t frame_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<CameraSubscriber>());
  rclcpp::shutdown();
  return 0;
}
