#!/usr/bin/env bats
#
# Unit tests for script/ci/lint_mixed_test_layout.sh (#495 / ADR-00000004).
# WARNING-only lint: flags a test/<category>/ directory that mixes test
# runner families (e.g. .bats + test_*.py) at one level, suggesting the
# test/<category>/<tool>/ subdir split. Non-blocking: always exits 0.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  LINT="/source/script/ci/lint_mixed_test_layout.sh"
  FAKE_ROOT="$(mktemp -d)"
  mkdir -p "${FAKE_ROOT}/test"
}

teardown() {
  rm -rf "${FAKE_ROOT}"
}

@test "warns when a category mixes bats and python at one level" {
  mkdir -p "${FAKE_ROOT}/test/integration"
  touch "${FAKE_ROOT}/test/integration/a_spec.bats"
  touch "${FAKE_ROOT}/test/integration/test_b.py"

  run bash "${LINT}" "${FAKE_ROOT}"
  assert_success
  assert_output --partial "test/integration/ mixes test runners"
  assert_output --partial "bats"
  assert_output --partial "python"
}

@test "silent for a single-tool (bats-only) category" {
  mkdir -p "${FAKE_ROOT}/test/unit"
  touch "${FAKE_ROOT}/test/unit/a_spec.bats" "${FAKE_ROOT}/test/unit/b_spec.bats"

  run bash "${LINT}" "${FAKE_ROOT}"
  assert_success
  refute_output --partial "mixes test runners"
}

@test "silent for a single-tool (python-only) category" {
  mkdir -p "${FAKE_ROOT}/test/e2e"
  touch "${FAKE_ROOT}/test/e2e/test_a.py" "${FAKE_ROOT}/test/e2e/b_test.py"

  run bash "${LINT}" "${FAKE_ROOT}"
  assert_success
  refute_output --partial "mixes test runners"
}

@test "warns only for the mixed category among several" {
  mkdir -p "${FAKE_ROOT}/test/unit" "${FAKE_ROOT}/test/integration" "${FAKE_ROOT}/test/e2e"
  touch "${FAKE_ROOT}/test/unit/a_spec.bats"
  touch "${FAKE_ROOT}/test/integration/c_spec.bats" "${FAKE_ROOT}/test/integration/test_d.py"
  touch "${FAKE_ROOT}/test/e2e/test_e.py"

  run bash "${LINT}" "${FAKE_ROOT}"
  assert_success
  assert_output --partial "test/integration/"
  refute_output --partial "test/unit/ mixes"
  refute_output --partial "test/e2e/ mixes"
}

@test "non-test files do not trigger a warning" {
  mkdir -p "${FAKE_ROOT}/test/unit"
  touch "${FAKE_ROOT}/test/unit/a_spec.bats" \
        "${FAKE_ROOT}/test/unit/test_helper.bash" \
        "${FAKE_ROOT}/test/unit/README.md"

  run bash "${LINT}" "${FAKE_ROOT}"
  assert_success
  refute_output --partial "mixes test runners"
}

@test "is non-blocking: exits 0 even when it warns" {
  mkdir -p "${FAKE_ROOT}/test/x"
  touch "${FAKE_ROOT}/test/x/a_spec.bats" "${FAKE_ROOT}/test/x/test_b.py"

  run bash "${LINT}" "${FAKE_ROOT}"
  [ "${status}" -eq 0 ]
}

@test "exits 2 when given a non-directory root" {
  run bash "${LINT}" "${FAKE_ROOT}/does-not-exist"
  [ "${status}" -eq 2 ]
}

@test "_runner_family classifies bats / python / other" {
  source "${LINT}"
  [ "$(_runner_family foo_spec.bats)" = "bats" ]
  [ "$(_runner_family foo.bats)" = "bats" ]
  [ "$(_runner_family test_foo.py)" = "python" ]
  [ "$(_runner_family foo_test.py)" = "python" ]
  [ -z "$(_runner_family README.md)" ]
  [ -z "$(_runner_family helper.bash)" ]
}
