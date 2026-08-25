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

# ── Wrapper drivers ─────────────────────────────────────────────────────────

# Drive a real wrapper script through `--dry-run` with a logging `xhost` shim
# first on PATH, and print the argument list of every `xhost` call it made
# (one invocation per line).
#
# Usage: run_wrapper_xhost <wrapper_path> [NAME=VALUE ...]
#
#   run run_wrapper_xhost /lint/run.sh XDG_SESSION_TYPE=wayland
#   assert_success
#   assert_output --partial '+SI:localuser:smokeuser'
#
# Why a driver and not a grep: the host-ACL branch is four lines of run.sh
# that decide whether a GUI container can reach the display at all. A spec
# that re-states those four lines inline and asserts its own copy stays green
# when the real branch is deleted or inverted, so it tests nothing. This
# executes the shipped wrapper.
#
# How it reaches the branch without docker: the ACL grant happens before any
# daemon contact, and `--dry-run` short-circuits every step that needs one.
# The sandbox is a directory holding a symlink to the wrapper plus a symlink
# to its lib/ chain and a minimal `.env.generated`; the wrapper resolves
# FILE_PATH from its invocation directory, finds no `.base/` and no
# `.setup.conf` there, and therefore skips the whole setup/drift lifecycle.
#
# Fails (rather than printing an empty list) when the wrapper exits non-zero
# or never calls xhost at all -- otherwise a wrapper that died early, or one
# with the branch deleted, would satisfy every `refute_output` assertion.
run_wrapper_xhost() {
  local _wrapper="${1:?run_wrapper_xhost: missing wrapper path}"; shift
  if [[ ! -f "${_wrapper}" ]]; then
    batslib_print_kv_single 10 "wrapper" "${_wrapper}" \
      | batslib_decorate "wrapper script does not exist" \
      | fail
    return 1
  fi

  # Locate the wrapper's lib/ the way its own bootstrap preamble does:
  # `<dir>/../lib` in the source / .base layout, `<dir>/lib` in the flat
  # /lint layout the devel-test stage builds.
  local _real _wdir _libdir="" _cand
  _real="$(readlink -f -- "${_wrapper}" 2>/dev/null || printf '%s' "${_wrapper}")"
  _wdir="$(cd -- "$(dirname -- "${_real}")" && pwd -P)"
  for _cand in "${_wdir}/../lib" "${_wdir}/lib"; do
    if [[ -f "${_cand}/bootstrap.sh" ]]; then
      _libdir="$(cd -- "${_cand}" && pwd -P)"
      break
    fi
  done
  if [[ -z "${_libdir}" ]]; then
    batslib_print_kv_single 10 "wrapper" "${_wrapper}" \
      | batslib_decorate "cannot locate the wrapper's lib/ directory" \
      | fail
    return 1
  fi

  local _root _sandbox _bin _log
  _root="${BATS_TEST_TMPDIR:-/tmp}"
  _sandbox="$(mktemp -d "${_root}/wrapper-xhost.XXXXXX")"
  _bin="${_sandbox}/bin"
  _log="${_sandbox}/xhost.log"
  mkdir -p "${_bin}"

  ln -s "${_real}" "${_sandbox}/run.sh"
  ln -s "${_libdir}" "${_sandbox}/lib"

  # Minimal derived env. USER_NAME is what the Wayland grant interpolates,
  # so it is deliberately distinctive: a hard-coded `+SI:localuser:` suffix
  # in the wrapper would not match it.
  {
    printf 'USER_NAME=smokeuser\n'
    printf 'IMAGE_NAME=smokeimage\n'
    printf 'DOCKER_HUB_USER=smokeowner\n'
  } > "${_sandbox}/.env.generated"

  cat > "${_bin}/xhost" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_log}"
SHIM
  chmod +x "${_bin}/xhost"
  : > "${_log}"

  # env -u first so an unset-XDG_SESSION_TYPE case is genuinely unset even
  # when the build environment exports one; caller assignments follow and win.
  local _status=0
  env -u XDG_SESSION_TYPE \
    PATH="${_bin}:${PATH}" \
    QUIET=1 \
    "$@" \
    bash "${_sandbox}/run.sh" --dry-run >/dev/null 2>&1 || _status=$?

  if (( _status != 0 )); then
    batslib_print_kv_single_or_multi 10 \
      "wrapper" "${_wrapper}" \
      "status"  "${_status}" \
      | batslib_decorate "wrapper exited non-zero under --dry-run" \
      | fail
    return 1
  fi
  if [[ ! -s "${_log}" ]]; then
    batslib_print_kv_single 10 "wrapper" "${_wrapper}" \
      | batslib_decorate "wrapper made no xhost call at all" \
      | fail
    return 1
  fi

  cat "${_log}"
}
