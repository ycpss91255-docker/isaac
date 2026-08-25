#!/usr/bin/env bats
#
# Unit tests for dist/test/bats/smoke/shared/test_helper.bash runtime
# assertion helpers.
# These helpers are intended to be load-ed by per-repo smoke specs inside
# the Docker `test` stage; here we exercise them in isolation under the
# template's own CI.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load "/source/dist/test/bats/smoke/shared/test_helper"

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

# ════════════════════════════════════════════════════════════════════
# run_wrapper_xhost
#
# The shipped smoke spec dist/test/bats/smoke/devel-test/display_env.bats
# calls this against /lint/run.sh, which only exists inside a downstream
# `-test` image. Driving the same helper against the wrapper at its source
# path puts the real xhost branch under base's own gate, so a deletion or
# an inversion goes red here and not only in a consumer's build.
# ════════════════════════════════════════════════════════════════════

_WRAPPER_UNDER_TEST=/source/dist/script/docker/wrapper/run.sh

@test "run_wrapper_xhost: wayland session grants +SI:localuser to the .env user" {
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_output "+SI:localuser:smokeuser"
}

@test "run_wrapper_xhost: x11 session grants +local:" {
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}" XDG_SESSION_TYPE=x11
  assert_success
  assert_output "+local:"
}

@test "run_wrapper_xhost: an unset XDG_SESSION_TYPE falls back to the X11 grant" {
  # env -u inside the helper, so this holds even when the CI container
  # exports a session type of its own.
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}"
  assert_success
  assert_output "+local:"
}

@test "run_wrapper_xhost: reports every xhost call, one per line" {
  # The count is what makes 'exactly one host ACL per invocation' assertable
  # downstream; a helper that collapsed or deduplicated calls would hide a
  # both-branches regression.
  run run_wrapper_xhost "${_WRAPPER_UNDER_TEST}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_equal "${#lines[@]}" 1
}

@test "run_wrapper_xhost: fails loudly when the wrapper makes no xhost call" {
  # Without this guard an empty capture would satisfy every refute_output
  # assertion in the shipped spec, so deleting the branch would read green.
  local _w="${TEMP_DIR}/wrapper"
  mkdir -p "${_w}" "${TEMP_DIR}/lib"
  : > "${TEMP_DIR}/lib/bootstrap.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${_w}/run.sh"
  run run_wrapper_xhost "${_w}/run.sh"
  assert_failure
  assert_output --partial "wrapper made no xhost call at all"
}

@test "run_wrapper_xhost: fails when the wrapper exits non-zero" {
  local _w="${TEMP_DIR}/wrapper"
  mkdir -p "${_w}" "${TEMP_DIR}/lib"
  : > "${TEMP_DIR}/lib/bootstrap.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' > "${_w}/run.sh"
  run run_wrapper_xhost "${_w}/run.sh"
  assert_failure
  assert_output --partial "wrapper exited non-zero"
  assert_output --partial "3"
}

@test "run_wrapper_xhost: fails when the wrapper path does not exist" {
  run run_wrapper_xhost "${TEMP_DIR}/no_such_wrapper.sh"
  assert_failure
  assert_output --partial "wrapper script does not exist"
}

@test "run_wrapper_xhost: fails when the wrapper's lib/ cannot be located" {
  local _w="${TEMP_DIR}/orphan"
  mkdir -p "${_w}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${_w}/run.sh"
  run run_wrapper_xhost "${_w}/run.sh"
  assert_failure
  assert_output --partial "cannot locate the wrapper's lib/ directory"
}

@test "run_wrapper_xhost: errors when the wrapper path arg is missing" {
  run run_wrapper_xhost
  assert_failure
  assert_output --partial "missing wrapper path"
}
