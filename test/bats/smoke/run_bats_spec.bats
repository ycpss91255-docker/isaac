#!/usr/bin/env bats
# bats file_tags=core
#
# Guard for script/ci/run_bats.sh (isaac#434): the devel-test stage runs the
# bats specs through it, and CI passes the groups a PR did not touch in
# BATS_SKIP_GROUPS. Specs of a skipped group must not run; specs of every
# other group, and specs with no group at all (the base-owned ones baked into
# the same directory), must keep running -- the shared layer is always
# checked.
#
# Behavioral: builds a throwaway spec tree and counts what bats selects.
#
# Baked into /smoke_test/ next to run_bats.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  if [ -x "${BATS_TEST_DIRNAME}/run_bats.sh" ]; then
    RUN_BATS="${BATS_TEST_DIRNAME}/run_bats.sh"
  else
    RUN_BATS="${BATS_TEST_DIRNAME}/../../../script/ci/run_bats.sh"
  fi
  [ -x "${RUN_BATS}" ]
  TREE="$(mktemp -d)"
  printf '# bats file_tags=core\n@test "c1" {\n  true\n}\n@test "c2" {\n  true\n}\n' > "${TREE}/core.bats"
  printf '# bats file_tags=stream\n@test "s1" {\n  true\n}\n' > "${TREE}/stream.bats"
  printf '# bats file_tags=gui\n@test "g1" {\n  true\n}\n' > "${TREE}/gui.bats"
  printf '@test "u1" {\n  true\n}\n' > "${TREE}/untagged.bats"
}

teardown() {
  rm -rf "${TREE}"
}

@test "run_bats: no skip list selects every spec" {
  run env -u BATS_SKIP_GROUPS "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "5" ]
}

@test "run_bats: an empty skip list selects every spec" {
  run env BATS_SKIP_GROUPS= "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "5" ]
}

@test "run_bats: a skipped group's specs are not selected" {
  run --separate-stderr env BATS_SKIP_GROUPS=stream "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "4" ]
}

@test "run_bats: several skipped groups are all dropped" {
  run --separate-stderr env BATS_SKIP_GROUPS=stream,gui "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "3" ]
}

@test "run_bats: untagged (base-owned) specs always run" {
  run --separate-stderr env BATS_SKIP_GROUPS=core,stream,gui "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "1" ]
}

@test "run_bats: whitespace around group names is ignored" {
  run --separate-stderr env "BATS_SKIP_GROUPS= stream , gui " "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "3" ]
}

@test "run_bats: an unknown group fails instead of silently skipping nothing" {
  run --separate-stderr env BATS_SKIP_GROUPS=nightly "${RUN_BATS}" --count "${TREE}"
  [ "${status}" -eq 2 ]
  [[ "${stderr}" == *"nightly"* ]]
}

@test "run_bats: it really runs the selected specs (exit status follows them)" {
  printf '# bats file_tags=gui\n@test "g-fail" {\n  false\n}\n' > "${TREE}/gui.bats"
  run env BATS_SKIP_GROUPS= "${RUN_BATS}" "${TREE}"
  [ "${status}" -ne 0 ]
  run env BATS_SKIP_GROUPS=gui "${RUN_BATS}" "${TREE}"
  [ "${status}" -eq 0 ]
}
