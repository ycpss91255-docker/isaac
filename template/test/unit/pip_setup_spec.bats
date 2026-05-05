#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  TEMP_DIR="$(mktemp -d)"

  # Create a fake requirements.txt alongside the script for testing
  FAKE_SCRIPT_DIR="${TEMP_DIR}/pip"
  mkdir -p "${FAKE_SCRIPT_DIR}"
  cp /source/config/pip/setup.sh "${FAKE_SCRIPT_DIR}/setup.sh"
  echo "# empty requirements" > "${FAKE_SCRIPT_DIR}/requirements.txt"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# pip/setup.sh
# ════════════════════════════════════════════════════════════════════

@test "pip setup.sh runs pip install with requirements.txt" {
  mock_cmd "pip" '
echo "pip called with: $*"
exit 0'
  run bash "${FAKE_SCRIPT_DIR}/setup.sh"
  assert_success
  assert_output --partial "pip called with: install -r"
}

@test "pip setup.sh sets PIP_BREAK_SYSTEM_PACKAGES=1" {
  mock_cmd "pip" 'echo "PIP_BREAK=${PIP_BREAK_SYSTEM_PACKAGES}"; exit 0'
  run bash "${FAKE_SCRIPT_DIR}/setup.sh"
  assert_success
  assert_output --partial "PIP_BREAK=1"
}

@test "pip setup.sh fails when pip is not available" {
  mock_cmd "pip" 'exit 127'
  run -127 bash "${FAKE_SCRIPT_DIR}/setup.sh"
}
