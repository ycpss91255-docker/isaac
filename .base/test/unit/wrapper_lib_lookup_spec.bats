#!/usr/bin/env bats
#
# Regression test for issue #282 — wrapper scripts (build/run/exec/stop)
# at .base/script/docker/ must locate _lib.sh through the .base/ subtree
# prefix on fresh clones of post-v0.25.0 downstream repos.
#
# Pre-fix the wrappers hard-coded ${FILE_PATH}/template/script/docker/_lib.sh,
# which broke fresh-clone local development on every downstream repo that
# had migrated its subtree from template/ to .base/ (#263). CI stayed green
# because Makefile.ci paths reference .base/... directly; only the
# user-facing wrapper invocation path was broken.
#
# Strategy:
#   * Scaffold a sandbox repo with the .base/ subtree layout.
#   * Symlink each wrapper (build.sh / run.sh / exec.sh / stop.sh) into the
#     sandbox root, mimicking what init.sh's _create_symlinks produces.
#   * Run each wrapper's --help; the wrapper must succeed in sourcing
#     _lib.sh from .base/script/docker/_lib.sh and print usage. The lookup
#     bug surfaces as the "cannot find _lib.sh" error path.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  SANDBOX="$(mktemp -d)"
  export SANDBOX

  mkdir -p "${SANDBOX}/.base/script/docker/lib"
  cp /source/script/docker/_lib.sh "${SANDBOX}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${SANDBOX}/.base/script/docker/i18n.sh"
  # _lib.sh post-#284 is an umbrella that sources lib/*.sh sub-libs.
  cp /source/script/docker/lib/*.sh "${SANDBOX}/.base/script/docker/lib/"

  for _w in build.sh run.sh exec.sh stop.sh; do
    ln -s "/source/script/docker/${_w}" "${SANDBOX}/${_w}"
  done
}

teardown() {
  rm -rf "${SANDBOX}"
}

# ── .base/ layout: wrapper sources _lib.sh successfully ───────────────

@test "build.sh --help: sources _lib.sh from .base/ (#282)" {
  run "${SANDBOX}/build.sh" --help
  assert_success
  refute_output --partial "cannot find _lib.sh"
}

@test "run.sh --help: sources _lib.sh from .base/ (#282)" {
  run "${SANDBOX}/run.sh" --help
  assert_success
  refute_output --partial "cannot find _lib.sh"
}

@test "exec.sh --help: sources _lib.sh from .base/ (#282)" {
  run "${SANDBOX}/exec.sh" --help
  assert_success
  refute_output --partial "cannot find _lib.sh"
}

@test "stop.sh --help: sources _lib.sh from .base/ (#282)" {
  run "${SANDBOX}/stop.sh" --help
  assert_success
  refute_output --partial "cannot find _lib.sh"
}

# ── Missing _lib.sh: wrapper surfaces the documented error ───────────

@test "build.sh: errors clearly when neither .base/ nor sibling _lib.sh exists (#282)" {
  rm -f "${SANDBOX}/.base/script/docker/_lib.sh"
  run "${SANDBOX}/build.sh" --help
  assert_failure
  assert_output --partial "cannot find _lib.sh"
  assert_output --partial ".base/script/docker/_lib.sh"
}
