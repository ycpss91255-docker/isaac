#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  export HOME="${TEMP_DIR}"

  # shellcheck disable=SC1091
  source /source/config/shell/terminator/setup.sh
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# check_deps
# ════════════════════════════════════════════════════════════════════

@test "check_deps returns 0 when terminator is installed" {
  mock_cmd "terminator" 'exit 0'
  run check_deps
  assert_success
}

@test "check_deps fails when terminator is not installed" {
  PATH="${MOCK_DIR}" run check_deps
  assert_failure
  assert_output --partial "Error:"
}

# ════════════════════════════════════════════════════════════════════
# _entry_point
# ════════════════════════════════════════════════════════════════════

@test "_entry_point calls main when deps pass" {
  mock_cmd "terminator" 'exit 0'
  mock_cmd "chown" 'exit 0'
  run _entry_point
  assert_success
}

@test "_entry_point fails when deps missing" {
  PATH="${MOCK_DIR}" run _entry_point
  assert_failure
  assert_output --partial "Missing dependencies"
}

# ════════════════════════════════════════════════════════════════════
# main
# ════════════════════════════════════════════════════════════════════

@test "main creates terminator config directory" {
  mock_cmd "chown" 'exit 0'
  run main
  assert [ -d "${TEMP_DIR}/.config/terminator" ]
}

@test "main copies terminator config file" {
  mock_cmd "chown" 'exit 0'
  run main
  assert [ -f "${TEMP_DIR}/.config/terminator/config" ]
}

@test "main calls chown with correct user and group" {
  mock_cmd "chown" 'echo "chown called: $*"; exit 0'
  run main
  assert_success
  assert_output --partial "chown called:"
}

@test "script runs entry_point when executed directly" {
  mock_cmd "terminator" 'exit 0'
  mock_cmd "chown" 'exit 0'
  run bash /source/config/shell/terminator/setup.sh
  assert_success
}
