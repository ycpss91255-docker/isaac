#!/usr/bin/env bats
#
# Isaac Sim 5.1.0 image smoke. Image-side; runs in /smoke_test/ inside
# the test stage built atop nvcr.io/nvidia/isaac-sim:5.1.0.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "isaac-sim launchers exist and are executable" {
  test -x /isaac-sim/runheadless.sh
  test -x /isaac-sim/runapp.sh
}

@test "isaac-sim ships Python 3.11 in /isaac-sim/kit/python/bin/python3" {
  test -x /isaac-sim/kit/python/bin/python3
  run /isaac-sim/kit/python/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
  assert_success
  assert_output "3.11"
}

@test "runtime user is host-aligned (not root, not isaac-sim default)" {
  run id -un
  assert_success
  refute_output "root"
  refute_output "isaac-sim"
}

@test "runtime user is in isaac-sim group (can read /isaac-sim/* mode 0750)" {
  run id -nG
  assert_success
  assert_output --partial "isaac-sim"
}

@test "HOME is writable" {
  test -w "${HOME}"
}

@test "bundled ROS 2 humble + jazzy libs are both readable" {
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.bridge/humble/lib
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.bridge/jazzy/lib
  run ls /isaac-sim/exts/isaacsim.ros2.bridge/humble/lib/librmw_fastrtps_cpp.so
  assert_success
  run ls /isaac-sim/exts/isaacsim.ros2.bridge/jazzy/lib/librmw_fastrtps_cpp.so
  assert_success
}

@test "bundled ROS 2 humble + jazzy rclpy are both readable (Python 3.11)" {
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.bridge/humble/rclpy/rclpy
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.bridge/jazzy/rclpy/rclpy
}
