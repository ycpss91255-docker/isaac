#!/usr/bin/env bats
# bats file_tags=core
#
# Guard for `test/assert_pytest_baseline.sh --group <group>` (isaac#434): the
# per-scope hosted job runs one group's tests against that group's own floor.
# A stub `docker` on PATH records the container command, so the spec observes
# what the script would run (marker selection, coverage) without docker.
#
# Baked into /smoke_test/ next to assert_pytest_baseline.sh by the devel-test
# stage.

bats_require_minimum_version 1.5.0

setup() {
  FAKE="$(mktemp -d)"
  mkdir -p "${FAKE}/test" "${FAKE}/bin"
  cp "${BATS_TEST_DIRNAME}/assert_pytest_baseline.sh" "${FAKE}/test/"
  chmod +x "${FAKE}/test/assert_pytest_baseline.sh"
  cat > "${FAKE}/test/pytest-baseline.txt" <<'BASE'
HOSTED_UNIT_BASELINE = 10
HOSTED_UNIT_BASELINE_CORE = 6
HOSTED_UNIT_BASELINE_GUI = 0
HOSTED_UNIT_BASELINE_STREAM = 3
HOSTED_UNIT_BASELINE_HEADLESS = 0
HOSTED_UNIT_BASELINE_DOCS = 1
BASE
  # Stub docker: logs the container script (the last argument, `sh -c <body>`)
  # and, for the counting run, answers the way the real loop would.
  cat > "${FAKE}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >> "${DOCKER_LOG}"
body="${@: -1}"
if [[ "${body}" == *"--collect-only"* ]]; then
  printf 'total 10\ncore 6\ngui 0\nstream %s\nheadless 0\ndocs 1\n' "${STUB_STREAM_COUNT:-3}"
fi
exit 0
STUB
  chmod +x "${FAKE}/bin/docker"
  export DOCKER_LOG="${FAKE}/docker.log"
  : > "${DOCKER_LOG}"
  export PATH="${FAKE}/bin:${PATH}"
}

teardown() {
  rm -rf "${FAKE}"
}

@test "assert_pytest_baseline --group: an unknown group exits 2 before any docker call" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --group nightly
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"nightly"* ]]
  [ ! -s "${DOCKER_LOG}" ]
}

@test "assert_pytest_baseline --group: a missing value exits 2" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --group
  [ "${status}" -eq 2 ]
}

@test "assert_pytest_baseline --group: cannot be combined with --gpu" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --gpu --group core
  [ "${status}" -eq 2 ]
  [ ! -s "${DOCKER_LOG}" ]
}

@test "assert_pytest_baseline --group stream: selects the group with -m and skips coverage" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --group stream
  [ "${status}" -eq 0 ]
  grep -q -- '-m stream' "${DOCKER_LOG}"
  ! grep -q -- '--cov' "${DOCKER_LOG}"
  [[ "${output}" == *"group stream: collected 3 >= floor 3"* ]]
}

@test "assert_pytest_baseline --group core: keeps the framework coverage gate" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --group core
  grep -q -- '--cov-fail-under=80' "${DOCKER_LOG}"
}

@test "assert_pytest_baseline --group stream: a group below its own floor fails" {
  STUB_STREAM_COUNT=2 run "${FAKE}/test/assert_pytest_baseline.sh" --group stream
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ratchet violation"* ]]
}

@test "assert_pytest_baseline --group stream: only that group is counted" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --group stream
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"group core"* ]]
  [[ "${output}" != *"group docs"* ]]
}
