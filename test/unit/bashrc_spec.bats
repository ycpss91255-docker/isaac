#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  RC="/source/config/shell/bashrc"
}

# ════════════════════════════════════════════════════════════════════
# Function definitions
# ════════════════════════════════════════════════════════════════════

@test "defines alias_func" {
  run grep -q "^alias_func()" "${RC}"
  assert_success
}

@test "defines swc" {
  run grep -q "^swc()" "${RC}"
  assert_success
}

@test "defines color_git_branch" {
  run grep -q "^color_git_branch()" "${RC}"
  assert_success
}

@test "defines ros1_complete and ros1_source" {
  run grep -q "^ros1_complete()" "${RC}"
  assert_success
  run grep -q "^ros1_source()" "${RC}"
  assert_success
}

@test "defines ros2_complete and ros2_source" {
  run grep -q "^ros2_complete()" "${RC}"
  assert_success
  run grep -q "^ros2_source()" "${RC}"
  assert_success
}

@test "defines _ros_detect helper" {
  run grep -q "^_ros_detect()" "${RC}"
  assert_success
}

@test "defines _ros_auto_source dispatcher" {
  run grep -q "^_ros_auto_source()" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Aliases
# ════════════════════════════════════════════════════════════════════

@test "defines ebc alias" {
  run grep -q "alias ebc=" "${RC}"
  assert_success
}

@test "defines sbc alias" {
  run grep -q "alias sbc=" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Functions are called at the bottom
# ════════════════════════════════════════════════════════════════════

@test "alias_func is called" {
  run grep -qE "^alias_func[[:space:]]*$" "${RC}"
  assert_success
}

@test "color_git_branch is called" {
  run grep -qE "^color_git_branch[[:space:]]*$" "${RC}"
  assert_success
}

@test "_ros_auto_source is called at startup" {
  run grep -qE "^_ros_auto_source[[:space:]]*$" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Key content
# ════════════════════════════════════════════════════════════════════

@test "swc searches for catkin devel/setup.bash" {
  run grep -q "devel" "${RC}"
  assert_success
}

@test "ros1_source references ROS_DISTRO and catkin devel layout" {
  run grep -q "ROS_DISTRO" "${RC}"
  assert_success
  run grep -q '/devel/setup.bash' "${RC}"
  assert_success
}

@test "ros2_source references colcon install layout" {
  run grep -q '/install/setup.bash' "${RC}"
  assert_success
}

@test "color_git_branch sets PS1" {
  run grep -q "PS1=" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _ros_auto_source behaviour — sandbox under mocked /opt/ros
# ════════════════════════════════════════════════════════════════════

@test "_ros_auto_source is silent when no ROS distro is installed" {
  local _fake="$(mktemp -d)/opt/ros"
  mkdir -p "${_fake}"
  # Monkey-patch _ros_detect to look at our fake /opt/ros by overriding
  # the for-loop glob via a wrapper function in a subshell.
  run bash -c "
    source '${RC}' >/dev/null 2>&1
    _ros_detect() {
      local d distro
      for d in '${_fake}'/*/setup.bash; do
        [[ -f \"\${d}\" ]] || continue
        distro=\"\$(basename \"\$(dirname \"\${d}\")\")\"
        case \" \${_ROS1_DISTROS} \" in *\" \${distro} \"*) echo \"ros1:\${distro}\" ;; esac
        case \" \${_ROS2_DISTROS} \" in *\" \${distro} \"*) echo \"ros2:\${distro}\" ;; esac
      done
    }
    _ros_auto_source
  "
  assert_success
  refute_output --partial "Multiple ROS"
  refute_output --partial "sourced"
}

@test "_ros_auto_source warns when both ROS 1 and ROS 2 are installed" {
  local _root; _root="$(mktemp -d)"
  mkdir -p "${_root}/opt/ros/noetic" "${_root}/opt/ros/humble"
  : > "${_root}/opt/ros/noetic/setup.bash"
  : > "${_root}/opt/ros/humble/setup.bash"
  run bash -c "
    source '${RC}' >/dev/null 2>&1
    _ros_detect() {
      local d distro
      for d in '${_root}'/opt/ros/*/setup.bash; do
        [[ -f \"\${d}\" ]] || continue
        distro=\"\$(basename \"\$(dirname \"\${d}\")\")\"
        case \" \${_ROS1_DISTROS} \" in *\" \${distro} \"*) echo \"ros1:\${distro}\" ;; esac
        case \" \${_ROS2_DISTROS} \" in *\" \${distro} \"*) echo \"ros2:\${distro}\" ;; esac
      done
    }
    _ros_auto_source
  "
  assert_success
  assert_output --partial "Multiple ROS versions detected"
  assert_output --partial "ros1:noetic"
  assert_output --partial "ros2:humble"
}
