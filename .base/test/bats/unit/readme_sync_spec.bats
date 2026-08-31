#!/usr/bin/env bats
#
# Unit tests for the localized-README drift guard: the generator
# script/test/sync-readme-hashes.sh (_sync_readme_hashes -- stamps each
# translated section with the hash of the English section it was translated
# against) and its read-only twin script/test/drivers/readme_sync.sh
# (_run_readme_sync -- the lint that reports a translation section whose
# recorded hash no longer matches the English source).
#
# The English author changes nothing; the translator never types a hash. The
# guard therefore has to answer three questions per translated file: is this
# section stale, is it missing, and is it deliberately untranslated.
#
# A fourth block answers the question the guard could not: does a re-stamp
# mean anything. It performs the silencing case -- edit the English, run the
# generator, expect the gate to go quiet -- rather than asserting on the
# marker format, because the format was never the defect; the missing
# translation-side record was.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live READMEs; a final pair of cases drives the REAL
# tree to prove it is stamped and clean today.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # stale_setup_conf_lint_spec.bats / issueref_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/readme_sync.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/readme"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _en <line>... -- write the scratch English README.
_en() {
  printf '%s\n' "$@" > "${SCRATCH}/README.md"
}

# _tr <lang> <line>... -- write a scratch translation.
_tr() {
  local _lang="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/doc/readme/README.${_lang}.md"
}

# _en_default -- the three-section English fixture every case starts from.
_en_default() {
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body.'
}

# _tr_default -- a translation carrying an id-only marker per section (what a
# translator writes by hand; the hash is the generator's job).
_tr_default() {
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '前言。' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲' \
    '' \
    '甲本文。' \
    '' \
    '<!-- sync: beta -->' \
    '## 乙' \
    '' \
    '乙本文。'
}

# _stamped -- the default fixture pair, stamped by the real generator.
_stamped() {
  _en_default
  _tr_default
  _sync_readme_hashes "${SCRATCH}" >/dev/null
}

# _en_beta_rewritten -- the English fixture with Beta's body rewritten in
# place. The heading survives, so only a content fingerprint sees it.
_en_beta_rewritten() {
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
}

# _tr_edit <lang> <old> <new> -- edit translated prose in place, the way a
# translator does: the stamped markers around it survive untouched.
_tr_edit() {
  local _lang="${1}" _old="${2}" _new="${3}"
  sed -i "s/${_old}/${_new}/" "${SCRATCH}/doc/readme/README.${_lang}.md"
}

# _marker <id> -- the stamped marker line for <id> in the zh-TW fixture.
_marker() {
  grep -E "^<!-- sync: ${1} " "${SCRATCH}/doc/readme/README.zh-TW.md"
}

# ════════════════════════════════════════════════════════════════════
# _run_readme_sync: the failure that motivated the guard
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: FAILS when an English section is rewritten in place and the translation is untouched (#846)" {
  _stamped
  # The heading survives, the body is rewritten -- the exact shape of the
  # drift a structural (headings-only) check cannot see.
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.zh-TW.md"* ]]
}

@test "_run_readme_sync: names the drifted SECTION, not just the file (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"beta"* ]]
  # The untouched sections must NOT be reported.
  [[ "${output}" != *"'alpha'"* ]]
}

@test "_run_readme_sync: FAILS on an English section with no marker in a translation (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body.' \
    '' \
    '## Gamma' \
    '' \
    'Gamma body.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"gamma"* ]]
  [[ "${output}" == *"MISSING"* ]]
}

@test "_run_readme_sync: PASSES a tree the generator has just stamped (#846)" {
  _stamped
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: PASSES again after an English edit, a re-translation and a re-run of the generator (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, rewritten and then re-translated.'
  _tr_edit zh-TW '乙本文。' '乙本文，已重譯。'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_readme_sync: untranslated sections, marker hygiene
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: EXEMPTS a section declared untranslated with sync-skip (#846)" {
  _en_default
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '前言。' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲' \
    '' \
    '甲本文。' \
    '' \
    '<!-- sync-skip: beta -- English-only reference section -->'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: FAILS on an UNSTAMPED marker (id written, generator never run) (#846)" {
  _en_default
  _tr_default
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"UNSTAMPED"* ]]
}

