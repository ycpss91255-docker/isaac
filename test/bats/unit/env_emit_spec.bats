#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# write_env: SSH X11 XAUTHORITY override
# ════════════════════════════════════════════════════════════════════
@test "write_env emits XAUTHORITY=<rewritten> when _ssh_x11_xauth arg is set (#321)" {
  local _env="${TEMP_DIR}/.env.generated"
  # Pass all positional args incl. the new trailing _ssh_x11_xauth.
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    "/path/to/.docker.xauth"
  assert [ -f "${_env}" ]
  run grep -F 'XAUTHORITY=/path/to/.docker.xauth' "${_env}"
  assert_success
  run grep -F 'SSH X11 forwarding cookie override' "${_env}"
  assert_success
}

@test "write_env does NOT emit XAUTHORITY override when _ssh_x11_xauth arg is empty (#321)" {
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host private false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    ""
  assert [ -f "${_env}" ]
  run cat "${_env}"
  refute_output --partial "SSH X11 forwarding cookie override"
  refute_output --partial $'\nXAUTHORITY='
}

# ════════════════════════════════════════════════════════════════════
# write_env
# ════════════════════════════════════════════════════════════════════
@test "write_env creates .env with all required variables and SETUP_* metadata" {
  local _env="${TEMP_DIR}/.env.generated"
  write_env "${_env}" \
    "testuser" "testgroup" "1001" "1001" \
    "x86_64" "dockerhub" "true" \
    "ros_noetic" "/workspace" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" \
    "all" "gpu" \
    "true" "abc123" "df456"

  assert [ -f "${_env}" ]
  run grep 'USER_NAME=testuser' "${_env}"; assert_success
  run grep 'USER_UID=1001'      "${_env}"; assert_success
  run grep 'GPU_ENABLED=true'   "${_env}"; assert_success
  run grep 'IMAGE_NAME=ros_noetic' "${_env}"; assert_success
  run grep 'NETWORK_MODE=host'  "${_env}"; assert_success
  run grep 'IPC_MODE=host'      "${_env}"; assert_success
  run grep 'PID_MODE=private'   "${_env}"; assert_success
  run grep 'PRIVILEGED=true'    "${_env}"; assert_success
  run grep 'GPU_COUNT=all'      "${_env}"; assert_success
  run grep -F 'GPU_CAPABILITIES="gpu"' "${_env}"; assert_success
  run grep 'SETUP_CONF_HASH=abc123' "${_env}"; assert_success
  run grep 'SETUP_DOCKERFILE_HASH=df456' "${_env}"; assert_success
  run grep 'SETUP_GUI_DETECTED=true' "${_env}"; assert_success
  run grep -E '^SETUP_TIMESTAMP=' "${_env}"; assert_success
  run grep 'APT_MIRROR_UBUNTU=tw.archive.ubuntu.com' "${_env}"; assert_success
  run grep 'APT_MIRROR_DEBIAN=mirror.twds.com.tw' "${_env}"; assert_success
  run grep 'TZ=Asia/Taipei' "${_env}"; assert_success
  # bash-source round-trip: re-loading the file must not raise a
  # "command not found" on any multi-word value (regression: previously
  # GPU_CAPABILITIES="gpu compute utility graphics" was unquoted).
  run bash -c "set -o allexport; source '${_env}'"
  assert_success
  refute_output --partial "command not found"
}

# ════════════════════════════════════════════════════════════════════
# .env.generated cache + .env workload overlay (A2 file roles,)
# ════════════════════════════════════════════════════════════════════
@test "_scaffold_env_overlay is idempotent (never overwrites)" {
  printf 'USER_KEY=keep\n' > "${TEMP_DIR}/.env"
  run _scaffold_env_overlay "${TEMP_DIR}/.env"
  assert_success
  run cat "${TEMP_DIR}/.env"
  assert_output "USER_KEY=keep"
}
