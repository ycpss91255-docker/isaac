#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  CONFIG="/source/config/shell/terminator/config"
}

# ════════════════════════════════════════════════════════════════════
# Sections
# ════════════════════════════════════════════════════════════════════

@test "has [global_config] section" {
  run grep -q "^\[global_config\]" "${CONFIG}"
  assert_success
}

@test "has [keybindings] section" {
  run grep -q "^\[keybindings\]" "${CONFIG}"
  assert_success
}

@test "has [profiles] section" {
  run grep -q "^\[profiles\]" "${CONFIG}"
  assert_success
}

@test "has [layouts] section" {
  run grep -q "^\[layouts\]" "${CONFIG}"
  assert_success
}

@test "has [plugins] section" {
  run grep -q "^\[plugins\]" "${CONFIG}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Profiles
# ════════════════════════════════════════════════════════════════════

@test "profiles has [[default]]" {
  run grep -q "\[\[default\]\]" "${CONFIG}"
  assert_success
}

@test "default profile disables system font" {
  run grep -q "use_system_font = False" "${CONFIG}"
  assert_success
}

@test "default profile has infinite scrollback" {
  run grep -q "scrollback_infinite = True" "${CONFIG}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Layouts
# ════════════════════════════════════════════════════════════════════

@test "layouts has Window type" {
  run grep -q "type = Window" "${CONFIG}"
  assert_success
}

@test "layouts has Terminal type" {
  run grep -q "type = Terminal" "${CONFIG}"
  assert_success
}