@test "_run_readme_sync: FAILS on a marker naming an id that is not an English section (#846)" {
  _stamped
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '## 甲' \
    '' \
    '<!-- sync: delta 000000000000 -->' \
    '## 丁' \
    '' \
    '<!-- sync-skip: beta -- untranslated -->'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"UNKNOWN"* ]]
  [[ "${output}" == *"delta"* ]]
}

@test "_run_readme_sync: FAILS on the same id claimed twice in one translation (#846)" {
  _stamped
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '## 甲' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '## 甲之二' \
    '' \
    '<!-- sync-skip: beta -- untranslated -->'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"DUPLICATE"* ]]
}

@test "_run_readme_sync: FAILS on a sync marker that is not followed by a heading (#846)" {
  _stamped
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha 000000000000 -->' \
    '這不是標題。' \
    '' \
    '<!-- sync-skip: beta -- untranslated -->'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"MISPLACED"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Section identity and hash input
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: ignores ATX-looking lines inside fenced code blocks (#846)" {
  # README.md's TL;DR fences shell comments starting with '#'; treating them
  # as headings would invent sections that no translation can ever carry.
  _en \
    '# Title' \
    '' \
    '```bash' \
    '# Not a heading' \
    '## Also not a heading' \
    '```' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.'
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: trailing whitespace in the English body does not flip the hash (#846)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.   ' \
    '' \
    '## Beta' \
    '' \
    'Beta body.' \
    ''
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_readme_sync: a nested subsection is its own section, the parent body stops at it (#846)" {
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '### Alpha detail' \
    '' \
    'Detail body.'
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題' \
    '' \
    '<!-- sync: alpha -->' \
    '## 甲' \
    '' \
    '<!-- sync: alpha-detail -->' \
    '### 甲細節'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]

  # Editing ONLY the subsection must flag the subsection, not the parent.
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '### Alpha detail' \
    '' \
    'Detail body, rewritten.'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"alpha-detail"* ]]
  [[ "${output}" != *"'alpha'"* ]]
}

@test "_run_readme_sync: FAILS when two English headings share one slug (ambiguous id) (#846)" {
  _en \
    '# Title' \
    '' \
    '## Alpha' \
    '' \
    'One.' \
    '' \
    '## alpha' \
    '' \
    'Two.'
  _tr zh-TW \
    '<!-- sync: title 000000000000 -->' \
    '# 標題'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"AMBIGUOUS"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _sync_readme_hashes: the generator
# ════════════════════════════════════════════════════════════════════

@test "_sync_readme_hashes: stamps an id-only marker with the English section hash (#846)" {
  _en_default
  _tr_default
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -eq 0 ]
  run grep -E '^<!-- sync: alpha [0-9a-f]{12} [0-9a-f]{12} -->$' \
    "${SCRATCH}/doc/readme/README.zh-TW.md"
  [ "${status}" -eq 0 ]
}

@test "_sync_readme_hashes: re-stamps a stale hash (#846)" {
  _stamped
  before="$(_marker beta)"
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, rewritten.'
  _tr_edit zh-TW '乙本文。' '乙本文，已重譯。'
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  [[ "$(_marker beta)" != "${before}" ]]
}

@test "_sync_readme_hashes: is idempotent on an already-stamped tree (#846)" {
  _stamped
  a="$(cat "${SCRATCH}/doc/readme/README.zh-TW.md")"
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  b="$(cat "${SCRATCH}/doc/readme/README.zh-TW.md")"
  [[ "${a}" == "${b}" ]]
}

@test "_sync_readme_hashes: leaves the translated prose untouched (stamps only markers) (#846)" {
  _stamped
  run grep -c '甲本文。' "${SCRATCH}/doc/readme/README.zh-TW.md"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "1" ]]
}

