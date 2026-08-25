#!/usr/bin/env bats
#
# Tests for the GUI+bridge hostname injection in generate_compose_yaml /
# the per-stage emitter (dist/script/docker/lib/compose_emit.sh).
#
# Rationale (ADR-00000019): under bridge networking the container otherwise gets a
# Docker-assigned random hostname, which breaks the LOCAL X11
# MIT-MAGIC-COOKIE (the cookie is keyed to the host's hostname). When GUI
# is enabled AND network.mode = bridge, the emitter pins the container's
# hostname to the host's name so local X still authenticates. Under host
# networking (the container already shares the host's UTS namespace) or
# when GUI is off, no hostname line is injected.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  # Pin a deterministic host name so the assertion does not depend on the
  # machine running the suite. generate_compose_yaml resolves the host name
  # from HOSTNAME (falling back to `uname -n`).
  export HOSTNAME="test-host-42"

  # Minimal baseline Dockerfile: devel + devel-test stages (mirrors
  # gen_spec.bats so the default no-custom-Dockerfile path emits both).
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# positional args (see gen_spec.bats):
#   out name gui gpu count caps extras net_name devices env tmpfs ports
#   shm net_mode ipc_mode ...

# ════════════════════════════════════════════════════════════════════
# devel service
# ════════════════════════════════════════════════════════════════════

@test "GUI + bridge injects hostname pinned to the host name on devel (#794)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "true" "false" "0" "gpu" _extras "" "" "" "" "" "" "bridge" "host"
  run grep -F 'hostname: test-host-42' "${COMPOSE_OUT}"
  assert_success
}

@test "GUI + host mode injects NO hostname on devel (#794)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "true" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host"
  run grep -E '^    hostname:' "${COMPOSE_OUT}"
  assert_failure
}

@test "GUI off + bridge injects NO hostname on devel (#794)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "bridge" "host"
  run grep -E '^    hostname:' "${COMPOSE_OUT}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# per-stage standalone emit (effective gui/net gate)
# ════════════════════════════════════════════════════════════════════

@test "per-stage GUI+bridge override injects hostname on that stage (#794)" {
  # Parent is GUI-off + host (devel emits NO hostname), so the only
  # possible source of a hostname line is the stage that opts into
  # GUI + bridge -- proving the standalone-emit path pins it via the
  # stage's EFFECTIVE flags.
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS probe
DOCK
  mkdir -p "${TEMP_DIR}"
  cat > "${TEMP_DIR}/.setup.conf" <<'CONF'
[stage:probe]
gui.mode = force
network.mode = bridge
CONF
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host"
  run grep -F 'hostname: test-host-42' "${COMPOSE_OUT}"
  assert_success
}

@test "per-stage GUI-off under bridge injects NO hostname (#794)" {
  # Parent GUI-off + host emits nothing; the stage stays on bridge but
  # turns the GUI off -> its effective gui is false, so no hostname line
  # anywhere. Guards the effective-flag gate on the standalone path.
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS probe
DOCK
  mkdir -p "${TEMP_DIR}"
  cat > "${TEMP_DIR}/.setup.conf" <<'CONF'
[stage:probe]
gui.mode = off
network.mode = bridge
CONF
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host"
  run grep -E '^    hostname:' "${COMPOSE_OUT}"
  assert_failure
}
