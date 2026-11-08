#!/usr/bin/env bats
#
# Isaac Sim image smoke. Image-side; runs in /smoke_test/ inside the
# test stage built atop the Dockerfile's BASE_IMAGE (nvcr.io/nvidia/isaac-sim).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "isaac-sim launchers exist and are executable" {
  test -x /isaac-sim/runheadless.sh
  test -x /isaac-sim/runapp.sh
}

@test "isaac-sim ships Python 3.12 in /isaac-sim/kit/python/bin/python3" {
  test -x /isaac-sim/kit/python/bin/python3
  run /isaac-sim/kit/python/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
  assert_success
  assert_output "3.12"
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
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.core/humble/lib
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.core/jazzy/lib
  run ls /isaac-sim/exts/isaacsim.ros2.core/humble/lib/librmw_fastrtps_cpp.so
  assert_success
  run ls /isaac-sim/exts/isaacsim.ros2.core/jazzy/lib/librmw_fastrtps_cpp.so
  assert_success
}

@test "bundled ROS 2 humble + jazzy rclpy are both readable (Python 3.12)" {
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.core/humble/rclpy/rclpy
  assert_dir_exists /isaac-sim/exts/isaacsim.ros2.core/jazzy/rclpy/rclpy
}

# Isaac Lab is installed against the bundled Isaac Sim (the _isaac_sim
# symlink), so the two must be the release pair NVIDIA ships together.
# Isaac Lab 3.0 records the Isaac Sim it targets in its root pyproject
# ([tool.isaaclab.versions] isaacsim = "X.Y.Z.N"); /isaac-sim/VERSION
# reads "X.Y.Z-rc.N+...". Bumping one pin without the other fails here
# instead of at the first Kit boot (isaac#295).
@test "Isaac Lab targets the Isaac Sim release the image bundles" {
  local sim lab
  sim="$(cut -d- -f1 /isaac-sim/VERSION)"
  run /isaac-sim/kit/python/bin/python3 -c '
import tomllib
with open("/opt/IsaacLab/pyproject.toml", "rb") as f:
    print(tomllib.load(f)["tool"]["isaaclab"]["versions"]["isaacsim"])
'
  assert_success
  lab="${output}"
  [[ "${lab}" == "${sim}" || "${lab}" == "${sim}".* ]] || {
    echo "Isaac Lab targets isaacsim ${lab}, image bundles ${sim}" >&2
    return 1
  }
}

# Isaac Lab's installer owns the torch install and pulls its pinned
# version from the CUDA 13 index (cu130 carries sm_120 kernels for the
# RTX 5090 runner). A different build on the Isaac python means another
# pip step overrode it (isaac#295).
@test "Isaac python torch is Isaac Lab's pinned CUDA 13 build" {
  local pin
  pin="$(/isaac-sim/kit/python/bin/python3 -c '
import tomllib
with open("/opt/IsaacLab/pyproject.toml", "rb") as f:
    print(tomllib.load(f)["tool"]["isaaclab"]["versions"]["torch"])
')"
  run /isaac-sim/kit/python/bin/python3 -c \
    'import importlib.metadata as m; print(m.version("torch"))'
  assert_success
  assert_output "${pin}+cu130"
}

# Isaac Sim shares prebundled packages between extensions as symlink
# farms. A pip step that deletes the copy the others link into leaves the
# package without an importable __init__.py -- on 6.0.1 that was
# `packaging` under omni.services.pip_archive, which silently broke
# matplotlib plots and the Newton experience (isaac#288).
@test "no pip_prebundle package lost its __init__.py (isaac#288)" {
  run find /isaac-sim -xtype l -name '__init__.py' -path '*pip_prebundle*'
  assert_success
  assert_output ""
}

# The bundled URDF importer imports newton_usd_schemas at load, while
# Isaac Lab's experience excludes isaacsim.pip.newton (the prebundle that
# carries it). The module must therefore come from the Isaac python's own
# site-packages, where every boot path sees it, rather than from a
# sys.path shim (isaac#247).
@test "newton_usd_schemas resolves from the Isaac python site-packages (isaac#247)" {
  run /isaac-sim/kit/python/bin/python3 -c '
import importlib.util
spec = importlib.util.find_spec("newton_usd_schemas")
print(spec.origin if spec else "NOT FOUND")
'
  assert_success
  assert_output --partial "/isaac-sim/kit/python/lib/python3.12/site-packages/newton_usd_schemas/"
}
