#!/usr/bin/env bats
#
# doc_counts_merge_spec.bats -- integration coverage for
# script/test/resolve-doc-counts.sh against a REAL git merge conflict.
#
# The unit spec drives the resolver's functions over hand-written marker
# fixtures. This one reproduces what actually happens: two branches each added
# tests, both bumped the same generated totals in doc/test/unit.md, and the
# merge conflicts on them. That conflict was resolved by hand six times in one
# review batch. One command has to leave a merged, regenerated, staged,
# gate-clean tree behind -- and, when the two sides disagree about something
# regeneration cannot settle, refuse without staging anything.

bats_require_minimum_version 1.5.0

RESOLVE="/source/script/test/resolve-doc-counts.sh"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${REPO}/test/bats/unit" "${REPO}/doc/test"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email tester@example.invalid
  git -C "${REPO}" config user.name tester
  _seed
}

# _spec <name> <test-name>... -- (re)write a spec file carrying the named tests.
_spec() {
  local _name="${1}"; shift
  local _t
  : > "${REPO}/test/bats/unit/${_name}.bats"
  for _t in "$@"; do
    printf '@test "%s" {\n:\n}\n' "${_t}" \
      >> "${REPO}/test/bats/unit/${_name}.bats"
  done
}

# _doc <total> <a-count> <a-row>... -- rewrite unit.md. The b_spec section is
# constant so the two branches touch well-separated regions and only the
# total line collides, which is the conflict shape the review batch produced.
_doc() {
  local _total="${1}" _acount="${2}"; shift 2
  {
    printf 'Unit specs under `test/bats/unit/`: **%s tests**.\n' "${_total}"
    printf '\nSpacer prose so the total and the first section are separate hunks.\n'
    printf '\nMore spacer prose, same reason.\n'
    printf '\n### test/bats/unit/a_spec.bats (%s)\n\n' "${_acount}"
    printf '| Test | Description |\n|------|-------------|\n'
    printf '%s\n' "$@"
    printf '\n### test/bats/unit/b_spec.bats (1)\n\n'
    printf '| Test | Description |\n|------|-------------|\n'
    printf '| `bravo` | the other original |\n'
  } > "${REPO}/doc/test/unit.md"
}

# _seed -- the common ancestor both branches start from.
_seed() {
  _spec a_spec alpha
  _spec b_spec bravo
  _doc 2 1 '| `alpha` | the original |'
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm base
}

# _commit_all <message> -- stage everything and commit.
_commit_all() {
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -qm "${1}"
}

@test "resolve-doc-counts: resolves a real two-branch counter conflict end to end (#857)" {
  git -C "${REPO}" checkout -q -b feature
  _spec a_spec alpha beta charlie
  _doc 4 3 '| `alpha` | the original |' '| `beta` | added on the branch |' \
    '| `charlie` | - |'
  _commit_all feature

  git -C "${REPO}" checkout -q main
  _spec b_spec bravo delta
  _doc 3 1 '| `alpha` | the original |'
  # main also documents its own new test, in the b_spec section at the end.
  printf '| `delta` | added on main |\n' >> "${REPO}/doc/test/unit.md"
  _commit_all main

  run git -C "${REPO}" merge --no-edit feature
  assert_failure
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_output --partial 'doc/test/unit.md'

  run bash "${RESOLVE}" "${REPO}"
  assert_success

  run cat "${REPO}/doc/test/unit.md"
  assert_success
  refute_output --partial '<<<<<<<'
  refute_output --partial '>>>>>>>'
  # Both branches' tests are catalogued and both branches' prose survives:
  # a mechanical collapse to one side would have dropped one of them.
  assert_line '| `alpha` | the original |'
  assert_line '| `beta` | added on the branch |'
  assert_line '| `charlie` | - |'
  assert_line '| `bravo` | the other original |'
  assert_line '| `delta` | added on main |'
  # The totals are regenerated from the MERGED spec tree, not inherited from
  # whichever side the collapse kept (3 + 2 = 5, a number neither side wrote).
  assert_output --partial '**5 tests**'
  assert_output --partial '### test/bats/unit/a_spec.bats (3)'
  assert_output --partial '### test/bats/unit/b_spec.bats (2)'

  # Resolved means resolved: nothing left unmerged, so the merge can be
  # committed without a second manual `git add`.
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_success
  assert_output ''

  run bash /source/script/test/check_test_md_drift.sh "${REPO}"
  assert_success
}

@test "resolve-doc-counts: REFUSES a merge whose sides describe the same test differently, staging nothing (#857)" {
  git -C "${REPO}" checkout -q -b feature
  _spec a_spec alpha beta
  _doc 3 2 '| `alpha` | the original |' '| `beta` | the branch wording |'
  _commit_all feature

  git -C "${REPO}" checkout -q main
  _spec a_spec alpha beta
  _doc 3 2 '| `alpha` | the original |' '| `beta` | the main wording |'
  _commit_all main

  run git -C "${REPO}" merge --no-edit feature
  assert_failure

  run bash "${RESOLVE}" "${REPO}"
  assert_failure
  assert_output --partial 'beta'
  assert_output --partial 'the branch wording'
  assert_output --partial 'the main wording'

  # Refused means untouched as far as git is concerned: still unmerged, so
  # nobody can commit a half-resolved tree by accident.
  run git -C "${REPO}" diff --name-only --diff-filter=U
  assert_output --partial 'doc/test/unit.md'
}
