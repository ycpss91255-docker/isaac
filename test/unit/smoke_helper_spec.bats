#!/usr/bin/env bats
#
# Unit tests for test/smoke/test_helper.bash runtime assertion helpers.
# These helpers are intended to be load-ed by per-repo smoke specs inside
# the Docker `test` stage; here we exercise them in isolation under the
# template's own CI.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load "/source/test/smoke/test_helper"

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# assert_cmd_installed
# ════════════════════════════════════════════════════════════════════

@test "assert_cmd_installed passes when cmd is on PATH" {
  mock_cmd "fakecmd" 'exit 0'
  run assert_cmd_installed fakecmd
  assert_success
}

@test "assert_cmd_installed fails with descriptive message when cmd missing" {
  run assert_cmd_installed no_such_cmd_xyzzy
  assert_failure
  assert_output --partial "command not found on PATH"
  assert_output --partial "no_such_cmd_xyzzy"
}

@test "assert_cmd_installed errors when cmd arg missing" {
  run assert_cmd_installed
  assert_failure
  assert_output --partial "missing cmd"
}

# ════════════════════════════════════════════════════════════════════
# assert_cmd_runs
# ════════════════════════════════════════════════════════════════════

@test "assert_cmd_runs passes when cmd exits 0" {
  mock_cmd "fakecmd" 'echo "v1.2.3"; exit 0'
  run assert_cmd_runs fakecmd
  assert_success
}

@test "assert_cmd_runs uses custom version flag when given" {
  mock_cmd "fakecmd" '
    if [[ "$1" == "-V" ]]; then exit 0; fi
    exit 99'
  run assert_cmd_runs fakecmd -V
  assert_success
}

@test "assert_cmd_runs fails when cmd exits non-zero" {
  mock_cmd "fakecmd" 'echo "boom" >&2; exit 7'
  run assert_cmd_runs fakecmd
  assert_failure
  assert_output --partial "exited non-zero"
  assert_output --partial "status"
}

@test "assert_cmd_runs fails when cmd is not installed" {
  run assert_cmd_runs no_such_cmd_xyzzy
  assert_failure
  assert_output --partial "command not found on PATH"
}

# ════════════════════════════════════════════════════════════════════
# assert_file_exists
# ════════════════════════════════════════════════════════════════════

@test "assert_file_exists passes when file is a regular file" {
  local _file="${TEMP_DIR}/present.txt"
  : > "${_file}"
  run assert_file_exists "${_file}"
  assert_success
}

@test "assert_file_exists fails when path is missing" {
  run assert_file_exists "${TEMP_DIR}/missing.txt"
  assert_failure
  assert_output --partial "file does not exist"
}

@test "assert_file_exists fails when path is a directory" {
  run assert_file_exists "${TEMP_DIR}"
  assert_failure
  assert_output --partial "file does not exist"
}

# ════════════════════════════════════════════════════════════════════
# assert_dir_exists
# ════════════════════════════════════════════════════════════════════

@test "assert_dir_exists passes when path is a directory" {
  run assert_dir_exists "${TEMP_DIR}"
  assert_success
}

@test "assert_dir_exists fails when path is missing" {
  run assert_dir_exists "${TEMP_DIR}/nodir"
  assert_failure
  assert_output --partial "directory does not exist"
}

@test "assert_dir_exists fails when path is a file" {
  local _file="${TEMP_DIR}/a_file"
  : > "${_file}"
  run assert_dir_exists "${_file}"
  assert_failure
  assert_output --partial "directory does not exist"
}

# ════════════════════════════════════════════════════════════════════
# assert_file_owned_by
# ════════════════════════════════════════════════════════════════════

@test "assert_file_owned_by passes when owner matches" {
  local _file="${TEMP_DIR}/owned.txt"
  : > "${_file}"
  local _user
  _user="$(stat -c '%U' "${_file}")"
  run assert_file_owned_by "${_user}" "${_file}"
  assert_success
}

@test "assert_file_owned_by fails with owner diff when user mismatches" {
  local _file="${TEMP_DIR}/owned.txt"
  : > "${_file}"
  run assert_file_owned_by definitely_not_a_real_user "${_file}"
  assert_failure
  assert_output --partial "owner mismatch"
  assert_output --partial "expected"
  assert_output --partial "actual"
}

@test "assert_file_owned_by fails when path missing" {
  run assert_file_owned_by root "${TEMP_DIR}/missing"
  assert_failure
  assert_output --partial "path does not exist"
}

# ════════════════════════════════════════════════════════════════════
# assert_pip_pkg
# ════════════════════════════════════════════════════════════════════

@test "assert_pip_pkg passes when pip show returns 0" {
  mock_cmd "pip" '
    if [[ "$1" == "show" ]]; then exit 0; fi
    exit 0'
  run assert_pip_pkg somepkg
  assert_success
}

@test "assert_pip_pkg fails when pip show returns non-zero" {
  mock_cmd "pip" '
    if [[ "$1" == "show" ]]; then exit 1; fi
    exit 0'
  run assert_pip_pkg missingpkg
  assert_failure
  assert_output --partial "pip package not installed"
  assert_output --partial "missingpkg"
}

@test "assert_pip_pkg fails when pip is not installed" {
  run assert_pip_pkg any
  assert_failure
  assert_output --partial "command not found on PATH"
  assert_output --partial "pip"
}
