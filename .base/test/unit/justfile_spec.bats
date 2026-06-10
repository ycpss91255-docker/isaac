#!/usr/bin/env bats
#
# Static checks for the user-facing justfile at
# .base/script/docker/justfile (symlinked from downstream repo root as
# `justfile`). ADR-00000005: `just` replaces the GNU make wrapper --
# recipes forward 1:1 to ./script/<name>.sh with full `{{args}}`
# passthrough (no MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim).
#
# These are content assertions (grep), not execution: `just` is not
# installed in the test-tools image, so the justfile is verified
# statically here; downstream installs `just` to run it.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  JUSTFILE=/source/script/docker/justfile
}

@test "justfile exists" {
  [ -f "${JUSTFILE}" ]
}

@test "justfile declares args-passthrough recipes for every wrapper verb (#545)" {
  local _v
  for _v in build run exec stop prune setup; do
    run grep -E "^${_v} \*args:" "${JUSTFILE}"
    assert_success
  done
  run grep -E '^setup-tui \*args:' "${JUSTFILE}"
  assert_success
  run grep -E '^upgrade \*args:' "${JUSTFILE}"
  assert_success
}

@test "justfile recipes forward to ./script/<wrapper>.sh with {{args}} (#545)" {
  run grep -F './script/build.sh {{args}}' "${JUSTFILE}"
  assert_success
  run grep -F './script/run.sh {{args}}' "${JUSTFILE}"
  assert_success
  run grep -F './script/exec.sh {{args}}' "${JUSTFILE}"
  assert_success
  run grep -F './script/setup_tui.sh {{args}}' "${JUSTFILE}"
  assert_success
  run grep -F './.base/upgrade.sh {{args}}' "${JUSTFILE}"
  assert_success
}

@test "justfile default recipe lists recipes (replaces make help) (#545)" {
  # bare `just` should be discoverable -- the default recipe runs `just --list`.
  run grep -E '^default:' "${JUSTFILE}"
  assert_success
  run grep -F 'just --list' "${JUSTFILE}"
  assert_success
}
