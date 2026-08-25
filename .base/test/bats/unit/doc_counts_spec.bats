#!/usr/bin/env bats
#
# Unit tests for script/test/sync-doc-counts.sh (_sync_doc_counts) -- the
# generator that derives the test-count figures in doc/test/*.md from the
# specs themselves (grep -c '^@test'), so the counts stop being hand-edited
# every PR. The check_test_md_drift.sh hook remains the validating safety net.
#
# Second half of the file covers the per-test CATALOG ROWS (`| Test |
# Description |` tables): the heading count was generated while the rows next
# to it were hand-written, so the rows rotted silently under a green gate.
# The rows are generated too now, and these cases pin the contract --
# preservation, deletion, rename, ordering, opt-out, escaping.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  GEN="/source/script/test/sync-doc-counts.sh"
}

@test "_sync_doc_counts: rewrites a stale ### heading to the real @test count (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **99 tests**." "" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "### test/bats/unit/x_spec.bats (3)"
}

@test "_sync_doc_counts: rewrites a stale #### (level-4) heading too (#815)" {
  # Regression: _sync_headings must regenerate deeper ATX headings, not just
  # `###`. Before the fix its regex anchored `^###[[:space:]]`, so a `####`
  # heading never matched -- its (N) drifted silently and check_test_md_drift
  # (same generator) was blind to it.
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "#### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "#### test/bats/unit/x_spec.bats (3)"
}

@test "_sync_doc_counts: rewrites the per-type total to the sum of the headings (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **99 tests**." "" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**3 tests**"
  refute_output --partial "**99 tests**"
}

@test "_sync_doc_counts: is idempotent on an already-synced tree (#727)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **2 tests**." "" "### test/bats/unit/x_spec.bats (2)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    a=$(cat "${root}/doc/test/unit.md")
    _sync_doc_counts "${root}"
    b=$(cat "${root}/doc/test/unit.md")
    [[ "${a}" == "${b}" ]] && echo IDEMPOTENT
  '
  assert_success
  assert_output --partial "IDEMPOTENT"
}

@test "_sync_doc_counts: rewrites the system per-type total from test/bats/system/ (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/system" "${root}/doc/test"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${root}/test/bats/system/x_spec.bats"
    printf "%s\n" "System specs under \`test/bats/system/\`: **99 tests**." > "${root}/doc/test/system.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/system.md"
  '
  assert_success
  assert_output --partial "**2 tests**"
  refute_output --partial "**99 tests**"
}

@test "_sync_doc_counts: tolerates an empty acceptance dir (count 0, no error) (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/acceptance" "${root}/doc/test"
    printf "%s\n" "Acceptance specs under \`test/bats/acceptance/\`: **7 tests**." > "${root}/doc/test/acceptance.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/acceptance.md"
  '
  assert_success
  assert_output --partial "**0 tests**"
  refute_output --partial "**7 tests**"
}

@test "_sync_test_md_index: fills the system + acceptance rows, retires behavioural (#782)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/test/bats/integration" \
             "${root}/test/bats/system" "${root}/test/bats/acceptance" \
             "${root}/dist/test/bats/smoke/shared" "${root}/doc/test"
    printf "@test \"u\" {\n:\n}\n" > "${root}/test/bats/unit/u_spec.bats"
    printf "@test \"i\" {\n:\n}\n" > "${root}/test/bats/integration/i_spec.bats"
    printf "@test \"s1\" {\n:\n}\n@test \"s2\" {\n:\n}\n@test \"s3\" {\n:\n}\n" > "${root}/test/bats/system/s_spec.bats"
    {
      echo "| Doc | Scope | Count |"
      echo "| [unit.md](unit.md) | unit | 0 |"
      echo "| [integration.md](integration.md) | integration | 0 |"
      echo "| [system.md](system.md) | system | 0 |"
      echo "| [acceptance.md](acceptance.md) | acceptance | 0 |"
      echo "| [smoke.md](smoke.md) | smoke | 0 |"
    } > "${root}/doc/test/TEST.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/TEST.md"
  '
  assert_success
  assert_output --partial "[system.md](system.md) | system | 3 "
  assert_output --partial "[acceptance.md](acceptance.md) | acceptance | 0 "
}

@test "_sync_test_md_index: regenerates the blockquote prose System/smoke pair (#843)" {
  # Regression: only the table rows and per-level headers were regenerated,
  # so TEST.md's hand-written "System (N) and smoke (N)" prose drifted and
  # ended up contradicting the table sitting right below it.
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/system" "${root}/dist/test/bats/smoke" \
             "${root}/doc/test"
    printf "@test \"s1\" {\n:\n}\n@test \"s2\" {\n:\n}\n" > "${root}/test/bats/system/s_spec.bats"
    printf "@test \"k\" {\n:\n}\n" > "${root}/dist/test/bats/smoke/k.bats"
    printf "%s\n" "> System (99) and smoke (98) tests are tracked here too." \
      > "${root}/doc/test/TEST.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/TEST.md"
  '
  assert_success
  assert_output --partial "System (2) and smoke (1) tests"
  refute_output --partial "System (99)"
}


