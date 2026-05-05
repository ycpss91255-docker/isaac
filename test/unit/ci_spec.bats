#!/usr/bin/env bats
#
# Unit tests for script/ci/ci.sh helper functions.
# Only helpers that can be exercised without a full CI run are covered here.
#
# NOTE: these tests confine PATH to MOCK_DIR *after* sourcing ci.sh so that
# (a) `command -v bats` inside _install_deps always misses (bats lives in
#     /usr/bin in the CI container, which MOCK_DIR does not include), and
# (b) apt-get / git resolve to our mocks instead of the real binaries.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
}

teardown() {
  cleanup_mock_dir
}

# ════════════════════════════════════════════════════════════════════
# _install_deps
# ════════════════════════════════════════════════════════════════════

@test "_install_deps: skips apt-get and git when bats is already installed" {
  mock_cmd "bats" 'exit 0'
  # These mocks must NOT be invoked; fail loudly if they are.
  mock_cmd "apt-get" 'echo "apt-get should not be called"; exit 1'
  mock_cmd "git" 'echo "git should not be called"; exit 1'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_success
  refute_output --partial "should not be called"
}

@test "_install_deps: dies with clear error when apt-get update fails" {
  mock_cmd "apt-get" '
    if [[ "$1" == "update" ]]; then exit 42; fi
    exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "apt-get update failed"
}

@test "_install_deps: dies with clear error when apt-get install fails" {
  mock_cmd "apt-get" '
    case "$1" in
      update)  exit 0 ;;
      install) exit 100 ;;
      *)       exit 0 ;;
    esac'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "apt-get install failed"
}

@test "_install_deps: dies with clear error when git clone bats-mock fails" {
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" '
    if [[ "$1" == "clone" ]]; then exit 128; fi
    exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_failure
  assert_output --partial "ERROR"
  assert_output --partial "git clone bats-mock failed"
}

@test "_install_deps: happy path succeeds when bats absent and all deps install cleanly" {
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _install_deps
  '
  assert_success
}

@test "_install_deps: rewrites sources.list when APT_MIRROR_DEBIAN differs from default" {
  local _log="${BATS_TEST_TMPDIR}/sed.log"
  # _install_deps gates the sed branch on `[[ -f /etc/apt/sources.list ]]`,
  # which is true on the previous kcov/kcov debian runner but FALSE on the
  # alpine test-tools image (no /etc/apt). Materialise the file once if
  # missing so this regression test is image-agnostic — the goal here is
  # to verify the sed substitution logic, not the file-existence guard
  # (the unset/default tests below already cover the no-op branch).
  if [[ ! -f /etc/apt/sources.list ]]; then
    mkdir -p /etc/apt
    : > /etc/apt/sources.list
  fi
  mock_cmd "sed" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    export APT_MIRROR_DEBIAN="mirror.twds.com.tw"
    _install_deps
  '
  assert_success
  assert [ -f "${_log}" ]
  run cat "${_log}"
  assert_output --partial "s|deb.debian.org|mirror.twds.com.tw|g"
}

@test "_install_deps: skips sources.list rewrite when APT_MIRROR_DEBIAN equals default" {
  mock_cmd "sed" 'echo "sed-should-not-be-called"; exit 1'
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    export APT_MIRROR_DEBIAN="deb.debian.org"
    _install_deps
  '
  assert_success
  refute_output --partial "sed-should-not-be-called"
}

@test "_install_deps: skips sources.list rewrite when APT_MIRROR_DEBIAN unset" {
  mock_cmd "sed" 'echo "sed-should-not-be-called"; exit 1'
  mock_cmd "apt-get" 'exit 0'
  mock_cmd "git" 'exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    unset APT_MIRROR_DEBIAN
    _install_deps
  '
  assert_success
  refute_output --partial "sed-should-not-be-called"
}

# ════════════════════════════════════════════════════════════════════
# _run_shellcheck
#
# Regression guard: if someone adds a new shell script under script/ or
# config/ but forgets to wire it into _run_shellcheck, the list drifts
# out of sync with reality. These tests pin the expected invocations so
# that drift surfaces as a test failure.
# ════════════════════════════════════════════════════════════════════

@test "_run_shellcheck: invokes shellcheck against every expected script" {
  # Log each invocation to a capture file so we can inspect the set.
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  # xargs needs a mock too — the real one would forward to the real
  # shellcheck binary (which lives in MOCK_DIR), so this is just a
  # belt-and-braces ensure PATH is honored.
  run bash -c '
    source /source/script/ci/ci.sh
    _run_shellcheck
  '
  assert_success

  assert [ -f "${_log}" ]
  run cat "${_log}"
  assert_output --partial "script/ci/ci.sh"
  assert_output --partial "init.sh"
  assert_output --partial "upgrade.sh"
  assert_output --partial "config/pip/setup.sh"
  assert_output --partial "config/shell/terminator/setup.sh"
  assert_output --partial "config/shell/tmux/setup.sh"
}

@test "_run_shellcheck: picks up every .sh file in script/docker/" {
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/ci/ci.sh
    _run_shellcheck
  '
  assert_success

  # Every .sh under script/docker/ (non-recursive) must appear.
  for _f in /source/script/docker/*.sh; do
    run grep -F "${_f}" "${_log}"
    assert_success
  done
}

@test "_run_shellcheck: exits non-zero when shellcheck fails on any script" {
  # Simulate a lint violation on init.sh specifically.
  mock_cmd "shellcheck" '
    for _arg in "$@"; do
      if [[ "${_arg}" == *"/init.sh" ]]; then
        printf "SC0001: fake violation\n" >&2
        exit 1
      fi
    done
    exit 0'
  # Enable -e to mirror real CI invocation (ci.sh sets it when run
  # directly; when sourced, the caller owns strict mode).
  run bash -c '
    set -e
    source /source/script/ci/ci.sh
    _run_shellcheck
  '
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _run_via_compose / main routing
#
# Regression guards for #168: default `ci.sh` (no flag) must hit the
# alpine `ci` service so the apt-install path is bypassed; `--coverage`
# must hit the kcov/kcov-based `coverage` service. Mock `docker` so
# the test captures the chosen service name + COVERAGE env without
# actually running compose.
# ════════════════════════════════════════════════════════════════════

@test "_run_via_compose: routes default mode to the ci service with COVERAGE=0" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose ci 0
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose"
  assert_output --partial "COVERAGE=0"
  assert_output --partial " ci"
  refute_output --partial "COVERAGE=1"
}

@test "_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose coverage 1
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose"
  assert_output --partial "COVERAGE=1"
  assert_output --partial " coverage"
}

@test "main: dispatches no-flag default to the ci service" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    main
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "COVERAGE=0"
}

@test "_run_tests: passes --jobs N when parallel is on PATH" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "parallel" 'exit 0'
  mock_cmd "nproc" 'echo 8'
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_tests
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "--jobs 8"
}

@test "_run_tests: omits --jobs when parallel is absent (graceful fallback)" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  # Intentionally NOT mocking `parallel` so command -v misses.
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_tests
  '
  assert_success
  assert_output --partial "serial"
  assert_output --partial "parallel not in PATH"

  run cat "${_log}"
  assert_success
  refute_output --partial "--jobs"
}

@test "main: dispatches --coverage to the coverage service" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/ci/ci.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
}
