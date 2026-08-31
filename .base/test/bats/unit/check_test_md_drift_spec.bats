#!/usr/bin/env bats
#
# Unit tests for script/test/check_test_md_drift.sh (_check_test_md_drift) --
# the read-only validating twin of sync-doc-counts.sh. It re-derives the
# doc/test/*.md count figures from the specs (the same `grep -c '^@test'`
# source) and exits non-zero when the committed docs have drifted, so a PR
# that adds a @test without running `just test sync-docs` fails the gate
# instead of silently shipping stale counts.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  CHECK="/source/script/test/check_test_md_drift.sh"
}

@test "_check_test_md_drift: exits 0 on an in-sync tree (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_success
}

@test "_check_test_md_drift: exits non-zero and names the drifted doc on a stale count (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "unit.md"
}

@test "_check_test_md_drift: tolerates an empty acceptance level dir (count 0) (#782)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/acceptance" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **1 tests**." "" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    printf "%s\n" "Acceptance specs under \`test/bats/acceptance/\`: **0 tests**." > "${root}/doc/test/acceptance.md"
    _check_test_md_drift "${root}"
  '
  assert_success
}

# ── Scan-root robustness ────────────────────────────────────────────────────
#
# The comparison copies doc/test into a temp dir and symlinks the spec trees
# in from the scan root, so a relative root resolves against the TEMP dir on
# that hop: every spec glob misses and every count comes back 0 -- a
# confident wrong answer, not an error. The sibling sync-doc-counts.sh has no
# such hop and takes a relative root fine, which is what makes passing `.` to
# both the natural thing to do.

@test "_check_test_md_drift: a RELATIVE root gives the same verdict as the absolute one (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    cd "${root}" || exit 2
    _check_test_md_drift .
  '
  assert_success
}

@test "_check_test_md_drift: a RELATIVE root still detects real drift (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    cd "${root}" || exit 2
    _check_test_md_drift .
  '
  assert_failure
  assert_output --partial "unit.md"
}

@test "_check_test_md_drift: FAILS on a nonexistent scan root, naming it (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    _check_test_md_drift "${BATS_TEST_TMPDIR}/nope"
  '
  assert_failure
  assert_output --partial "nope"
}

@test "_check_test_md_drift: FAILS on a scan root with no doc/test (no vacuous pass) (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit"
    printf "@test \"a\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "doc/test"
}

@test "_check_test_md_drift: FAILS on a spec-free scan root (no vacuous pass) (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **0 tests**." > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "${BATS_TEST_TMPDIR}/r"
}

@test "_check_test_md_drift: counts a shipped smoke spec as spec files (#848)" {
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/dist/test/bats/smoke" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n" > "${root}/dist/test/bats/smoke/s.bats"
    printf "%s\n" "Shared smoke specs that ship under \`dist/test/bats/smoke/\`: **1 tests**." \
      "" "### dist/test/bats/smoke/s.bats (1)" "" \
      "| Test | Description |" "|------|-------------|" "| \`a\` | - |" \
      > "${root}/doc/test/smoke.md"
    _check_test_md_drift "${root}"
  '
  assert_success
}

@test "_check_test_md_drift: FAILS when a spec has more tests than catalog rows (#859)" {
  # The rot this closes: the heading count was regenerated (so the gate said
  # in sync) while the per-test table next to it stayed short. Rows are
  # generated now, so a short table IS drift.
  run bash -c '
    source "'"${CHECK}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" \
      "### test/bats/unit/x_spec.bats (2)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | only one of the two |" > "${root}/doc/test/unit.md"
    _check_test_md_drift "${root}"
  '
  assert_failure
  assert_output --partial "beta"
}
