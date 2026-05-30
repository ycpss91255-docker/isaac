#!/usr/bin/env bats
#
# Unit tests for _assemble_mount_value -- pure function that builds the
# host:container[:mode] string used by [devices] device_* and [volumes]
# mount_* entries (#461).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  source /source/script/docker/lib/_tui_conf.sh
}

# ── #461: _assemble_mount_value ───────────────────────────────────

@test "_assemble_mount_value returns host:container when no mode (#461)" {
  run _assemble_mount_value /dev /dev
  assert_success
  assert_output "/dev:/dev"
}

@test "_assemble_mount_value returns host:container:mode for single mode (#461)" {
  run _assemble_mount_value /data /data ro
  assert_success
  assert_output "/data:/data:ro"
}

@test "_assemble_mount_value accepts combined access,propagation (#461)" {
  run _assemble_mount_value /dev /dev rw,rslave
  assert_success
  assert_output "/dev:/dev:rw,rslave"
}

@test "_assemble_mount_value output validates via _validate_mount (#461)" {
  # Assembled string must pass the validator (round-trip).
  local _result
  _result="$(_assemble_mount_value /dev /dev rw,rslave)"
  _validate_mount "${_result}"
}

@test "_assemble_mount_value empty mode means no suffix (#461)" {
  run _assemble_mount_value /a /b ""
  assert_success
  assert_output "/a:/b"
}

# ── #461 TUI picker flow (mocked) ───────────────────────────────────

@test "_prompt_mount_with_picker assembles full mount string from picker steps (#461)" {
  source /source/script/docker/wrapper/setup_tui.sh
  _QFILE="${BATS_TEST_TMPDIR}/q"
  : > "${_QFILE}"
  # Queue 4 responses: host, container, access, propagation
  printf '0|/dev\n0|/dev\n0|rw\n0|rslave\n' > "${_QFILE}"
  _tui_pop() {
    local _line; _line="$(head -n 1 "${_QFILE}")"; sed -i '1d' "${_QFILE}"
    printf '%s' "${_line#*|}"; return "${_line%%|*}"
  }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  export -f _tui_pop _tui_inputbox _tui_radiolist; export _QFILE
  run _prompt_mount_with_picker ""
  assert_success
  assert_output "/dev:/dev:rw,rslave"
}

@test "_prompt_mount_with_picker no propagation gives just host:container:access (#461)" {
  source /source/script/docker/wrapper/setup_tui.sh
  _QFILE="${BATS_TEST_TMPDIR}/q"
  : > "${_QFILE}"
  printf '0|/data\n0|/data\n0|ro\n0|none\n' > "${_QFILE}"
  _tui_pop() {
    local _line; _line="$(head -n 1 "${_QFILE}")"; sed -i '1d' "${_QFILE}"
    printf '%s' "${_line#*|}"; return "${_line%%|*}"
  }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  export -f _tui_pop _tui_inputbox _tui_radiolist; export _QFILE
  run _prompt_mount_with_picker ""
  assert_success
  assert_output "/data:/data:ro"
}

@test "_prompt_mount_with_picker no access + no propagation gives just host:container (#461)" {
  source /source/script/docker/wrapper/setup_tui.sh
  _QFILE="${BATS_TEST_TMPDIR}/q"
  : > "${_QFILE}"
  printf '0|/a\n0|/b\n0|none\n0|none\n' > "${_QFILE}"
  _tui_pop() {
    local _line; _line="$(head -n 1 "${_QFILE}")"; sed -i '1d' "${_QFILE}"
    printf '%s' "${_line#*|}"; return "${_line%%|*}"
  }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  export -f _tui_pop _tui_inputbox _tui_radiolist; export _QFILE
  run _prompt_mount_with_picker ""
  assert_success
  assert_output "/a:/b"
}
