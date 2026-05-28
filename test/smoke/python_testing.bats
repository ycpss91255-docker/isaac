#!/usr/bin/env bats
#
# Python testing toolkit smoke tests for the devel-test stage.
# Asserts that pytest + pyyaml + pytest-cov are installed into Isaac Sim's
# bundled Python (/isaac-sim/python.sh), so consumer repos can run in-
# container Python unit tests. Stage-scoped to devel-test only — the
# runtime devel image stays lean. Closes #59.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

@test "pytest installed in devel-test stage" {
  assert_cmd_installed /isaac-sim/python.sh
  run /isaac-sim/python.sh -m pytest --version
  assert_success
}

@test "pyyaml installed in devel-test stage" {
  run /isaac-sim/python.sh -c "import yaml; print(yaml.__version__)"
  assert_success
}

@test "pytest-cov installed in devel-test stage" {
  run /isaac-sim/python.sh -m pytest --help
  assert_success
  assert_output --partial "--cov"
}
