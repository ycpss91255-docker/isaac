#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# -------------------- build.sh --------------------

@test "build.sh -h exits 0" {
  run bash /lint/build.sh -h
  assert_success
}

@test "build.sh --help exits 0" {
  run bash /lint/build.sh --help
  assert_success
}

@test "build.sh -h prints usage" {
  run bash /lint/build.sh -h
  assert_line --partial "Usage:"
}

# -------------------- run.sh --------------------

@test "run.sh -h exits 0" {
  run bash /lint/run.sh -h
  assert_success
}

@test "run.sh --help exits 0" {
  run bash /lint/run.sh --help
  assert_success
}

@test "run.sh -h prints usage" {
  run bash /lint/run.sh -h
  assert_line --partial "Usage:"
}

# -------------------- exec.sh --------------------

@test "exec.sh -h exits 0" {
  run bash /lint/exec.sh -h
  assert_success
}

@test "exec.sh --help exits 0" {
  run bash /lint/exec.sh --help
  assert_success
}

@test "exec.sh -h prints usage" {
  run bash /lint/exec.sh -h
  assert_line --partial "Usage:"
}

# -------------------- stop.sh --------------------

@test "stop.sh -h exits 0" {
  run bash /lint/stop.sh -h
  assert_success
}

@test "stop.sh --help exits 0" {
  run bash /lint/stop.sh --help
  assert_success
}

@test "stop.sh -h prints usage" {
  run bash /lint/stop.sh -h
  assert_line --partial "Usage:"
}

# -------------------- LANG auto-detect --------------------

@test "build.sh detects zh from LANG=zh_TW.UTF-8" {
  run env LANG=zh_TW.UTF-8 bash /lint/build.sh -h
  assert_success
  assert_line --partial "用法:"
}

@test "build.sh detects ja from LANG=ja_JP.UTF-8" {
  run env LANG=ja_JP.UTF-8 bash /lint/build.sh -h
  assert_success
  assert_line --partial "使用法:"
}

@test "build.sh defaults to en for LANG=en_US.UTF-8" {
  run env LANG=en_US.UTF-8 bash /lint/build.sh -h
  assert_success
  assert_line --partial "Usage:"
}

@test "build.sh SETUP_LANG overrides LANG" {
  run env LANG=ja_JP.UTF-8 SETUP_LANG=zh-TW bash /lint/build.sh -h
  assert_success
  assert_line --partial "用法:"
}
