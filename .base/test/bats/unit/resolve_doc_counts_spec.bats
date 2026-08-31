#!/usr/bin/env bats
#
# Unit tests for script/test/resolve-doc-counts.sh (_resolve_doc_counts) --
# the one command that resolves a doc/test/*.md merge conflict: collapse the
# markers, regenerate the derived figures authoritatively, verify.
#
# The recipe it replaces was retyped by hand six times in a single review
# batch (an awk one-liner plus two scripts) and had to be pasted verbatim into
# every dispatched agent prompt. It was also hazardous: a mechanical collapse
# adopts whichever side it keeps, INCLUDING for content the generator does not
# derive, so a stale figure or a lost sentence rides through silently.
#
# The cases below therefore split into two halves: the toil half (markers go,
# figures come back right) and the safety half (anything the collapse cannot
# justify by regeneration is refused loudly, never adopted quietly).

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  RESOLVE="/source/script/test/resolve-doc-counts.sh"
}

# ── Root guards ──────────────────────────────────────────────────────────────

@test "_resolve_doc_counts: FAILS on a RELATIVE root, naming it (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"a\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    cd "${root}"
    _resolve_doc_counts .
  '
  assert_failure
  assert_output --partial "relative"
}

@test "_resolve_doc_counts: FAILS on a nonexistent root, naming it (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    _resolve_doc_counts "${BATS_TEST_TMPDIR}/nope"
  '
  assert_failure
  assert_output --partial "nope"
}

# ── The toil ─────────────────────────────────────────────────────────────────

@test "_resolve_doc_counts: collapses a counter-only conflict and regenerates (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      "@test \"gamma\" {" ":" "}" > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **1 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **2 tests**." \
      ">>>>>>> origin/main" \
      "" \
      "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**3 tests**"
  refute_output --partial "<<<<<<<"
  refute_output --partial ">>>>>>>"
  refute_output --partial "======="
}

@test "_resolve_doc_counts: drops the diff3 base section too (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **9 tests**." \
      "||||||| merged common ancestors" \
      "Unit specs under \`test/bats/unit/\`: **7 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **8 tests**." \
      ">>>>>>> origin/main" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_output --partial "**1 tests**"
  refute_output --partial "|||||||"
  refute_output --partial "merged common ancestors"
}

@test "_resolve_doc_counts: rescues the catalog prose from BOTH sides (#857)" {
  # Each side described a test the other side's table does not carry. A
  # mechanical collapse keeps one description and drops the other; there is
  # nothing to regenerate it from, so it would be lost silently.
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" "@test \"beta\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "### test/bats/unit/x_spec.bats (2)" \
      "" \
      "| Test | Description |" \
      "|------|-------------|" \
      "<<<<<<< HEAD" \
      "| \`alpha\` | ours describes alpha |" \
      "=======" \
      "| \`beta\` | theirs describes beta |" \
      ">>>>>>> origin/main" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
    cat "${root}/doc/test/unit.md"
  '
  assert_success
  assert_line '| `alpha` | ours describes alpha |'
  assert_line '| `beta` | theirs describes beta |'
  refute_output --partial "<<<<<<<"
  refute_output --partial "======="
}

@test "_resolve_doc_counts: an unconflicted tree is verified, not rewritten (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" "Unit specs under \`test/bats/unit/\`: **1 tests**." "" \
      "### test/bats/unit/x_spec.bats (1)" > "${root}/doc/test/unit.md"
    before=$(cat "${root}/doc/test/unit.md")
    _resolve_doc_counts "${root}"
    after=$(cat "${root}/doc/test/unit.md")
    [[ "${before}" == "${after}" ]] && echo UNCHANGED
  '
  assert_success
  assert_output --partial "no conflicted"
  assert_output --partial "UNCHANGED"
}

# ── The trap ─────────────────────────────────────────────────────────────────

@test "_resolve_doc_counts: FAILS when the two sides describe the same test differently (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "### test/bats/unit/x_spec.bats (1)" \
      "" \
      "| Test | Description |" \
      "|------|-------------|" \
      "<<<<<<< HEAD" \
      "| \`alpha\` | ours wording |" \
      "=======" \
      "| \`alpha\` | theirs wording |" \
      ">>>>>>> origin/main" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial "alpha"
  assert_output --partial "ours wording"
  assert_output --partial "theirs wording"
}

@test "_resolve_doc_counts: FAILS when the sides differ in prose the generator does not derive (#857)" {
  # The exact trap the manual recipe carried: the collapse adopts whichever
  # side it kept for a hand-maintained sentence sitting next to the generated
  # figures, and nothing downstream notices.
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/test/bats/unit" "${root}/doc/test"
    printf "%s\n" "@test \"alpha\" {" ":" "}" \
      > "${root}/test/bats/unit/x_spec.bats"
    printf "%s\n" \
      "### test/bats/unit/x_spec.bats (1)" \
      "" \
      "<<<<<<< HEAD" \
      "Covers the old behaviour, hand written." \
      "=======" \
      "Covers the new behaviour, hand written." \
      ">>>>>>> origin/main" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial "hand written"
}

@test "_resolve_doc_counts: FAILS when the drift gate is unhappy afterwards (#857)" {
  # A scan root the gate refuses (no spec files: every count would compare 0
  # against 0) must surface as a failure, not as a resolved-looking tree.
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test"
    printf "%s\n" \
      "<<<<<<< HEAD" \
      "Unit specs under \`test/bats/unit/\`: **1 tests**." \
      "=======" \
      "Unit specs under \`test/bats/unit/\`: **2 tests**." \
      ">>>>>>> origin/main" > "${root}/doc/test/unit.md"
    _resolve_doc_counts "${root}"
  '
  assert_failure
  assert_output --partial "no spec files"
}

@test "_resolve_assert_no_markers: FAILS naming the file and line of a survivor (#857)" {
  run bash -c '
    source "'"${RESOLVE}"'"
    root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/doc/test"
    printf "%s\n" "fine" "<<<<<<< HEAD" "also fine" \
      > "${root}/doc/test/unit.md"
    _resolve_assert_no_markers "${root}"
  '
  assert_failure
  assert_output --partial "unit.md:2"
}
