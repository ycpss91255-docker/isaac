#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ── [deploy] dri_groups (non-NVIDIA iGPU /dev/dri access) ───────────────
# SETUP_DETECT_DRI_GROUPS is a documented, supported operator override of
# the /dev/dri stat host probe (README "Host-detection overrides" +
# setup.sh --help). The two tests below assert the operator-override
# contract: the env var forces the GID list verbatim and skips the stat.
@test "SETUP_DETECT_DRI_GROUPS operator override forces the GID list verbatim (#496)" {
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 992'
    source /source/dist/script/docker/wrapper/setup.sh
    _detect_dri_groups
  "
  assert_success
  # The override echoes its value verbatim and skips the /dev/dri stat,
  # so the output is exactly the operator-supplied list (no host probe).
  assert_output "44 992"
}

@test "SETUP_DETECT_DRI_GROUPS override echoes repeated GIDs verbatim (no stat dedup) (#496)" {
  run bash -c "
    export SETUP_DETECT_DRI_GROUPS='44 44 992'
    source /source/dist/script/docker/wrapper/setup.sh
    _detect_dri_groups
  "
  assert_success
  # The override is a verbatim passthrough; sort -u dedup only applies on
  # the real /dev/dri stat path, which the override deliberately bypasses.
  assert_output --partial "44"
  assert_output --partial "992"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_gpu / _resolve_gui
# ════════════════════════════════════════════════════════════════════
@test "_resolve_gpu auto + detected=true => enabled" {
  local _out
  _resolve_gpu "auto" "true" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gpu auto + detected=false => disabled" {
  local _out
  _resolve_gpu "auto" "false" _out
  assert_equal "${_out}" "false"
}

@test "_resolve_gpu force => enabled regardless of detection" {
  local _out
  _resolve_gpu "force" "false" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gpu off => disabled regardless of detection" {
  local _out
  _resolve_gpu "off" "true" _out
  assert_equal "${_out}" "false"
}

@test "_resolve_gui auto + detected=true => enabled" {
  local _out
  _resolve_gui "auto" "true" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gui force => enabled regardless" {
  local _out
  _resolve_gui "force" "false" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gui off => disabled regardless" {
  local _out
  _resolve_gui "off" "true" _out
  assert_equal "${_out}" "false"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_runtime / _detect_jetson (Jetson NVIDIA runtime)
#
# SETUP_DETECT_JETSON is a documented, supported operator override of the
# /etc/nv_tegra_release host probe (README "Host-detection overrides" +
# setup.sh --help). These tests assert the operator-override contract:
# the env var forces the detection result and skips the host probe.
# ════════════════════════════════════════════════════════════════════
@test "SETUP_DETECT_JETSON=true operator override forces Jetson detection" {
  # The probe file does not exist in the test env, so a true result here
  # proves the override short-circuits the /etc/nv_tegra_release probe.
  SETUP_DETECT_JETSON=true _detect_jetson
}

@test "SETUP_DETECT_JETSON=false operator override forces non-Jetson detection" {
  ! SETUP_DETECT_JETSON=false _detect_jetson
}

@test "_resolve_runtime auto on Jetson => nvidia" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "auto" _out
  assert_equal "${_out}" "nvidia"
}

@test "_resolve_runtime auto off Jetson => empty" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_runtime "auto" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime nvidia => always nvidia" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_runtime "nvidia" _out
  assert_equal "${_out}" "nvidia"
}

@test "_resolve_runtime off => empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "off" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime empty => empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime unknown mode falls through to empty (safe default)" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "garbage" _out
  assert_equal "${_out}" ""
}

# ════════════════════════════════════════════════════════════════════
# _resolve_build_network (Jetson build-net auto-detect,)
# ════════════════════════════════════════════════════════════════════
@test "_resolve_build_network auto on Jetson => host" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "auto" _out
  assert_equal "${_out}" "host"
}

@test "_resolve_build_network auto off Jetson => empty" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_build_network "auto" _out
  assert_equal "${_out}" ""
}

@test "_resolve_build_network host => always host (explicit override wins)" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_build_network "host" _out
  assert_equal "${_out}" "host"
}

@test "_resolve_build_network bridge / none / default pass through" {
  local _out
  _resolve_build_network "bridge" _out
  assert_equal "${_out}" "bridge"
  _resolve_build_network "none" _out
  assert_equal "${_out}" "none"
  _resolve_build_network "default" _out
  assert_equal "${_out}" "default"
}

@test "_resolve_build_network off / empty => empty (explicitly suppressed)" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "off" _out
  assert_equal "${_out}" ""
  SETUP_DETECT_JETSON=true _resolve_build_network "" _out
  assert_equal "${_out}" ""
}

@test "_resolve_build_network unknown mode falls through to empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "garbage" _out
  assert_equal "${_out}" ""
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash
# ════════════════════════════════════════════════════════════════════
@test "_compute_conf_hash returns a sha256-shaped hex string" {
  local _h
  _compute_conf_hash "${TEMP_DIR}" _h
  [[ "${_h}" =~ ^[0-9a-f]{64}$ ]]
}

@test "_compute_conf_hash differs when per-repo setup.conf changes" {
  local _h1 _h2
  _compute_conf_hash "${TEMP_DIR}" _h1
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = off
EOF
  _compute_conf_hash "${TEMP_DIR}" _h2
  [[ "${_h1}" != "${_h2}" ]]
}
