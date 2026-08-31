#!/usr/bin/env bash
# drivers/i18n_orphan.sh - "no identifier documented ONLY in a translation"
# per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_i18n_orphan.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/home_literal.sh / drivers/readme_sync.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why this is a SEPARATE lint from readme-sync: the sync guard is a
# per-section fingerprint, i.e. "did the translation move when the English
# moved?". It is structurally blind to an identifier that exists in a
# translation and NOWHERE else, because that identifier has no English
# counterpart -- nothing to compare, so nothing to flag. Two real blocks
# lived in that blind spot for months and were found by hand rather than by
# any gate: a per-instance mechanism (an env suffix, a `--instance` option
# and a per-instance overlay directory) that had been deleted from the code
# while all three translations kept documenting it, and a zh-CN-only argv
# passthrough shim retired together with the Makefile. The first was a
# silent no-op, the second a hard `unknown option`.
#
# Note the inversion. Every other guard in this repo -- the sync
# fingerprints, the derived figures, the stale-path and home-path literal
# scans -- checks that something PRESENT is correct. This one checks for
# something present that should be ABSENT, which is why none of them could
# have found either block.
#
# ── The three scope decisions, each measured rather than assumed ────────────
#
# 1. The haystack is README.md ALONE, never the code tree.
#
#    Measured: with the code tree added to the haystack, BOTH known blocks
#    stop being reported. The code tree carries negative regression
#    assertions ("this identifier must not appear anywhere in the wrapper")
#    and comments explaining an absence ("no such env shim here; just does
#    not have make's argv quirks"), and each of those spells the retired
#    identifier verbatim. A code-tree haystack therefore suppresses exactly
#    the findings this lint exists to produce.
#
#    It is also the cleaner question. An identifier present in the code but
#    absent from the English README is a DIFFERENT finding -- English is
#    missing something -- and conflating the two muddies both.
#
# 2. The needle set is identifier-shaped tokens inside CODE SPANS: fenced
#    blocks AND inline backticks.
#
#    Fences alone are language-independent and an obvious starting point,
#    but measured against the pre-fix tree they catch only one of the two
#    known blocks: the per-instance prose ran in ordinary paragraphs with
#    the identifier in inline backticks, which a fence-only scan walks
#    straight past. Adding inline spans catches both and, measured across
#    every historical revision of the translation set, adds no finding that
#    is not a true one. Scanning unfenced prose does not: it immediately
#    picks up markdown link targets and untranslated English technical
#    words, which is the noise that gets a lint muted.
#
# 3. Path-shaped tokens are NOT a token shape here.
#
#    Measured over the translations' history, the path shape fires on
#    markdown table debris (`<br/>`-joined cells tokenize as a path) and on
#    paths that are perfectly real but simply are not spelled in README.md,
#    at revisions where the env-var and long-option shapes are silent. The
#    two shapes below produce, across that same history, nothing that is not
#    a true finding -- so the narrow pair is what ships, and a lint that
#    cries wolf gets muted.
#
# Blocking, not advisory, on that evidence: the measured false-positive
# count on the current tree is zero, and zero at every sampled point of the
# translation set's history.
#
# Escape hatch, for the case the measurement says is rare rather than
# impossible -- an identifier that is genuinely real but lives in a
# downstream repo, or a translation that legitimately runs ahead of the
# English. Bracket the lines with
#   <!-- i18n-orphan-lint: allow-begin -- <why> -->
#   ...
#   <!-- i18n-orphan-lint: allow-end -->
# An HTML comment renders as nothing, so the marker costs the reader
# nothing, and the `<why>` is the point: an opt-out with a reason is a
# decision, an opt-out without one is decay. Unbalanced markers (an
# unterminated begin, an unmatched end) fail the lint -- a silently
# swallowed region would re-open the hole this guard closes. A region
# swallows everything between its markers, fences included, so a whole
# example block can be bracketed from outside.

# ── Translation-only identifier lint ─────────────────────────────────────────

