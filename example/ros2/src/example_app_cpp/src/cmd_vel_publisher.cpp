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

// cmd_vel publisher node: the app-side driver of the example chassis.
//
// Publishes a geometry_msgs/Twist on /cmd_vel at 10 Hz. This is the
// outbound half of the ROS 2 bidirectional topology (ADR-0017 section 6):
// the Isaac driver subscribes to /cmd_vel and drives the camera_bot, so
// commands published here move the robot in the sim. Replace the timer
// body with your control logic; the velocities are parameters.

#include <chrono>
#include <memory>
#include <string>

#include "geometry_msgs/msg/twist.hpp"
#include "rclcpp/rclcpp.hpp"

namespace
{
// The topic the base-repo example subscribes to (example/sim/scene/
// scene.yaml: ros2_io.subscriptions - topic /cmd_vel).
constexpr char kDefaultCmdVelTopic[] = "/cmd_vel";
}  // namespace

class CmdVelPublisher : public rclcpp::Node
{
public:
  CmdVelPublisher()
  : Node("cmd_vel_publisher"), tick_count_(0)
  {
    const std::string topic = this->declare_parameter<std::string>(
      "cmd_vel_topic", kDefaultCmdVelTopic);
    this->declare_parameter<double>("linear_x", 0.5);
    this->declare_parameter<double>("angular_z", 0.3);
    publisher_ =
      this->create_publisher<geometry_msgs::msg::Twist>(topic, 10);
    timer_ = this->create_wall_timer(
      std::chrono::milliseconds(100),
      std::bind(&CmdVelPublisher::OnTimer, this));
    RCLCPP_INFO(this->get_logger(), "publishing on %s", topic.c_str());
  }

private:
  void OnTimer()
  {
    const double linear_x = this->get_parameter("linear_x").as_double();
    const double angular_z = this->get_parameter("angular_z").as_double();
    geometry_msgs::msg::Twist msg;
    msg.linear.x = linear_x;
    msg.angular.z = angular_z;
    publisher_->publish(msg);
    ++tick_count_;
    RCLCPP_INFO(
      this->get_logger(),
      "[CMD_VEL OK] #%zu linear_x=%.3f angular_z=%.3f", tick_count_,
      linear_x, angular_z);
  }

  rclcpp::Publisher<geometry_msgs::msg::Twist>::SharedPtr publisher_;
  rclcpp::TimerBase::SharedPtr timer_;
  std::size_t tick_count_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<CmdVelPublisher>());
  rclcpp::shutdown();
  return 0;
}
