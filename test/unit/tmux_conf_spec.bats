#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  CONF="/source/config/shell/tmux/tmux.conf"
}

# ════════════════════════════════════════════════════════════════════
# Core settings
# ════════════════════════════════════════════════════════════════════

@test "defines prefix key" {
  run grep -q "set-option -g prefix" "${CONF}"
  assert_success
}

@test "sets default shell to bash" {
  run grep -q 'default-shell.*bash' "${CONF}"
  assert_success
}

@test "sets default terminal" {
  run grep -q "set -g default-terminal" "${CONF}"
  assert_success
}

@test "enables mouse support" {
  run grep -q "set -g mouse on" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Vi mode
# ════════════════════════════════════════════════════════════════════

@test "enables vi status-keys" {
  run grep -q "status-keys vi" "${CONF}"
  assert_success
}

@test "enables vi mode-keys" {
  run grep -q "mode-keys vi" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Key bindings
# ════════════════════════════════════════════════════════════════════

@test "defines split-window bindings" {
  run grep -q "split-window" "${CONF}"
  assert_success
}

@test "defines reload config binding" {
  run grep -q "source-file" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Status bar
# ════════════════════════════════════════════════════════════════════

@test "enables status bar" {
  run grep -q "set-option -g status on" "${CONF}"
  assert_success
}

@test "sets status bar position" {
  run grep -q "status-position" "${CONF}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# TPM (plugin manager)
# ════════════════════════════════════════════════════════════════════

@test "declares tpm plugin" {
  run grep -q "@plugin 'tmux-plugins/tpm'" "${CONF}"
  assert_success
}

@test "initializes tpm at end of file" {
  run grep -q "tpm/tpm" "${CONF}"
  assert_success
}
