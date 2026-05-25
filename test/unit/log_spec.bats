#!/usr/bin/env bats
#
# log_spec.bats - Execution tests for _log_err / _log_warn / _log_info
# helpers in script/docker/_lib.sh (#278). Covers tagged prefix shape,
# stream routing (stdout vs stderr), NO_COLOR / FORCE_COLOR / TTY
# detection.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB="/source/script/docker/_lib.sh"
}

# ── prefix + level keyword shape ────────────────────────────────────────────

@test "_log_err writes '[<tag>] ERROR: <msg>' to stderr (no TTY -> no color)" {
  run --separate-stderr bash -c "source ${LIB}; _log_err build 'something broke'"
  assert_success
  assert_equal "${output}" ""
  assert_equal "${stderr}" "[build] ERROR: something broke"
}

@test "_log_warn writes '[<tag>] WARNING: <msg>' to stderr (no TTY -> no color)" {
  run --separate-stderr bash -c "source ${LIB}; _log_warn run 'deprecated flag'"
  assert_success
  assert_equal "${output}" ""
  assert_equal "${stderr}" "[run] WARNING: deprecated flag"
}

@test "_log_info writes '[<tag>] INFO: <msg>' to stdout (no TTY -> no color)" {
  run --separate-stderr bash -c "source ${LIB}; _log_info setup 'phase done'"
  assert_success
  assert_equal "${output}" "[setup] INFO: phase done"
  assert_equal "${stderr}" ""
}

# ── multi-word message joins with spaces ────────────────────────────────────

@test "_log_err joins multi-token message with single spaces" {
  run --separate-stderr bash -c "source ${LIB}; _log_err build word1 word2 word3"
  assert_success
  assert_equal "${stderr}" "[build] ERROR: word1 word2 word3"
}

# ── missing tag is rejected ─────────────────────────────────────────────────

@test "_log_err with no tag exits non-zero (param ':?' guard)" {
  run -127 bash -c "source ${LIB}; _log_err"
}

@test "_log_warn with no tag exits non-zero (param ':?' guard)" {
  run -127 bash -c "source ${LIB}; _log_warn"
}

@test "_log_info with no tag exits non-zero (param ':?' guard)" {
  run -127 bash -c "source ${LIB}; _log_info"
}

# ── FORCE_COLOR forces ANSI even on non-TTY ─────────────────────────────────

@test "_log_err with FORCE_COLOR=1 emits red bold ANSI on non-TTY stderr" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_err build msg"
  assert_success
  assert_equal "${stderr}" $'\033[1;31m[build] ERROR:\033[0m msg'
}

@test "_log_warn with FORCE_COLOR=1 emits yellow ANSI on non-TTY stderr" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_warn run msg"
  assert_success
  assert_equal "${stderr}" $'\033[33m[run] WARNING:\033[0m msg'
}

@test "_log_info with FORCE_COLOR=1 still emits plain (INFO uses default colour, #338-followup)" {
  # INFO is intentionally unstyled — ERROR / WARNING use bright ANSI to
  # draw the eye, INFO matches the visual weight of the unstyled summary
  # lines that setup.sh prints alongside it (e.g. `[setup] USER=...`).
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_info setup msg"
  assert_success
  assert_equal "${output}" "[setup] INFO: msg"
}

# ── NO_COLOR wins over FORCE_COLOR + TTY ────────────────────────────────────

@test "_log_err with NO_COLOR=1 + FORCE_COLOR=1 omits ANSI (NO_COLOR wins)" {
  run --separate-stderr bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LIB}; NO_COLOR=1 FORCE_COLOR=1 _log_err build msg"
  assert_success
  assert_equal "${stderr}" "[build] ERROR: msg"
}

@test "_log_warn with NO_COLOR=1 omits ANSI" {
  run --separate-stderr bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LIB}; NO_COLOR=1 FORCE_COLOR=1 _log_warn run msg"
  assert_success
  assert_equal "${stderr}" "[run] WARNING: msg"
}

@test "_log_info with NO_COLOR=1 omits ANSI" {
  run --separate-stderr bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LIB}; NO_COLOR=1 FORCE_COLOR=1 _log_info setup msg"
  assert_success
  assert_equal "${output}" "[setup] INFO: msg"
}

# ── _log_color_enabled fd argument semantics ───────────────────────────────

@test "_log_color_enabled returns non-zero on non-TTY fd 1 without overrides" {
  run bash -c "source ${LIB}; _log_color_enabled 1"
  assert_failure
}

@test "_log_color_enabled returns 0 with FORCE_COLOR=1 on non-TTY" {
  run bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_color_enabled 1"
  assert_success
}

@test "_log_color_enabled returns non-zero with NO_COLOR=1 + FORCE_COLOR=1" {
  run bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LIB}; NO_COLOR=1 FORCE_COLOR=1 _log_color_enabled 1"
  assert_failure
}

@test "_log_color_enabled with no fd argument exits non-zero (param guard)" {
  run -127 bash -c "source ${LIB}; _log_color_enabled"
}

# ── _log_plain helper (#309) ────────────────────────────────────────────────

@test "_log_plain writes '[<tag>] <msg>' to stdout with no style (no ANSI even with FORCE_COLOR)" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_plain build '' 'plain text'"
  assert_success
  assert_equal "${output}" "[build] plain text"
  assert_equal "${stderr}" ""
}

@test "_log_plain with bold style + FORCE_COLOR=1 wraps message in ANSI bold" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_plain build bold 'header'"
  assert_success
  assert_equal "${output}" $'[build] \033[1mheader\033[0m'
  assert_equal "${stderr}" ""
}

@test "_log_plain with dim style + FORCE_COLOR=1 wraps message in ANSI dim" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_plain build dim '────────'"
  assert_success
  assert_equal "${output}" $'[build] \033[2m────────\033[0m'
}

@test "_log_plain with bold style + NO_COLOR=1 omits ANSI even with FORCE_COLOR=1" {
  run --separate-stderr bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LIB}; NO_COLOR=1 FORCE_COLOR=1 _log_plain build bold 'header'"
  assert_success
  assert_equal "${output}" "[build] header"
}

@test "_log_plain on non-TTY without FORCE_COLOR omits ANSI" {
  run --separate-stderr bash -c "source ${LIB}; _log_plain build bold 'header'"
  assert_success
  assert_equal "${output}" "[build] header"
}

@test "_log_plain joins multi-token message with single spaces" {
  run --separate-stderr bash -c "source ${LIB}; _log_plain build '' word1 word2 word3"
  assert_success
  assert_equal "${output}" "[build] word1 word2 word3"
}

@test "_log_plain with no tag exits non-zero (param ':?' guard)" {
  run -127 bash -c "source ${LIB}; _log_plain"
}

@test "_log_plain with unknown style + FORCE_COLOR=1 falls back to no ANSI (case match miss)" {
  run --separate-stderr bash -c "FORCE_COLOR=1 source ${LIB}; FORCE_COLOR=1 _log_plain build invalid 'msg'"
  assert_success
  assert_equal "${output}" "[build] msg"
}
