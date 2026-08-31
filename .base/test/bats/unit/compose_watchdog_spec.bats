#!/usr/bin/env bats
#
# Tests for [lifecycle] watchdog support in generate_compose_yaml and its
# resolution in _resolve_deploy_context: the WATCHDOG_* service
# environment is emitted ONLY when the master switch (watchdog_check) is
# set, so the default-off case leaves compose.yaml byte-identical (the
# default-off golden is unaffected).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
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

# _gcy_wd <watchdog_env_str> -- call generate_compose_yaml with the
# watchdog env block as the 31st positional arg (everything else defaulted).
_gcy_wd() {
  local _wd="${1-}"
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "" "" "no" "" "true" "${_wd}"
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: WATCHDOG_* env emission (gated on the switch)
# ════════════════════════════════════════════════════════════════════

@test "watchdog env omitted from compose when disabled (default off, #505 golden) (#797)" {
  _gcy_wd ""
  run grep -F "WATCHDOG_" "${COMPOSE_OUT}"
  assert_failure
}

@test "watchdog env emitted on devel when watchdog_check is set (#797)" {
  local _wd
  printf -v _wd '%s\n%s\n%s' \
    "WATCHDOG_CHECK=rosnode ping -a" "WATCHDOG_INTERVAL=15" "WATCHDOG_ON_FAIL=restart-service"
  _gcy_wd "${_wd}"
  run grep -F 'WATCHDOG_CHECK=rosnode ping -a' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'WATCHDOG_INTERVAL=15' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'WATCHDOG_ON_FAIL=restart-service' "${COMPOSE_OUT}"
  assert_success
}

@test "watchdog env value is YAML double-quoted (command with structural chars) (#797)" {
  local _wd="WATCHDOG_CHECK=test -f /tmp/ok && echo up: yes"
  _gcy_wd "${_wd}"
  # A ': ' in the value would re-parse as a YAML mapping unless quoted.
  run grep -F -- '- "WATCHDOG_CHECK=test -f /tmp/ok && echo up: yes"' "${COMPOSE_OUT}"
  assert_success
}

@test "watchdog env rides on devel; extends:devel stages inherit it (single emit) (#797)" {
  local _wd="WATCHDOG_CHECK=true"
  _gcy_wd "${_wd}"
  # devel carries the env; the test service extends:devel and inherits it,
  # so WATCHDOG_CHECK appears exactly once (not duplicated per service).
  run grep -cF "WATCHDOG_CHECK=true" "${COMPOSE_OUT}"
  assert_success
  assert_output "1"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_context: build the WATCHDOG_* env block from setup.conf
# ════════════════════════════════════════════════════════════════════

_write_conf() {
  cat > "${TEMP_DIR}/.setup.conf"
}

@test "_resolve_deploy_context yields empty watchdog_env_str when check unset (#797)" {
  mkdir -p "${TEMP_DIR}"
  _write_conf <<'EOF'
[lifecycle]
restart = no
init = true
EOF
  local -A _ctx=()
  _resolve_deploy_context "${TEMP_DIR}" _ctx
  [ -z "${_ctx[watchdog_env_str]}" ]
}

@test "_resolve_deploy_context builds WATCHDOG_* only for the set knobs (#797)" {
  mkdir -p "${TEMP_DIR}"
  _write_conf <<'EOF'
[lifecycle]
restart = on-failure
init = true
watchdog_check = curl -fsS localhost:8080/health
watchdog_failures = 5
watchdog_on_fail = restart-service
EOF
  local -A _ctx=()
  _resolve_deploy_context "${TEMP_DIR}" _ctx
  local _s="${_ctx[watchdog_env_str]}"
  echo "${_s}" | grep -F 'WATCHDOG_CHECK=curl -fsS localhost:8080/health'
  echo "${_s}" | grep -F 'WATCHDOG_FAILURES=5'
  echo "${_s}" | grep -F 'WATCHDOG_ON_FAIL=restart-service'
  # Unset knobs are NOT emitted (they fall back to watchdog.sh defaults).
  ! echo "${_s}" | grep -qF 'WATCHDOG_INTERVAL'
  ! echo "${_s}" | grep -qF 'WATCHDOG_NOTIFY'
}
