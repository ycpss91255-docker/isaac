#!/usr/bin/env bats
#
# Integration: how the repo-root compose.yaml resolves the tooling image.
#
# One variable, TEST_TOOLS_IMAGE, names both the image the build-only
# `test-tools` service WRITES and the image the `ci` / `coverage` /
# `ci-system` services RUN. What decides that is compose's own
# interpolation, not the file's text, so these assertions drive
# `docker compose config` and compare what compose actually resolves.
#
# `docker compose config` is pure client-side interpolation: it needs the
# compose CLI (baked into the test-tools image this suite runs in) but no
# daemon and no docker socket, so this spec belongs to the plain `ci`
# service rather than the socket-mounted `ci-system` one.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ROOT=/source
}

# _resolution <service>
#
# Prints `<exit status>|<stdout>` for `docker compose config --images
# <service>` run the way a bare invocation sees it: TEST_TOOLS_IMAGE
# removed from the environment. stderr is dropped so the value describes
# the OUTCOME (did compose resolve an image, and which) rather than the
# wording of any diagnostic -- the wording is pinned by its own test, and
# compose names an arbitrary one of four offending services in it.
_resolution() {
  local _service="${1:?_resolution requires <service>}"
  local _out _rc
  _out="$(env -u TEST_TOOLS_IMAGE docker compose \
    -f "${ROOT}/compose.yaml" config --images "${_service}" 2>/dev/null)" \
    && _rc=0 || _rc=$?
  printf '%s|%s\n' "${_rc}" "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# The tag the build writes is the tag the run reads
# ════════════════════════════════════════════════════════════════════

@test "compose.yaml: with TEST_TOOLS_IMAGE unset the tag the test-tools build writes is the tag the ci run reads (#896)" {
  # Two different fallbacks on one variable meant a bare
  # `docker compose build test-tools` tagged one image while a bare
  # `docker compose run ci` pulled another: the suite ran against the
  # published image and the edit to dockerfile/Dockerfile.test-tools had
  # no effect, with nothing warning. Whatever compose does with no value,
  # the build side and the run side must reach the SAME outcome.
  local _build _run
  _build="$(_resolution test-tools)"
  _run="$(_resolution ci)"
  assert_equal "${_build}" "${_run}"
}

@test "compose.yaml: with TEST_TOOLS_IMAGE unset every consumer service reaches the same outcome as the build (#896)" {
  # `ci` is not the only consumer -- `coverage` and `ci-system` read the
  # same variable, and a fallback that diverges on any one of them is the
  # same silent defect.
  local _build _service
  _build="$(_resolution test-tools)"
  for _service in ci coverage ci-system; do
    assert_equal "$(_resolution "${_service}")" "${_build}"
  done
}

# ════════════════════════════════════════════════════════════════════
# An unset value says so, and says what to run instead
# ════════════════════════════════════════════════════════════════════

@test "compose.yaml: an unset TEST_TOOLS_IMAGE fails naming the just recipe to run (#896)" {
  # Reaching an unset value means the invocation left the single entry
  # point, and that is the thing worth reporting. compose's own
  # "neither an image nor a build context specified" is true and useless
  # -- it names no way to get one. Refusing while naming the recipe is
  # what makes silently building or pulling something impossible.
  #
  # Which SERVICE compose names is not a contract: it interpolates the
  # whole file and reports the first required variable it reaches, and the
  # order varies between runs (observed alternating between the
  # `test-tools` and `smoke` services on one tree). Every service's message
  # names a just recipe and says not to drive compose directly, so those
  # are what this asserts; pinning one recipe pinned map iteration order
  # instead, and went red whenever the other service won the race.
  run env -u TEST_TOOLS_IMAGE docker compose \
    -f "${ROOT}/compose.yaml" config --images
  assert_failure
  assert_output --partial "required variable TEST_TOOLS_IMAGE is missing a value"
  assert_output --partial "just test"
  assert_output --partial "instead of driving docker compose directly"
}
