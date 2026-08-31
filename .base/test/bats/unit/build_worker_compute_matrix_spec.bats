#!/usr/bin/env bats
#
# build_worker_compute_matrix_spec.bats -- unit tests for
# script/ci/build_worker/compute_matrix.sh, the platform -> build matrix
# resolver extracted out of build-worker.yaml's inline `compute-matrix`
# step.
#
# The matrix computation is the classic "a matrix condition that produces
# no jobs" semantic break the shared worker can suffer: actionlint cannot
# catch it, and it only surfaced when a downstream ran the worker in
# production. Pushing it down to a pure-shell script (System-level logic
# -> Unit level, ADR-00000018) makes every branch -- valid platforms,
# whitespace tolerance, the unsupported-platform reject, and the
# empty/no-jobs reject -- runnable locally under `just test`.
#
# The script reads the comma-separated platform list from the PLATFORMS
# env var (mirroring build-worker.yaml's `env: PLATFORMS: ${{ inputs...}}`
# pre-expansion convention, so the logic stays portable to a non-GitHub CI
# host) and prints the matrix JSON to stdout; the GITHUB_OUTPUT plumbing
# stays thin in the YAML.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/build_worker/compute_matrix.sh"
  [[ -f "${SCRIPT}" ]] || skip "compute_matrix.sh not at expected path"
}

@test "compute_matrix: linux/amd64 -> single include entry on ubuntu-latest / x86_64" {
  PLATFORMS="linux/amd64" run bash "${SCRIPT}"
  assert_success
  assert_output '{"include":[{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"}]}'
}

@test "compute_matrix: linux/arm64 -> single include entry on ubuntu-24.04-arm / aarch64" {
  PLATFORMS="linux/arm64" run bash "${SCRIPT}"
  assert_success
  assert_output '{"include":[{"platform":"linux/arm64","runner":"ubuntu-24.04-arm","hardware":"aarch64"}]}'
}

@test "compute_matrix: both platforms -> two ordered include entries" {
  PLATFORMS="linux/amd64,linux/arm64" run bash "${SCRIPT}"
  assert_success
  assert_output '{"include":[{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"},{"platform":"linux/arm64","runner":"ubuntu-24.04-arm","hardware":"aarch64"}]}'
}

@test "compute_matrix: tolerates whitespace around comma-separated platforms" {
  PLATFORMS=" linux/amd64 , linux/arm64 " run bash "${SCRIPT}"
  assert_success
  assert_output '{"include":[{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"},{"platform":"linux/arm64","runner":"ubuntu-24.04-arm","hardware":"aarch64"}]}'
}

@test "compute_matrix: skips empty segments (trailing comma) without emitting an empty entry" {
  PLATFORMS="linux/amd64,," run bash "${SCRIPT}"
  assert_success
  assert_output '{"include":[{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"}]}'
}

@test "compute_matrix: unsupported platform fails with a naming, plain-language error" {
  PLATFORMS="linux/riscv64" run bash "${SCRIPT}"
  assert_failure
  assert_output --partial "linux/riscv64"
  assert_output --partial "linux/amd64, linux/arm64"
}

@test "compute_matrix: empty platform list fails (no matrix -> no jobs guard)" {
  PLATFORMS="" run bash "${SCRIPT}"
  assert_failure
  assert_output --partial "No valid platforms"
}

@test "compute_matrix: all-empty segments fail (whitespace-only -> no jobs guard)" {
  PLATFORMS=" , , " run bash "${SCRIPT}"
  assert_failure
  assert_output --partial "No valid platforms"
}
