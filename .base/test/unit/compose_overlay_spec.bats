#!/usr/bin/env bats
#
# Unit tests for _compose_project_with_overlay (lib/compose.sh) and
# _validate_instance_name -- added in #465 to support
# `run.sh --instance NAME` loading config/instances/<name>.{yaml,env}
# as compose overlays.
#
# Behaviour-style: assert what the dry-run docker-compose invocation
# looks like, not how the wrapper assembles its argv internally.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/lib/compose.sh

  TMP_DIR="$(mktemp -d)"
  FILE_PATH="${TMP_DIR}"
  PROJECT_NAME="alice-myrepo"
  DRY_RUN=true
  export FILE_PATH PROJECT_NAME DRY_RUN
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _compose_project_with_overlay (#465)
# ════════════════════════════════════════════════════════════════════

@test "_compose_project_with_overlay: yaml only adds extra -f after compose.yaml (#465)" {
  local _yaml="${TMP_DIR}/foo.yaml"
  : > "${_yaml}"
  run _compose_project_with_overlay "${_yaml}" "" -- up
  assert_success
  # Both -f flags present, compose.yaml before overlay (compose deep-
  # merges later files over earlier ones).
  [[ "${output}" == *"-f ${TMP_DIR}/compose.yaml"*"-f ${_yaml}"* ]]
  assert_output --partial "--env-file ${TMP_DIR}/.env"
  assert_output --partial "up"
  refute_output --partial "--env-file ${TMP_DIR}/foo.env"
}

@test "_compose_project_with_overlay: env only adds extra --env-file after .env (#465)" {
  local _env="${TMP_DIR}/foo.env"
  : > "${_env}"
  run _compose_project_with_overlay "" "${_env}" -- up
  assert_success
  [[ "${output}" == *"--env-file ${TMP_DIR}/.env"*"--env-file ${_env}"* ]]
  assert_output --partial "-f ${TMP_DIR}/compose.yaml"
  refute_output --partial "-f ${TMP_DIR}/foo.yaml"
}

@test "_compose_project_with_overlay: both yaml + env appended (#465)" {
  local _yaml="${TMP_DIR}/foo.yaml" _env="${TMP_DIR}/foo.env"
  : > "${_yaml}"
  : > "${_env}"
  run _compose_project_with_overlay "${_yaml}" "${_env}" -- up
  assert_success
  [[ "${output}" == *"-f ${TMP_DIR}/compose.yaml"*"-f ${_yaml}"* ]]
  [[ "${output}" == *"--env-file ${TMP_DIR}/.env"*"--env-file ${_env}"* ]]
}

@test "_compose_project_with_overlay: missing file is silently skipped (#465)" {
  # Wrapper owns existence check; caller can pass candidate paths
  # blindly.
  run _compose_project_with_overlay "${TMP_DIR}/nope.yaml" "${TMP_DIR}/nope.env" -- up
  assert_success
  refute_output --partial "-f ${TMP_DIR}/nope.yaml"
  refute_output --partial "--env-file ${TMP_DIR}/nope.env"
  # Base -f / --env-file still emitted (degenerates to _compose_project).
  assert_output --partial "-f ${TMP_DIR}/compose.yaml"
  assert_output --partial "--env-file ${TMP_DIR}/.env"
}

# ════════════════════════════════════════════════════════════════════
# _validate_instance_name (#465)
#
# Path-safety guard for the overlay convention:
#   config/instances/${name}.{yaml,env}
# Anything outside `^[a-z0-9][a-z0-9_-]*$` is rejected with exit 1 so
# `--instance ../etc/passwd` and the like cannot escape the dir.
# Aligns with the char class used elsewhere in the project
# (_parse_logging_svc_sections, stage-name rules, etc.).
# ════════════════════════════════════════════════════════════════════

@test "_validate_instance_name: accepts lowercase alphanumeric (#465)" {
  run _validate_instance_name "dev1"
  assert_success
}

@test "_validate_instance_name: accepts hyphen + underscore separators (#465)" {
  run _validate_instance_name "foo-bar"
  assert_success
  run _validate_instance_name "a_b"
  assert_success
}

@test "_validate_instance_name: rejects empty string (#465)" {
  run _validate_instance_name ""
  assert_failure
  assert_output --partial "instance name"
}

@test "_validate_instance_name: rejects uppercase (#465)" {
  run _validate_instance_name "Foo"
  assert_failure
  assert_output --partial "instance name"
}

@test "_validate_instance_name: rejects path traversal characters (#465)" {
  run _validate_instance_name "../etc/passwd"
  assert_failure
  run _validate_instance_name "foo/bar"
  assert_failure
  run _validate_instance_name "."
  assert_failure
}

@test "_validate_instance_name: accepts leading digit (alphanumeric is OK) (#465)" {
  run _validate_instance_name "1dev"
  assert_success
}

@test "_validate_instance_name: rejects leading hyphen / underscore (#465)" {
  run _validate_instance_name "-dev"
  assert_failure
  run _validate_instance_name "_dev"
  assert_failure
}
