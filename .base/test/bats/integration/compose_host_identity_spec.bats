#!/usr/bin/env bats
#
# Integration: how the repo-root compose.yaml resolves the host identity.
#
# HOST_UID / HOST_GID decide the uid:gid the self-test containers run
# things as while the checkout is bind-mounted at /source -- i.e. the
# ownership of every file the suite writes into the working tree. What
# decides them is compose's own interpolation, not the file's text, so
# these assertions drive `docker compose config` and compare what compose
# actually resolves.
#
# `docker compose config` is pure client-side interpolation: it needs the
# compose CLI (baked into the test-tools image this suite runs in) but no
# daemon and no docker socket, so this spec belongs to the plain `ci`
# service rather than the socket-mounted `ci-system` one.
#
# TEST_TOOLS_IMAGE is pinned to a throwaway value in every invocation
# below: it is a separate required variable of the same file, and leaving
# it to chance would make these assertions report on ITS resolution.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  ROOT=/source
  PINNED_IMAGE="test-tools:host-identity-spec"
  # The compose plugin is a package of the tooling image
  # (docker-cli-compose in dockerfile/Dockerfile.test-tools), and a run
  # against a PUBLISHED tag older than that package predates it. Nothing
  # about the resolution can be observed without it, so say so instead of
  # asserting on a `docker --help` dump. The file-shape half of this
  # invariant is pinned unconditionally in base_docker_namespace_spec.
  docker compose version >/dev/null 2>&1 \
    || skip "this test-tools image has no docker compose plugin"
}

# ════════════════════════════════════════════════════════════════════
# An absent identity says so, and says what to run instead
# ════════════════════════════════════════════════════════════════════

@test "compose.yaml: an unset HOST_UID fails naming the entry point to use (#895)" {
  # 1000 used to be substituted here. On any host whose developer is not
  # uid 1000 that left the files the suite wrote owned by a stranger --
  # silently, because writing them succeeded. Refusing is the only outcome
  # that cannot be mistaken for a working run.
  run env -u HOST_UID TEST_TOOLS_IMAGE="${PINNED_IMAGE}" \
    docker compose -f "${ROOT}/compose.yaml" config
  assert_failure
  assert_output --partial "HOST_UID"
  assert_output --partial "just test"
}

@test "compose.yaml: an unset HOST_GID fails the same way (#895)" {
  run env -u HOST_GID TEST_TOOLS_IMAGE="${PINNED_IMAGE}" \
    docker compose -f "${ROOT}/compose.yaml" config
  assert_failure
  assert_output --partial "HOST_GID"
  assert_output --partial "just test"
}

# ════════════════════════════════════════════════════════════════════
# What the caller supplies is what the container gets
# ════════════════════════════════════════════════════════════════════

@test "compose.yaml: every checkout-mounting service takes the supplied ids verbatim (#895)" {
  # A default surviving on ONE of the three services is the same defect
  # narrowed: the suite writes the checkout from all of them.
  local _service
  for _service in ci ci-system coverage; do
    run env HOST_UID=4242 HOST_GID=4243 TEST_TOOLS_IMAGE="${PINNED_IMAGE}" \
      docker compose -f "${ROOT}/compose.yaml" config "${_service}"
    assert_success
    assert_output --partial "HOST_UID: \"4242\""
    assert_output --partial "HOST_GID: \"4243\""
    refute_output --partial "1000"
  done
}