# The English reference and the translations it is compared against. Both
# must exist, and at least one translation must be found: an empty scan
# would pass vacuously and silently disable the guard. The translation set
# is a glob, not a list, so a fourth language is covered the day it lands.
readonly _I18N_ORPHAN_SOURCE_REL='README.md'
readonly _I18N_ORPHAN_DIR_REL='doc/readme'
readonly _I18N_ORPHAN_GLOB='README.*.md'

# The two token shapes (see scope decision 3 above for what is excluded).
#
#   env  an UPPER_SNAKE identifier with at least one underscore, i.e. the
#        shape of an environment variable or a shell constant. The
#        underscore requirement is what keeps ordinary capitalised English
#        ("README", "GUI", "ROS") out of the token stream.
#   opt  a GNU-style long option. The left-context group rejects a match
#        inside a longer run of hyphens or in the middle of a word, so
#        `---x` and `foo--bar` do not tokenize.
readonly _I18N_ORPHAN_ENV_RE='[A-Z][A-Z0-9]*(_[A-Z0-9]+)+'
readonly _I18N_ORPHAN_OPT_RE='--[a-z][a-z0-9]*(-[a-z0-9]+)*'
readonly _I18N_ORPHAN_OPT_CTX_RE="(^|[^-[:alnum:]_])${_I18N_ORPHAN_OPT_RE}"

# A fence opener or closer, with or without an info string.
readonly _I18N_ORPHAN_FENCE_RE='^[[:space:]]*(```|~~~)'

# An inline code span. Deliberately single-line: a span that wraps across a
# newline is not matched, which loses a token rather than inventing one.
# shellcheck disable=SC2016 # backticks are the markdown delimiter, literal.
readonly _I18N_ORPHAN_SPAN_RE='`[^`]+`'

# Region markers for the explicit opt-out (see the header note).
readonly _I18N_ORPHAN_ALLOW_BEGIN='i18n-orphan-lint: allow-begin'
readonly _I18N_ORPHAN_ALLOW_END='i18n-orphan-lint: allow-end'

# _i18n_orphan_tokens <text>
#
# Print every identifier-shaped token in <text>, one per line, unsorted and
# possibly repeated. Both shapes run over the same text so the caller cannot
# apply one and forget the other; `|| true` because grep exits 1 on no
# match, which is the common case and not an error.
_i18n_orphan_tokens() {
  local _text="${1}"
  grep -oE -- "${_I18N_ORPHAN_ENV_RE}" <<<"${_text}" || true
  grep -oE -- "${_I18N_ORPHAN_OPT_CTX_RE}" <<<"${_text}" \
    | grep -oE -- "${_I18N_ORPHAN_OPT_RE}" || true
}

# _i18n_orphan_spans <line>
#
# Print the contents of <line>'s inline code spans, backticks stripped, one
# span per line. Empty output when the line has none.
_i18n_orphan_spans() {
  local _line="${1}"
  grep -oE -- "${_I18N_ORPHAN_SPAN_RE}" <<<"${_line}" | tr -d '`' || true
}

