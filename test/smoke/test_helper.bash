#!/usr/bin/env bash
#
# Shared bats test helper for smoke tests (copied into /smoke_test/ at the
# Dockerfile `test` stage). Intended to be load-ed by per-repo smoke specs:
#
#   setup() {
#     load "${BATS_TEST_DIRNAME}/test_helper"
#   }
#
# The helpers below are thin wrappers around common runtime assertions
# (binary on PATH, file/dir exists with expected ownership, python pkg
# installed via pip). They keep per-repo smoke specs short and self-
# documenting, e.g.:
#
#   @test "tmux is installed" { assert_cmd_installed tmux; }
#   @test "tpm cloned"        { assert_dir_exists "${HOME}/.tmux/plugins/tpm"; }
#   @test "rospy available"   { assert_pip_pkg rospkg; }

bats_load_library "bats-support"
bats_load_library "bats-assert"

# ── Runtime assertion helpers ───────────────────────────────────────────────

# Fail the test unless <cmd> is resolvable on PATH.
#
# Usage: assert_cmd_installed <cmd>
assert_cmd_installed() {
  local _cmd="${1:?assert_cmd_installed: missing cmd}"
  if ! command -v "${_cmd}" >/dev/null 2>&1; then
    batslib_print_kv_single 10 "cmd" "${_cmd}" \
      | batslib_decorate "command not found on PATH" \
      | fail
    return 1
  fi
}

# Fail the test unless <cmd> runs successfully with <version_flag>
# (default `--version`). Useful for catching "installed but broken" cases
# (missing shared libs, corrupt binary, etc.).
#
# Usage: assert_cmd_runs <cmd> [version_flag]
assert_cmd_runs() {
  local _cmd="${1:?assert_cmd_runs: missing cmd}"
  local _flag="${2:---version}"
  assert_cmd_installed "${_cmd}" || return 1
  run "${_cmd}" "${_flag}"
  # shellcheck disable=SC2154  # 'status' and 'output' are populated by `run`
  if (( status != 0 )); then
    batslib_print_kv_single_or_multi 10 \
      "cmd"    "${_cmd} ${_flag}" \
      "status" "${status}" \
      "output" "${output}" \
      | batslib_decorate "command ran but exited non-zero" \
      | fail
  fi
}

# Fail the test unless <path> exists and is a regular file.
#
# Usage: assert_file_exists <path>
assert_file_exists() {
  local _path="${1:?assert_file_exists: missing path}"
  if [[ ! -f "${_path}" ]]; then
    batslib_print_kv_single 10 "path" "${_path}" \
      | batslib_decorate "file does not exist" \
      | fail
  fi
}

# Fail the test unless <path> exists and is a directory.
#
# Usage: assert_dir_exists <path>
assert_dir_exists() {
  local _path="${1:?assert_dir_exists: missing path}"
  if [[ ! -d "${_path}" ]]; then
    batslib_print_kv_single 10 "path" "${_path}" \
      | batslib_decorate "directory does not exist" \
      | fail
  fi
}

# Fail the test unless <path>'s owning user matches <user>.
#
# Usage: assert_file_owned_by <user> <path>
assert_file_owned_by() {
  local _user="${1:?assert_file_owned_by: missing user}"
  local _path="${2:?assert_file_owned_by: missing path}"
  if [[ ! -e "${_path}" ]]; then
    batslib_print_kv_single 10 "path" "${_path}" \
      | batslib_decorate "path does not exist" \
      | fail
    return
  fi
  local _actual=""
  _actual="$(stat -c '%U' "${_path}")"
  if [[ "${_actual}" != "${_user}" ]]; then
    batslib_print_kv_single_or_multi 10 \
      "path"     "${_path}" \
      "expected" "${_user}" \
      "actual"   "${_actual}" \
      | batslib_decorate "owner mismatch" \
      | fail
  fi
}

# Fail the test unless <pkg> is visible to `pip show`.
#
# Usage: assert_pip_pkg <pkg>
assert_pip_pkg() {
  local _pkg="${1:?assert_pip_pkg: missing pkg}"
  assert_cmd_installed pip || return 1
  run pip show "${_pkg}"
  # shellcheck disable=SC2154
  if (( status != 0 )); then
    batslib_print_kv_single_or_multi 10 \
      "pkg"    "${_pkg}" \
      "status" "${status}" \
      "output" "${output}" \
      | batslib_decorate "pip package not installed" \
      | fail
  fi
}
