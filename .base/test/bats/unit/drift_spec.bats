#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift
# ════════════════════════════════════════════════════════════════════
@test "_check_setup_drift no-op when .env missing" {
  run _check_setup_drift "${TEMP_DIR}"
  assert_success
}

@test "_check_setup_drift silent when nothing changed" {
  # Prime .env by running a full setup cycle (write_env + _compute_conf_hash)
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  # stub detect_gui/detect_gpu to match stored false
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_success
  refute_output --partial "WARNING"
}

@test "_check_setup_drift returns non-zero when conf hash changes" {
  local _h_old=""
  _compute_conf_hash "${TEMP_DIR}" _h_old
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h_old}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  # Drop in a new per-repo setup.conf → hash differs
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run _check_setup_drift "${TEMP_DIR}"
  # Non-zero exit lets build.sh/run.sh trigger auto-regen (v0.9.5+).
  assert_failure
  assert_output --partial "drift detected"
  assert_output --partial "setup.conf modified"
}

@test "_check_setup_drift returns non-zero when GPU detection changes" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  # Store with GPU=false
  write_env "${TEMP_DIR}/.env.generated" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "private" "true" "all" "gpu" \
    "false" "${_h}" ""
  # Now detection says true
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="true"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_failure
  assert_output --partial "GPU detection changed"
}
