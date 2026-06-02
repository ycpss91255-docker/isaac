#!/usr/bin/env bats
#
# Regression guard for Makefile.local docker-logs FD redirect (#75).
#
# Under pid=host the container PID 1 namespace is the host's, so the
# container's literal PID-1 procfs path resolves to host systemd's
# stdout/stderr. Writes fail with EPERM and `docker logs <isaac>`
# stays empty.
#
# The fix in Makefile.local resolves CONTAINER_PID1 via `docker
# inspect --format '{{.State.Pid}}'` and redirects to
# /proc/${CONTAINER_PID1}/fd/{1,2} -- that FD pair IS the docker
# logs pipe, so Kit output streams natively.
#
# Makefile.local is baked into /smoke_test/ alongside this spec by
# the devel-test stage in Dockerfile (matching the pattern used for
# the other smoke specs).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  MAKEFILE_LOCAL="${BATS_TEST_DIRNAME}/Makefile.local"
}

@test "Makefile.local: no /proc/1/fd/ redirect under pid=host (#75)" {
  assert_file_exists "${MAKEFILE_LOCAL}"
  run grep -F "/proc/1/fd/" "${MAKEFILE_LOCAL}"
  [ "$status" -ne 0 ]
}

@test "Makefile.local: redirect resolves container PID 1 via State.Pid (#75)" {
  assert_file_exists "${MAKEFILE_LOCAL}"
  grep -q "CONTAINER_PID1" "${MAKEFILE_LOCAL}"
  grep -q "State\.Pid" "${MAKEFILE_LOCAL}"
}

@test "Makefile.local: run-stream launches web-viewer in stream-only auto-launch (#79/#107)" {
  assert_file_exists "${MAKEFILE_LOCAL}"
  # Must be -e FLAG=VALUE args to the viewer docker run, not a bare string
  # in a comment or elsewhere (#107).
  grep -qE '[-]e[[:space:]]+VIEWER_UI_MODE=stream-only' "${MAKEFILE_LOCAL}"
  grep -qE '[-]e[[:space:]]+VIEWER_AUTO_LAUNCH=true' "${MAKEFILE_LOCAL}"
  # Negative guard: the opposite values must not be wired.
  ! grep -qE '[-]e[[:space:]]+VIEWER_UI_MODE=usd-viewer' "${MAKEFILE_LOCAL}"
  ! grep -qE '[-]e[[:space:]]+VIEWER_AUTO_LAUNCH=false' "${MAKEFILE_LOCAL}"
}

@test "Makefile.local: host.yaml-absent message is functional, not Kit jargon (#108)" {
  assert_file_exists "${MAKEFILE_LOCAL}"
  grep -q "remote browser access will not work" "${MAKEFILE_LOCAL}"
  # The Kit-internal term is no longer surfaced to users.
  ! grep -q "skip publicEndpointAddress" "${MAKEFILE_LOCAL}"
}

@test "Makefile.local: run-stream output includes a firewall hint (#108)" {
  assert_file_exists "${MAKEFILE_LOCAL}"
  grep -qiE 'firewall' "${MAKEFILE_LOCAL}"
  grep -qE '8011' "${MAKEFILE_LOCAL}"
  grep -qE '49100' "${MAKEFILE_LOCAL}"
}

@test "Makefile.local: HOST_YAML resolves relative to the makefile dir (#109)" {
  assert_file_exists "${MAKEFILE_LOCAL}"
  grep -q "MAKEFILE_LIST" "${MAKEFILE_LOCAL}"
  grep -qE 'HOST_YAML[[:space:]]*:?=[[:space:]]*\$\(SELF_DIR\)' "${MAKEFILE_LOCAL}"
}
