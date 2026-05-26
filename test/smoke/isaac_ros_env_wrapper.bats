#!/usr/bin/env bats
#
# Unit tests for /usr/local/bin/isaac-ros-env-wrapper.sh — runs in
# the test stage (FROM devel), where the wrapper has been COPY'd in
# and /etc/isaac/ros-distro has been baked from ARG ROS_DISTRO.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "wrapper exists and is executable" {
  assert_file_exists /usr/local/bin/isaac-ros-env-wrapper.sh
  assert [ -x /usr/local/bin/isaac-ros-env-wrapper.sh ]
}

@test "/etc/isaac/ros-distro is baked with humble (default ARG)" {
  assert_file_exists /etc/isaac/ros-distro
  run cat /etc/isaac/ros-distro
  assert_success
  assert_output "humble"
}

@test "wrapper exports ROS_DISTRO from /etc/isaac/ros-distro" {
  run /usr/local/bin/isaac-ros-env-wrapper.sh bash -c 'printf "%s" "${ROS_DISTRO}"'
  assert_success
  assert_output "humble"
}

@test "wrapper exports LD_LIBRARY_PATH derived from ROS_DISTRO" {
  run /usr/local/bin/isaac-ros-env-wrapper.sh bash -c 'printf "%s" "${LD_LIBRARY_PATH}"'
  assert_success
  assert_output "/isaac-sim/exts/isaacsim.ros2.bridge/humble/lib"
}

@test "wrapper hard-overrides runtime ROS_DISTRO env" {
  ROS_DISTRO=jazzy run /usr/local/bin/isaac-ros-env-wrapper.sh bash -c 'printf "%s" "${ROS_DISTRO}"'
  assert_success
  assert_output "humble"
}

@test "wrapper passes args verbatim to wrapped command" {
  run /usr/local/bin/isaac-ros-env-wrapper.sh echo arg1 arg2 arg3
  assert_success
  assert_output "arg1 arg2 arg3"
}

@test "wrapper appends publicEndpointAddress when PUBLIC_IP is set" {
  PUBLIC_IP=10.2.23.83 run /usr/local/bin/isaac-ros-env-wrapper.sh echo -v
  assert_success
  assert_output "-v --/app/livestream/publicEndpointAddress=10.2.23.83"
}

@test "wrapper does not append publicEndpointAddress when PUBLIC_IP is empty" {
  unset PUBLIC_IP
  run /usr/local/bin/isaac-ros-env-wrapper.sh echo -v
  assert_success
  assert_output "-v"
}

@test "devel stage ENV ROS_DISTRO is baked (soft)" {
  run bash -c 'printf "%s" "${ROS_DISTRO}"'
  assert_success
  assert_output "humble"
}

@test "devel stage ENV LD_LIBRARY_PATH points to baked humble lib" {
  run bash -c 'printf "%s" "${LD_LIBRARY_PATH}"'
  assert_success
  assert_output "/isaac-sim/exts/isaacsim.ros2.bridge/humble/lib"
}
