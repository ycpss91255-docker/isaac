#!/usr/bin/env bats
#
# Unit tests for the docker wrapper in the BASE SELF-USE topology:
# base uses the very wrapper it ships, but base is the template SOURCE, so
# its tree has NO `.base/` subtree, NO .setup.conf, NO
# generated .env.generated, and a HAND-AUTHORED compose.yaml (its
# test-harness services). The consumer-shaped sandbox in build_sh_spec.bats
# always has `.base/` + a mock setup.sh; this file models the base-self
# shape (real files shipped under dist/, wrapper reached via a
# script/<x>.sh symlink) instead.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  # Base-self sandbox mirrors base's real shape: real docker lib + wrapper
  # shipped under dist/, reached via a base-own flat symlink script/build.sh
  # -> ../dist/script/docker/wrapper/build.sh. NO `.base/` subtree.
  SANDBOX="${TEMP_DIR}/base"
  mkdir -p "${SANDBOX}/dist/script/docker/lib" \
           "${SANDBOX}/dist/script/docker/wrapper" \
           "${SANDBOX}/dockerfile" \
           "${SANDBOX}/script"
  cp /source/dist/script/docker/lib/* "${SANDBOX}/dist/script/docker/lib/"
  # Symlink the wrapper (not copy) so kcov attributes coverage to the real
  # /source build.sh; resolve relative so the in-sandbox dist/ libs are used.
  ln -s /source/dist/script/docker/wrapper/build.sh \
        "${SANDBOX}/dist/script/docker/wrapper/build.sh"
  ln -s ../dist/script/docker/wrapper/build.sh "${SANDBOX}/script/build.sh"
  touch "${SANDBOX}/dockerfile/Dockerfile.test-tools"

  # Hand-authored compose.yaml with a test-tools service that builds from
  # Dockerfile.test-tools (base's shape). No .setup.conf,
  # no .env.generated -- the states that distinguish base from a consumer.
  cat > "${SANDBOX}/compose.yaml" <<'EOS'
services:
  test-tools:
    build:
      context: .
      dockerfile: dockerfile/Dockerfile.test-tools
    image: test-tools:local
EOS
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

@test "build.sh --help resolves its libs in the base-self topology (no .base/)" {
  run bash "${SANDBOX}/script/build.sh" --help
  assert_success
  assert_output --partial "build.sh"
  refute_output --partial "cannot find _lib.sh"
}

@test "build.sh --target test-tools (base self) dispatches compose build, skips setup.sh" {
  run bash "${SANDBOX}/script/build.sh" --target test-tools --dry-run
  assert_success
  # Reached the compose dispatch for the hand-authored test-tools service.
  assert_output --partial "compose"
  assert_output --partial "test-tools"
  # Must NOT have tried to bootstrap/generate (no setup.conf to seed from,
  # and generating would clobber the hand-authored compose.yaml).
  refute_output --partial "First run"
  refute_output --partial "did not produce"
}
