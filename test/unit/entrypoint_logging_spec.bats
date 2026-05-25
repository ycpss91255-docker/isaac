#!/usr/bin/env bats
#
# Tests for script/docker/_entrypoint_logging.sh -- the helper sourced
# from repo entrypoints to tee container stdout/stderr to the host
# bind-mounted log file when [logging] local_path is set (#328).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _entrypoint_logging.sh helper (#328)
# ════════════════════════════════════════════════════════════════════

@test "entrypoint_logging is no-op when LOG_FILE_PATH unset (#328)" {
  # Subshell, LOG_FILE_PATH unset, sourcing the helper must succeed
  # and not crash. After sourcing, plain echo should not produce a file.
  run bash -c '
    unset LOG_FILE_PATH
    . /source/script/docker/_entrypoint_logging.sh
    echo "ok"
  '
  assert_success
  assert_output "ok"
}

@test "entrypoint_logging tees stdout to LOG_FILE_PATH when set (#328)" {
  local _log="${TEMP_DIR}/devel.log"
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    . /source/script/docker/_entrypoint_logging.sh
    echo 'hello from entrypoint'
    # sync so the tee subprocess flushes before we read.
    sleep 0.2
  "
  assert_success
  # Stdout still carries the line (docker logs preserve)
  assert_output --partial "hello from entrypoint"
  # And the host file contains it too
  run grep -F "hello from entrypoint" "${_log}"
  assert_success
}

@test "entrypoint_logging truncates LOG_FILE_PATH on each run (#328)" {
  local _log="${TEMP_DIR}/devel.log"
  echo "stale content from prior run" > "${_log}"
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    . /source/script/docker/_entrypoint_logging.sh
    echo 'fresh run'
    sleep 0.2
  "
  assert_success
  # Stale content gone
  run grep -F "stale content" "${_log}"
  assert_failure
  # Fresh content present
  run grep -F "fresh run" "${_log}"
  assert_success
}

@test "entrypoint_logging creates parent dir if missing (#328)" {
  local _log="${TEMP_DIR}/nested/dir/devel.log"
  [[ ! -d "${TEMP_DIR}/nested" ]]
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    . /source/script/docker/_entrypoint_logging.sh
    echo 'parent-created'
    sleep 0.2
  "
  assert_success
  [[ -d "${TEMP_DIR}/nested/dir" ]]
  run grep -F "parent-created" "${_log}"
  assert_success
}

@test "entrypoint_logging warns + continues when target is a directory (#328)" {
  # Pre-create the target path as a directory so the truncate step
  # (`: > path`) fails -- exercises the warn-and-continue branch.
  # This works for both root and non-root callers (chmod-based test
  # was skipped under root, which the test harness runs as).
  local _log="${TEMP_DIR}/devel.log"
  mkdir -p "${_log}"
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    . /source/script/docker/_entrypoint_logging.sh
    echo 'should still print'
  " 2>&1
  assert_success
  # Warning visible on stderr (combined here)
  assert_output --partial "WARN"
  # Fallback emitted the line through to the inherited stdout
  assert_output --partial "should still print"
}

@test "entrypoint_logging captures stderr along with stdout (#328)" {
  local _log="${TEMP_DIR}/devel.log"
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    . /source/script/docker/_entrypoint_logging.sh
    echo 'on-stdout'
    echo 'on-stderr' >&2
    sleep 0.2
  " 2>&1
  assert_success
  # Both lines land in the file.
  run grep -F "on-stdout" "${_log}"
  assert_success
  run grep -F "on-stderr" "${_log}"
  assert_success
}
