#!/usr/bin/env bats
#
# Unit tests for the shared [logging] / [logging.<svc>] parsers in
# lib/conf_logging.sh.
#
# Parsers were extracted from script/docker/wrapper/setup.sh during the
# #402 lifecycle refactor (PR-A) so that lib/gitignore.sh can reuse the
# same logic without circular sourcing (setup.sh used to own both the
# parser and the runtime-time gitignore sync; PR-B moves the sync to
# init.sh while keeping the parser as a shared primitive).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # _collect_logging depends on _parse_ini_section (defined in setup.sh)
  # and _SETUP_SCRIPT_DIR (set when setup.sh is sourced). Source order:
  # setup.sh first, then conf_logging.sh so the lib's definitions win
  # the second-definition tie-break (mirrors how setup.sh will source
  # the lib once the rewire commit lands in PR-A's later cycle).
  # shellcheck disable=SC1091
  source /source/script/docker/wrapper/setup.sh
  # shellcheck disable=SC1091
  source /source/script/docker/lib/conf_logging.sh

  TEMP_DIR="$(mktemp -d)"
  CONF_FILE="${TEMP_DIR}/setup.conf"
}

teardown() {
  unset SETUP_CONF
  rm -rf "${TEMP_DIR}"
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
