#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/i18n_orphan.sh -- the "an identifier
# documented ONLY in a translation" lint.
#
# The localized-README sync guard compares an English section against its
# translation, so it is structurally blind to an identifier that exists in a
# translation and in neither the English README nor anywhere else: there is
# no English counterpart to compare, so nothing is flagged. Two real blocks
# lived in that blind spot for months -- an `INSTANCE_SUFFIX` /
# `run.sh --instance NAME` / `config/instances/<NAME>` mechanism that had
# been deleted from the code, documented in all three translations, and a
# zh-CN-only `EXEC_ARGS` passthrough shim retired with the Makefile. Both
# were found by hand, not by a gate.
#
# Every other guard in this repo checks that something PRESENT is correct.
# This one is the inverse: something present that should be absent.
#
# Scope decisions this spec pins, each measured rather than assumed:
#   - The haystack is README.md ALONE, never the code tree. The code tree
#     carries negative regression assertions ("this identifier must not
#     appear") and comments explaining an absence ("no such shim here"), and
#     those mention the retired identifier verbatim -- so a code-tree
#     haystack suppresses exactly the findings the lint exists to produce.
#     An identifier present in the code but absent from English is a
#     different finding, and conflating the two muddies both.
#   - The needle set is identifier-shaped tokens inside CODE SPANS -- fenced
#     blocks AND inline backticks. Fences alone are not enough: the
#     `INSTANCE_SUFFIX` prose ran in inline backticks, which a fence-only
#     scan walks straight past.
#   - Path-shaped tokens are deliberately NOT a token shape. Over the
#     translations' history they produce markdown-table debris and paths
#     that are real but live outside README.md, while the env-var and
#     long-option shapes produce nothing but true findings.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; two cases replay the verbatim
# pre-fix blocks, and a final case drives the REAL tree to prove it passes
# today. Shape mirrors home_literal_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/i18n_orphan.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/readme"
  REPO_ROOT="${SCRATCH}"

  # A tree that passes, so each case perturbs exactly one thing. The
  # English side must carry at least one identifier of its own, or the
  # non-vacuity guard fires instead of the case under test.
  _write_english
  _write_translation "README.zh-TW.md" '`USER_NAME` is the OS user.'
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write_english [extra-line]... -- the scratch README.md.
_write_english() {
  {
    printf '# base\n\n'
    printf 'The container user comes from `USER_NAME`, and `just run` takes\n'
    printf '`--target` to pick a stage.\n\n'
    if [[ $# -gt 0 ]]; then
      printf '%s\n' "$@"
    fi
  } > "${SCRATCH}/README.md"
}

# _write_translation <basename> <line>... -- a scratch translation file.
_write_translation() {
  local _name="${1}"; shift
  printf '%s\n' "$@" > "${SCRATCH}/doc/readme/${_name}"
}

# ════════════════════════════════════════════════════════════════════
# _run_i18n_orphan: findings
# ════════════════════════════════════════════════════════════════════

@test "_run_i18n_orphan: FAILS on an env-var identifier in a fenced block that the English README never mentions (#902)" {
  _write_translation "README.ja.md" \
    'Kit style args:' \
    '```bash' \
    "EXEC_ARGS='--/app/port=49100' just exec -t cli bash" \
    '```'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/readme/README.ja.md:3"* ]]
  [[ "${output}" == *"EXEC_ARGS"* ]]
}

@test "_run_i18n_orphan: FAILS on an env-var identifier in an INLINE code span, which a fence-only scan walks past (#902)" {
  # The shape that made the hand-found case hand-found: the prose that
  # documented the removed mechanism was ordinary paragraph text with the
  # identifier in single backticks, never inside a fence.
  _write_translation "README.ja.md" \
    'Some prose about naming.' \
    'The fourth dimension is **`INSTANCE_SUFFIX`**, orthogonal to users.'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/readme/README.ja.md:2"* ]]
  [[ "${output}" == *"INSTANCE_SUFFIX"* ]]
}

@test "_run_i18n_orphan: FAILS on a long option the English README never mentions (#902)" {
  _write_translation "README.zh-CN.md" \
    'Start a second instance with `--instance NAME`.'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/readme/README.zh-CN.md:1"* ]]
  [[ "${output}" == *"--instance"* ]]
}

@test "_run_i18n_orphan: reports EVERY translation that carries an orphan, not just the first (#902)" {
  _write_translation "README.ja.md" 'see `ORPHAN_ONE`'
  _write_translation "README.zh-CN.md" 'see `ORPHAN_TWO`'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.ja.md"* ]]
  [[ "${output}" == *"README.zh-CN.md"* ]]
}

@test "_run_i18n_orphan: names both readings and the opt-out in the failure message (#902)" {
  # A finding is either a mechanism that was removed from the code or a
  # translation that ran ahead of the English. The message has to carry
  # both readings and the escape hatch, or the next reader guesses.
  _write_translation "README.ja.md" 'see `ORPHAN_ONE`'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md"* ]]
  [[ "${output}" == *"${_I18N_ORPHAN_ALLOW_BEGIN}"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_i18n_orphan: what is deliberately NOT a finding
# ════════════════════════════════════════════════════════════════════

@test "_run_i18n_orphan: PASSES when the identifier appears in English PROSE without backticks (#902)" {
  # The English side is read whole, not just its code spans: an identifier
  # the English README mentions in running text is documented, and flagging
  # it would be noise.
  _write_english 'The DEPLOY_STAGE value picks what gets bundled.'
  _write_translation "README.ja.md" 'see `DEPLOY_STAGE`'
  run _run_i18n_orphan
  [ "${status}" -eq 0 ]
}

@test "_run_i18n_orphan: PASSES on an identifier-shaped token in translation prose OUTSIDE any code span (#902)" {
  # Unbackticked prose is not a claim about an identifier. Scanning it is
  # what turns this into a noisy gate -- markdown link targets and
  # untranslated English technical words all live there.
  _write_translation "README.ja.md" \
    'See ../PRD.md and the NOT_AN_IDENTIFIER discussion.'
  run _run_i18n_orphan
  [ "${status}" -eq 0 ]
}

@test "_run_i18n_orphan: PASSES on a path-shaped token absent from the English README (#902)" {
  # Paths are deliberately outside the token shapes: over the translations'
  # history the path shape yields table debris and real paths that simply
  # are not spelled in README.md, while the env-var and long-option shapes
  # yield only true findings.
  _write_translation "README.ja.md" \
    '```' \
    'config/instances/<NAME>.yaml   -> docker compose -f' \
    '```'
  run _run_i18n_orphan
  [ "${status}" -eq 0 ]
}

@test "_run_i18n_orphan: PASSES on a bare '--' separator and on a lone hyphenated word (#902)" {
  # `--` is argv punctuation, not an option, and a hyphenated English word
  # in backticks is not a long option either.
  _write_translation "README.ja.md" \
    'Pass `--` before the command, as in `just exec -- bash`.'
  run _run_i18n_orphan
  [ "${status}" -eq 0 ]
}

@test "_run_i18n_orphan: does NOT flag a longer identifier as a match for a shorter English one (#902)" {
  # Membership is whole-token, not substring: English mentioning
  # `USER_NAME` must not bless a translation-only `USER_NAME_SUFFIX`.
  _write_translation "README.ja.md" 'see `USER_NAME_SUFFIX`'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"USER_NAME_SUFFIX"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_i18n_orphan: the allow-region opt-out
# ════════════════════════════════════════════════════════════════════

@test "_run_i18n_orphan: an allow region suppresses the finding inside it (#902)" {
  _write_translation "README.ja.md" \
    "<!-- ${_I18N_ORPHAN_ALLOW_BEGIN} downstream-only var -->" \
    'see `DOWNSTREAM_ONLY_VAR`' \
    "<!-- ${_I18N_ORPHAN_ALLOW_END} -->"
  run _run_i18n_orphan
  [ "${status}" -eq 0 ]
}

@test "_run_i18n_orphan: FAILS on an orphan AFTER an allow-end (the region does not leak) (#902)" {
  _write_translation "README.ja.md" \
    "<!-- ${_I18N_ORPHAN_ALLOW_BEGIN} downstream-only var -->" \
    'see `DOWNSTREAM_ONLY_VAR`' \
    "<!-- ${_I18N_ORPHAN_ALLOW_END} -->" \
    'see `LEAKED_ORPHAN_VAR`'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.ja.md:4"* ]]
  [[ "${output}" != *"DOWNSTREAM_ONLY_VAR"* ]]
}

@test "_run_i18n_orphan: FAILS on an unterminated allow-begin (#902)" {
  # A swallowed region would silently disable the guard for the rest of the
  # file, which is the hole this lint exists to close.
  _write_translation "README.ja.md" \
    "<!-- ${_I18N_ORPHAN_ALLOW_BEGIN} downstream-only var -->" \
    'see `DOWNSTREAM_ONLY_VAR`'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_i18n_orphan: FAILS on an allow-end with no open allow-begin (#902)" {
  _write_translation "README.ja.md" \
    'see `USER_NAME`' \
    "<!-- ${_I18N_ORPHAN_ALLOW_END} -->"
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_i18n_orphan: vacuous-pass guards
# ════════════════════════════════════════════════════════════════════

@test "_run_i18n_orphan: DIES when README.md is missing rather than passing vacuously (#902)" {
  rm -f "${SCRATCH}/README.md"
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"README.md"* ]]
}

@test "_run_i18n_orphan: DIES when the translation directory is missing (#902)" {
  rm -rf "${SCRATCH}/doc/readme"
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"doc/readme"* ]]
}

@test "_run_i18n_orphan: DIES when the translation directory holds no translation (#902)" {
  rm -f "${SCRATCH}"/doc/readme/README.*.md
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no translation"* ]]
}

@test "_run_i18n_orphan: DIES when the English README yields no identifier at all (#902)" {
  # An empty reference set would flag every token in every translation, so
  # the tokenizer having silently stopped working must be an error, not a
  # flood.
  printf '# base\n\nprose only\n' > "${SCRATCH}/README.md"
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no identifier"* ]]
}

@test "_run_i18n_orphan: DIES when no translation yields a single scanned token (#902)" {
  # The mirror guard: a tokenizer or fence-tracking regression that stops
  # extracting from the translation side would make the lint pass on
  # everything forever.
  _write_translation "README.zh-TW.md" 'prose with no code spans at all'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no identifier"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_i18n_orphan: the two blocks that survived every existing guard
# ════════════════════════════════════════════════════════════════════

@test "_run_i18n_orphan: catches the removed per-instance mechanism verbatim, as it stood before the hand fix (#902)" {
  # Verbatim from doc/readme/README.ja.md as it stood before the manual
  # cleanup: the identifier sits in bold inline backticks in running prose,
  # and the option in a line-wrapped inline span. The mechanism had been
  # deleted from the code, so the English README named neither.
  _write_translation "README.ja.md" \
    'name も結果としてユーザ間衝突を回避できます。' \
    '' \
    '**`INSTANCE_SUFFIX`** は 4 つ目の次元で、user 分離とは直交します。' \
    '同じ OS user が同一 repo の container を複数並行起動したい場合' \
    '（例: 2 つの branch を同時にテスト）、`INSTANCE_SUFFIX=2` を設定' \
    'すると `alice-<repo>-2` と対応する project name が得られます。' \
    'デフォルトは空文字列で、wrapper が対応する場面では `-n /' \
    '--instance` で指定できます。'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"INSTANCE_SUFFIX"* ]]
  [[ "${output}" == *"README.ja.md:3"* ]]
}

@test "_run_i18n_orphan: catches the retired argv shim verbatim, as it stood before the hand fix (#902)" {
  # Verbatim from doc/readme/README.zh-CN.md as it stood before the manual
  # cleanup: a fenced example for a passthrough shim that had been retired
  # together with the Makefile, documented in zh-CN alone.
  _write_translation "README.zh-CN.md" \
    '```bash' \
    'just docker build                            # rebuild' \
    '' \
    "EXEC_ARGS='--/app/livestream/port=49100' \\" \
    '  just docker exec -t headless-stream /isaac-sim/runheadless.sh -v' \
    '```'
  run _run_i18n_orphan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"EXEC_ARGS"* ]]
  [[ "${output}" == *"README.zh-CN.md:4"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_i18n_orphan: the real tree
# ════════════════════════════════════════════════════════════════════

@test "_run_i18n_orphan: the real repo tree carries no translation-only identifier (#902)" {
  REPO_ROOT="/source"
  run _run_i18n_orphan
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
