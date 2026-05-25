#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the `devel` image built
# from this repo's Dockerfile, via the `test` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, assert_pip_pkg, ...) to keep
# assertions terse. Add one assertion per meaningful installation
# artifact.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}

@test "fastdds.xml is baked at /isaac-sim/fastdds.xml and world-readable" {
  assert_file_exists /isaac-sim/fastdds.xml
  test -r /isaac-sim/fastdds.xml
  run grep -q '<useBuiltinTransports>false</useBuiltinTransports>' /isaac-sim/fastdds.xml
  assert_success
}

@test "custom streaming kit experience baked at /isaac-sim/apps/ (issue #21 fix-B)" {
  # SimulationApp drivers opt in via experience="/isaac-sim/apps/<name>.kit".
  # Lacking this file, the driver falls back to the bundled
  # isaacsim.exp.base.python.kit which has no livestream extensions →
  # `livestream: 2` becomes a no-op and the WebRTC Streaming Client has
  # no server to connect to.
  assert_file_exists /isaac-sim/apps/isaacsim.exp.base.python.streaming.kit
  test -r /isaac-sim/apps/isaacsim.exp.base.python.streaming.kit
  # Confirms the file actually bundles the streaming extensions instead of
  # being a stub. Grep for both core + webrtc to catch a partial copy.
  run grep -q 'omni.kit.livestream.core' /isaac-sim/apps/isaacsim.exp.base.python.streaming.kit
  assert_success
  run grep -q 'omni.kit.livestream.webrtc' /isaac-sim/apps/isaacsim.exp.base.python.streaming.kit
  assert_success
}