# ── Per-test catalog rows ────────────────────────────────────────────────────
#
# Fixtures build the spec files with printf, never a heredoc: a literal
# `@test ...` at column 0 anywhere in this file -- heredoc body included --
# is picked up by bats own preprocessor as a test definition of THIS file.

@test "_sync_catalog_rows: generates a row for every @test the table is missing (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      "@test \"gamma\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (3)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | first one |" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `alpha` | first one |'
  assert_line '| `beta` | - |'
  assert_line '| `gamma` | - |'
}

@test "_sync_catalog_rows: a hand-written description survives regeneration (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (2)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`beta\` | carefully worded prose |" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `beta` | carefully worded prose |'
  assert_line '| `alpha` | - |'
}

@test "_sync_catalog_rows: the row of a deleted test goes away (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | still here |" \
      "| \`gone\` | described a test that no longer exists |" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `alpha` | still here |'
  refute_output --partial 'no longer exists'
}

@test "_sync_catalog_rows: a renamed test is a delete plus an add, prose does not follow (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha renamed\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | prose written against the old name |" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `alpha renamed` | - |'
  refute_output --partial 'the old name'
}

@test "_sync_catalog_rows: rows follow spec file order, not the old table order (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"zulu\" {" ":" "}" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (2)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | second in the spec |" \
      "| \`zulu\` | first in the spec |" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    grep "^| .zulu\|^| .alpha" "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line --index 0 --partial 'zulu'
  assert_line --index 1 --partial 'alpha'
}

@test "_sync_catalog_rows: a section without a per-test table is left alone (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (2)" "" \
      "| Category | Tests |" "|----------|-------|" \
      "| Everything, summarised by hand | 2 |" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| Everything, summarised by hand | 2 |'
  refute_output --partial 'alpha'
}

@test "_sync_catalog_rows: a heading whose spec path does not resolve is left alone (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/gone_spec.bats (4)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`historic\` | for a spec no longer in the tree |" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `historic` | for a spec no longer in the tree |'
}

@test "_sync_catalog_rows: a pipe in a test name is escaped so the table stays well formed (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"forwards -h|--help to usage\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" "" \
      "| Test | Description |" "|------|-------------|" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    a=$(cat "${root}/doc/test/unit.md")
    _sync_doc_counts "${root}"
    b=$(cat "${root}/doc/test/unit.md")
    [[ "${a}" == "${b}" ]] || echo NOT-IDEMPOTENT
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `forwards -h\|--help to usage` | - |'
  refute_output --partial 'NOT-IDEMPOTENT'
}

@test "_sync_catalog_rows: backslash escapes resolve to the name bats reports (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"escaping \\\\ then \\\" and \\\$X\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" "" \
      "| Test | Description |" "|------|-------------|" \
      > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `escaping \ then " and $X` | - |'
}

@test "_sync_catalog_rows: is idempotent on an already-generated catalog (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (2)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | one |" "| \`beta\` | two |" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    a=$(cat "${root}/doc/test/unit.md")
    _sync_doc_counts "${root}"
    b=$(cat "${root}/doc/test/unit.md")
    [[ "${a}" == "${b}" ]] && echo IDEMPOTENT
  '
  assert_success
  assert_output --partial "IDEMPOTENT"
}

# ── Missing sections ─────────────────────────────────────────────────────────

@test "_sync_doc_sections: a spec file with no section at all gets one (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "@test \"zulu\" {" ":" "}" "@test \"yankee\" {" ":" "}" \
      > "${root}/test/bats/unit/y_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **1 tests**." "" \
      "### test/bats/unit/x_spec.bats (1)" "" \
      "| Test | Description |" "|------|-------------|" \
      "| \`alpha\` | described already |" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `alpha` | described already |'
  assert_output --partial "### test/bats/unit/y_spec.bats (2)"
  assert_line '| `zulu` | - |'
  assert_line '| `yankee` | - |'
}

@test "_sync_doc_sections: an existing section is never duplicated (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _sync_doc_counts "${root}"
    _sync_doc_counts "${root}"
    grep -c "^### test/bats/unit/x_spec.bats" "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output "1"
}

@test "_sync_doc_sections: a shipped smoke spec lands in smoke.md (#859)" {
  run bash -c '
    source "'"${GEN}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/dist/test/bats/smoke/shared" "${root}/doc/test"
    printf "%s\n" "@test \"kettle\" {" ":" "}" \
      > "${root}/dist/test/bats/smoke/shared/k.bats"
    printf "%s\n" "Smoke specs: **0 tests**." > "${root}/doc/test/smoke.md"
    _sync_doc_counts "${root}"
    cat "${root}/doc/test/smoke.md"
  '
  assert_success
  assert_output --partial "### dist/test/bats/smoke/shared/k.bats (1)"
  assert_line '| `kettle` | - |'
}
