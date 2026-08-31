#!/usr/bin/env bats
#
# The diagnostic for a configured `[network] port_*` that will never be
# published.
#
# The template ships `[network] mode = host`, and compose only honours a
# `ports:` block under bridge -- so under the shipped default a configured port
# mapping is dropped. Every layer up to that point behaves as if the value
# mattered: the TUI has a dedicated ports editor, `_validate_port_mapping`
# rejects a malformed mapping, and `set` / `add` store it. The value was then
# discarded with no diagnostic anywhere: not at set time, not at apply time,
# not at run time.
#
# ADR-00000019 chose the host default deliberately, so the fix is a diagnostic,
# not a default change. The warning fires where the user can act on it -- when
# the value is stored, and again when the emitter drops it (dev compose and the
# field-deploy compose alike).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  export SETUP_LANG=en
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
  SETUP_SH="/source/dist/script/docker/wrapper/setup.sh"
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

_write_conf() {
  local _dir="${1}"; shift
  mkdir -p "${_dir}"
  printf '%s\n' "$@" > "${_dir}/.setup.conf"
}

# The stable English fragment every fire point shares.
_INERT="publishes ports only under mode = bridge"

# ════════════════════════════════════════════════════════════════════
# set / add: warn when the stored value cannot take effect
# ════════════════════════════════════════════════════════════════════

@test "set network.port_N under the shipped host default warns (#879)" {
  run bash "${SETUP_SH}" set network.port_1 8080:80 --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "${_INERT}"
}

@test "set network.port_N under mode = bridge stays quiet (#879)" {
  _write_conf "${TEMP_DIR}" "[network]" "mode = bridge"
  run bash "${SETUP_SH}" set network.port_1 8080:80 --base-path "${TEMP_DIR}"
  assert_success
  refute_output --partial "${_INERT}"
}

@test "add network.port under the shipped host default warns (#879)" {
  run bash "${SETUP_SH}" add network.port 8080:80 --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "${_INERT}"
}

@test "add network.port under mode = bridge stays quiet (#879)" {
  _write_conf "${TEMP_DIR}" "[network]" "mode = bridge"
  run bash "${SETUP_SH}" add network.port 8080:80 --base-path "${TEMP_DIR}"
  assert_success
  refute_output --partial "${_INERT}"
}

@test "set network.mode host with ports already configured warns (#879)" {
  # The symmetric move: the ports were fine until the mode changed under them.
  _write_conf "${TEMP_DIR}" "[network]" "mode = bridge" "port_1 = 8080:80"
  run bash "${SETUP_SH}" set network.mode host --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "${_INERT}"
}

@test "set network.mode bridge with ports already configured stays quiet (#879)" {
  _write_conf "${TEMP_DIR}" "[network]" "mode = host" "port_1 = 8080:80"
  run bash "${SETUP_SH}" set network.mode bridge --base-path "${TEMP_DIR}"
  assert_success
  refute_output --partial "${_INERT}"
}

@test "set network.mode host with no ports configured stays quiet (#879)" {
  run bash "${SETUP_SH}" set network.mode host --base-path "${TEMP_DIR}"
  assert_success
  refute_output --partial "${_INERT}"
}

@test "--quiet suppresses the confirmation but never the port diagnostic (#879)" {
  # --quiet is for scripted callers that do not want the 3-line receipt; a
  # value that will be silently dropped is not chatter.
  run bash "${SETUP_SH}" set network.port_1 8080:80 --base-path "${TEMP_DIR}" --quiet
  assert_success
  refute_output --partial "[setup] set [network]"
  assert_output --partial "${_INERT}"
}

# ════════════════════════════════════════════════════════════════════
# apply: warn when the dev compose emitter drops the block
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml warns when it drops ports under host mode (#879)" {
  local _out="${TEMP_DIR}/compose.yaml"
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
EOF
  local _extras=() _ports
  printf -v _ports '%s' "8080:80"
  run generate_compose_yaml "${_out}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "${_ports}" "" "host" "host"
  assert_success
  assert_output --partial "${_INERT}"
  run grep -E '^    ports:$' "${_out}"
  assert_failure
}

@test "generate_compose_yaml stays quiet when it emits ports under bridge (#879)" {
  local _out="${TEMP_DIR}/compose.yaml"
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
EOF
  local _extras=() _ports
  printf -v _ports '%s' "8080:80"
  run generate_compose_yaml "${_out}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "${_ports}" "" "bridge" "host"
  assert_success
  refute_output --partial "${_INERT}"
}

@test "generate_compose_yaml stays quiet under host mode with no ports (#879)" {
  local _out="${TEMP_DIR}/compose.yaml"
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
EOF
  local _extras=()
  run generate_compose_yaml "${_out}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host"
  assert_success
  refute_output --partial "${_INERT}"
}

# ════════════════════════════════════════════════════════════════════
# setup deploy: the field emitter has the same gate, so the same warning
# ════════════════════════════════════════════════════════════════════

@test "_generate_resolved_compose warns when the field bundle drops ports (#879)" {
  _write_conf "${TEMP_DIR}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" "[network]" "mode = host" "port_1 = 8080:80"
  local _out="${TEMP_DIR}/compose.yaml"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" run _generate_resolved_compose \
    "${TEMP_DIR}" runtime "local/myrepo:runtime-v1" "myrepo-runtime" "${_out}" _binds
  assert_success
  assert_output --partial "${_INERT}"
}

@test "_generate_resolved_compose stays quiet when the field bundle emits ports (#879)" {
  _write_conf "${TEMP_DIR}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" "[network]" "mode = bridge" "network_name = appnet" \
    "port_1 = 8080:80"
  local _out="${TEMP_DIR}/compose.yaml"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" run _generate_resolved_compose \
    "${TEMP_DIR}" runtime "local/myrepo:runtime-v1" "myrepo-runtime" "${_out}" _binds
  assert_success
  refute_output --partial "${_INERT}"
}

# ════════════════════════════════════════════════════════════════════
# i18n: the diagnostic exists in all four locales
# ════════════════════════════════════════════════════════════════════

@test "the ports-inert diagnostic is translated in all four locales (#879)" {
  local _lang _prev="${_LANG}"
  for _lang in en zh-TW zh-CN ja; do
    _LANG="${_lang}"
    run _setup_msg network ports_inert
    assert_success
    [[ -n "${output}" ]]
  done
  _LANG="${_prev}"
}

@test "the ports-inert diagnostic differs per locale (no untranslated arms) (#879)" {
  local _prev="${_LANG}"
  _LANG=en;    local _en;    _en="$(_setup_msg network ports_inert)"
  _LANG=zh-TW; local _zh_tw; _zh_tw="$(_setup_msg network ports_inert)"
  _LANG=zh-CN; local _zh_cn; _zh_cn="$(_setup_msg network ports_inert)"
  _LANG=ja;    local _ja;    _ja="$(_setup_msg network ports_inert)"
  _LANG="${_prev}"
  [[ "${_en}" != "${_zh_tw}" ]]
  [[ "${_en}" != "${_zh_cn}" ]]
  [[ "${_en}" != "${_ja}" ]]
  [[ "${_zh_tw}" != "${_zh_cn}" ]]
  [[ "${_zh_tw}" != "${_ja}" ]]
  [[ "${_zh_cn}" != "${_ja}" ]]
}