@test "_sync_readme_hashes: reports the sections a translation is still missing (#846)" {
  _en_default
  _tr zh-TW \
    '<!-- sync: title -->' \
    '# 標題'
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"alpha"* ]]
  [[ "${output}" == *"beta"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _sync_readme_hashes: a re-stamp has to mean something
#
# The generator records the ENGLISH hash. On its own that makes "I updated
# the translation, then synced" indistinguishable from "I synced so the gate
# would stop complaining". These cases PERFORM the silencing attempt and
# assert it does not end in a green tree.
# ════════════════════════════════════════════════════════════════════

@test "_sync_readme_hashes: REFUSES to re-stamp a section whose English moved while the translation did not (#873)" {
  _stamped
  before="$(_marker beta)"
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"beta"* ]]
  # The recorded hash must NOT have moved: a refusal that still wrote the
  # new hash would be the silencing case with extra steps.
  [[ "$(_marker beta)" == "${before}" ]]
}

@test "_sync_readme_hashes: an English-only edit plus a sync run leaves the lint RED (#873)" {
  _stamped
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -ne 0 ]
  # The whole point: running the generator did not buy a green tree.
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"beta"* ]]
}

@test "_sync_readme_hashes: refusing one section still stamps the untouched ones (#873)" {
  _en_default
  _tr_default
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -ne 0 ]
  # alpha never drifted, so it stays stamped and is not named.
  [[ "${output}" != *"'alpha'"* ]]
  run _run_readme_sync
  [[ "${output}" != *"'alpha'"* ]]
}

@test "_sync_readme_hashes: re-stamps when the translation moved together with the English (#873)" {
  _stamped
  _en_beta_rewritten
  _tr_edit zh-TW '乙本文。' '乙本文，已重寫。'
  run _sync_readme_hashes "${SCRATCH}"
  [ "${status}" -eq 0 ]
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_sync_readme_hashes: --accept records a reviewed no-op and clears the lint (#873)" {
  # The accepted cost from the guard's introduction: an English typo fix
  # marks the translations stale and the human confirms nothing needs
  # re-translating. That must stay one command -- an EXPLICIT one.
  _stamped
  _en_beta_rewritten
  run _sync_readme_hashes "${SCRATCH}" beta
  [ "${status}" -eq 0 ]
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_sync_readme_hashes: --accept clears only the section it names (#873)" {
  _stamped
  _en \
    '# Title' \
    '' \
    'Intro body.' \
    '' \
    '## Alpha' \
    '' \
    'Alpha body, rewritten too.' \
    '' \
    '## Beta' \
    '' \
    'Beta body, completely rewritten in place.'
  run _sync_readme_hashes "${SCRATCH}" beta
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"alpha"* ]]
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"alpha"* ]]
}

@test "_sync_readme_hashes: records the translation's own hash beside the English one (#873)" {
  _stamped
  run grep -E '^<!-- sync: beta [0-9a-f]{12} [0-9a-f]{12} -->$' \
    "${SCRATCH}/doc/readme/README.zh-TW.md"
  [ "${status}" -eq 0 ]
}

@test "_run_readme_sync: FAILS when the translated prose changed since it was stamped (#873)" {
  # Without this the recorded translation hash goes stale, and a later
  # English edit would read the un-stamped translation edit as evidence of
  # a re-translation it never was.
  _stamped
  _tr_edit zh-TW '乙本文。' '乙本文，微調過。'
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"UNRECORDED"* ]]
  [[ "${output}" == *"beta"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Fail-loud guards: never pass vacuously
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: FAILS when the English README is missing (#846)" {
  _tr_default
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md"* ]]
}

@test "_run_readme_sync: FAILS when no translation files are found (#846)" {
  _en_default
  run _run_readme_sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/readme"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_readme_sync: the REAL doc/readme/ tree is stamped and clean today (#846)" {
  REPO_ROOT="/source"
  run _run_readme_sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_sync_readme_hashes: is a no-op on the REAL tree (already stamped) (#846)" {
  # Run the generator against a copy so the live tree is never mutated by a
  # test; an already-stamped tree must come back byte-identical.
  cp /source/README.md "${SCRATCH}/README.md"
  cp /source/doc/readme/README.zh-TW.md "${SCRATCH}/doc/readme/README.zh-TW.md"
  cp /source/doc/readme/README.zh-CN.md "${SCRATCH}/doc/readme/README.zh-CN.md"
  cp /source/doc/readme/README.ja.md "${SCRATCH}/doc/readme/README.ja.md"
  _sync_readme_hashes "${SCRATCH}" >/dev/null
  run diff -r /source/doc/readme "${SCRATCH}/doc/readme"
  [ "${status}" -eq 0 ]
}