_run_i18n_orphan() {
  echo "--- Running translation-only identifier lint ---"

  local _src="${REPO_ROOT}/${_I18N_ORPHAN_SOURCE_REL}"
  if [[ ! -f "${_src}" ]]; then
    _die ci_i18n_orphan \
      "English source '${_I18N_ORPHAN_SOURCE_REL}' not found under ${REPO_ROOT} -- there is no reference set to compare the translations against, so the lint would flag everything or nothing."
    return 1
  fi
  local _dir="${REPO_ROOT}/${_I18N_ORPHAN_DIR_REL}"
  if [[ ! -d "${_dir}" ]]; then
    _die ci_i18n_orphan \
      "translation directory '${_I18N_ORPHAN_DIR_REL}/' not found under ${REPO_ROOT} -- the lint would pass vacuously."
    return 1
  fi

  local -a _files=()
  local _file
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_dir}" -maxdepth 1 -type f -name "${_I18N_ORPHAN_GLOB}" \
             -print0 2>/dev/null | sort -z)
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _die ci_i18n_orphan \
      "no translation matching '${_I18N_ORPHAN_DIR_REL}/${_I18N_ORPHAN_GLOB}' -- the lint would pass vacuously."
    return 1
  fi

  # The reference set: every identifier the English README names ANYWHERE,
  # code span or running prose. Read whole on purpose -- an identifier the
  # English mentions in a sentence is documented, and flagging it would be
  # exactly the noise that gets a lint muted.
  local -A _known=()
  local _token
  while IFS= read -r _token; do
    [[ -n "${_token}" ]] && _known["${_token}"]=1
  done < <(_i18n_orphan_tokens "$(cat "${_src}")")
  if [[ "${#_known[@]}" -eq 0 ]]; then
    _die ci_i18n_orphan \
      "'${_I18N_ORPHAN_SOURCE_REL}' yielded no identifier at all -- the reference set is empty, so every token in every translation would be reported. The tokenizer, not the README, is what to look at."
    return 1
  fi

  local _violations=0 _scanned=0
  local _rel _line _lineno _in_fence _in_allow _begin_line _text
  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_fence=0
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      # An open region swallows everything to its end marker, fences
      # included, so a whole example block can be bracketed from outside.
      if [[ "${_in_allow}" -eq 1 ]]; then
        [[ "${_line}" == *"${_I18N_ORPHAN_ALLOW_END}"* ]] && _in_allow=0
        continue
      fi
      if [[ "${_line}" == *"${_I18N_ORPHAN_ALLOW_BEGIN}"* ]]; then
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_I18N_ORPHAN_ALLOW_END}"* ]]; then
        printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
          "${_rel}" "${_lineno}"
        _violations=$(( _violations + 1 ))
        continue
      fi

      if [[ "${_line}" =~ ${_I18N_ORPHAN_FENCE_RE} ]]; then
        _in_fence=$(( 1 - _in_fence ))
        continue
      fi

      if [[ "${_in_fence}" -eq 1 ]]; then
        _text="${_line}"
      else
        _text="$(_i18n_orphan_spans "${_line}")"
      fi
      [[ -z "${_text}" ]] && continue

      while IFS= read -r _token; do
        [[ -z "${_token}" ]] && continue
        _scanned=$(( _scanned + 1 ))
        [[ -n "${_known["${_token}"]:-}" ]] && continue
        printf '%s:%d: %s -- %s\n' "${_rel}" "${_lineno}" "${_token}" "${_line}"
        _violations=$(( _violations + 1 ))
      done < <(_i18n_orphan_tokens "${_text}")
    done < "${_file}"

    if [[ "${_in_allow}" -eq 1 ]]; then
      printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
        "${_rel}" "${_begin_line}"
      _violations=$(( _violations + 1 ))
    fi
  done

  # The mirror of the empty-reference-set guard: a tokenizer or
  # fence-tracking regression that stops extracting from the translation
  # side would make this lint pass on everything, forever, in silence.
  if [[ "${_scanned}" -eq 0 ]]; then
    _die ci_i18n_orphan \
      "the ${#_files[@]} translation(s) under '${_I18N_ORPHAN_DIR_REL}/' yielded no identifier at all -- nothing was compared, so the lint would pass vacuously. The tokenizer or the fence tracking, not the translations, is what to look at."
    return 1
  fi

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_i18n_orphan \
      "${_violations} identifier(s) documented only in a translation / unbalanced allow marker(s). Each is one of two things, and both want a human: a mechanism that was REMOVED from the code while the translation kept documenting it, or a translation that ran AHEAD of ${_I18N_ORPHAN_SOURCE_REL}. Fix the first by deleting the block, the second by writing the English. A genuinely legitimate one (an identifier that lives in a downstream repo) opts out by bracketing it with '<!-- ${_I18N_ORPHAN_ALLOW_BEGIN} -- <why> -->' / '<!-- ${_I18N_ORPHAN_ALLOW_END} -->'."
    return 1
  fi
  echo "translation-only identifier lint: clean (${_scanned} identifier(s) checked across ${#_files[@]} translation(s))"
}
