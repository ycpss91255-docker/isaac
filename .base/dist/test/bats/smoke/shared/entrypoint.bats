#!/usr/bin/env bats
#
# Shared build-time smoke: the "does it even come up" baseline that runs
# inside EVERY Dockerfile `-test` stage (devel-test and runtime-test),
# so it must only assert things present in every real stage under test.
# It therefore avoids /lint (populated only in devel-test) and touches
# just the universal surface: the installed entrypoint + bash on PATH.
# Loaded together with the shared test_helper.bash (both live under
# smoke/shared/ and are COPYed into /smoke_test/ by each `-test` stage).

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
