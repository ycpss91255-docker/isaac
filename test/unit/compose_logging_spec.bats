#!/usr/bin/env bats
#
# Tests for [logging] / [logging.<svc>] support in generate_compose_yaml
# and the supporting _collect_logging / _parse_logging_svc_sections
# parsers in script/docker/setup.sh. Closes #310.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  CONF_FILE="${TEMP_DIR}/setup.conf"
}

teardown() {
  unset SETUP_CONF
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: logging block emission
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml omits logging: block when both inputs empty (back-compat)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "" ""
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits logging: block on devel from global [logging]" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s\n%s' \
    "driver=json-file" "max_size=10m" "max_file=3" "compress=true"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'driver: json-file' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "10m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-file: "3"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'compress: "true"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits logging on test service" {
  local _extras=()
  local _global="driver=local"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # The test service block sits after devel; assert the logging line
  # appears at least twice (once for devel, once for test).
  run grep -c -E '^    logging:$' "${COMPOSE_OUT}"
  assert_success
  [[ "${output}" -ge 2 ]]
}

@test "generate_compose_yaml driver-only [logging] omits options: block" {
  local _extras=()
  local _global="driver=syslog"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F 'driver: syslog' "${COMPOSE_OUT}"
  assert_success
  run grep -E '^      options:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml partial options emits only set keys" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -E '^      options:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "50m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-file' "${COMPOSE_OUT}"
  assert_failure
  run grep -F 'compress' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml per-svc [logging.<svc>] overrides global key on that svc" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s' "driver=json-file" "max_size=10m" "max_file=3"
  local _per_svc="test:max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # Both 10m (devel/global) and 50m (test override) should appear.
  run grep -F 'max-size: "10m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "50m"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml per-svc [logging.<svc>] inherits keys absent in override" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s' "driver=json-file" "max_size=10m" "max_file=3"
  local _per_svc="test:max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # The `test` service's logging block must still emit max-file (inherited).
  # Slice from the second `logging:` line onward and assert max-file appears.
  run awk '/^    logging:$/ { c++ } c >= 2 { print }' "${COMPOSE_OUT}"
  assert_success
  echo "${output}" | grep -F 'max-file: "3"'
}

# ════════════════════════════════════════════════════════════════════
# _parse_logging_svc_sections
# ════════════════════════════════════════════════════════════════════

@test "_parse_logging_svc_sections enumerates services in file order" {
  cat > "${CONF_FILE}" <<'CONF'
[logging]
driver = json-file

[logging.runtime]
max_size = 50m

[logging.devel]
compress = false
CONF
  local -a _svcs=()
  _parse_logging_svc_sections "${CONF_FILE}" _svcs
  [[ "${#_svcs[@]}" -eq 2 ]]
  [[ "${_svcs[0]}" == "runtime" ]]
  [[ "${_svcs[1]}" == "devel" ]]
}

@test "_parse_logging_svc_sections ignores plain [logging] section" {
  cat > "${CONF_FILE}" <<'CONF'
[logging]
driver = json-file
CONF
  local -a _svcs=()
  _parse_logging_svc_sections "${CONF_FILE}" _svcs
  [[ "${#_svcs[@]}" -eq 0 ]]
}

@test "_parse_logging_svc_sections returns empty when file does not exist" {
  local -a _svcs=()
  _parse_logging_svc_sections "/no/such/file" _svcs
  [[ "${#_svcs[@]}" -eq 0 ]]
}

# ════════════════════════════════════════════════════════════════════
# _collect_logging
# ════════════════════════════════════════════════════════════════════

@test "_collect_logging reads global [logging] from per-repo setup.conf" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[logging]
driver = local
max_size = 20m
CONF
  local _g="" _p=""
  _collect_logging "${TEMP_DIR}" _g _p
  [[ "${_g}" == *"driver=local"* ]]
  [[ "${_g}" == *"max_size=20m"* ]]
  [[ -z "${_p}" ]]
}

@test "_collect_logging reads per-service [logging.<svc>] sections" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[logging]
driver = json-file

[logging.runtime]
max_size = 100m
compress = false
CONF
  local _g="" _p=""
  _collect_logging "${TEMP_DIR}" _g _p
  [[ "${_p}" == *"runtime:max_size=100m"* ]]
  [[ "${_p}" == *"runtime:compress=false"* ]]
}

@test "_collect_logging returns empty when no [logging] sections anywhere" {
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[image]
rule_1 = @basename
CONF
  local _g="" _p=""
  # Force template fallback to also miss (point _SETUP_SCRIPT_DIR at a
  # path whose ../../config/docker/setup.conf does not exist).
  local _save="${_SETUP_SCRIPT_DIR:-}"
  _SETUP_SCRIPT_DIR="${TEMP_DIR}/nonexistent/docker"
  _collect_logging "${TEMP_DIR}" _g _p
  _SETUP_SCRIPT_DIR="${_save}"
  [[ -z "${_g}" ]]
  [[ -z "${_p}" ]]
}
