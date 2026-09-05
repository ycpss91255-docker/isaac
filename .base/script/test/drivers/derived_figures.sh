#!/usr/bin/env bash
# drivers/derived_figures.sh - "a figure a document repeats must match the
# code that defines it" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers -- and the shipped lib's
# _validate_stage_name / SCHEMA_SECTIONS -- are available. Provides
# _run_derived_figures. Follows drivers/stale_setup_conf.sh /
# drivers/home_literal.sh conventions (sourced lib, uses ${REPO_ROOT},
# _log_* / _die, no main).
#
# Why: two figures had drifted, and each of them lived in more than one
# place, which is exactly what makes a hand fix the wrong answer -- the
# next edit re-opens the gap in whichever copy the editor did not have
# open.
#
#   1. The baseline stage blocklist. _validate_stage_name rejects
#      {sys, devel-base, devel, runtime-test} plus the legacy aliases
#      {base, test}, and deliberately lets `devel-test` through: it is
#      emitted as the `test` service so `[stage:devel-test]` has a runtime
#      control surface. Six documents said otherwise, listing a
#      five-element set with `devel-test` in it -- README.md, two of
#      stage.sh's own docstrings, three localized READMEs and four
#      setup_tui.sh message tables. A reader of any of them concludes the
#      `test` service does not exist.
#
#   2. The setup.conf section list. SCHEMA_SECTIONS is the single source
#      for "which sections exist, in what order"; README.md's overview
#      announced seven and listed eight, missing six real ones.
#
# What is derived, and how:
#
#   - The baseline renderings come from _validate_stage_name's own
#     `return 2` case arms, read back out of `declare -f` (the parsed,
#     canonical form -- immune to comment, indentation and line-wrapping
#     changes in the source file). Every extracted name is then probed
#     back THROUGH the predicate: if one does not return 2 the extraction
#     misread the function, and this lint fails loudly rather than pinning
#     prose to a set it invented.
#   - The section list is SCHEMA_SECTIONS verbatim, and the announced
#     count is just its length.
#
# Scope: the prose surfaces that a maintainer navigates by -- README.md,
# CONTEXT.md, the localized doc/readme/README.*.md, and dist/**/*.sh
# (shipped code comments AND the TUI message tables, which are user-facing
# strings). doc/adr/ and doc/changelog/ are deliberately NOT scanned: an
# ADR and a changelog entry are dated records of what was decided or
# shipped, and rewriting them to match today's code would destroy the
# record.
#
# What this lint does NOT try to be: a general "this English paragraph
# describes this function" mechanism. It pins two named, machine-derivable
# figures. A third figure is a third constant here, not a new framework.

# ── Derived-figure lint ──────────────────────────────────────────────────────

# The prose files that must exist. Each is required: a missing one would
# make the scan pass vacuously, which is how a lint quietly stops linting.
readonly _DERIVED_FIGURES_DOC_FILES=('README.md' 'CONTEXT.md')

# The localized READMEs, scanned through a glob (rather than a fixed list)
# so a fourth language is covered the day it is added.
readonly _DERIVED_FIGURES_DOC_DIR='doc/readme'
readonly _DERIVED_FIGURES_DOC_GLOB='README.*.md'

# The shipped runtime tree. Its *.sh files carry both the stage subsystem's
# own docstrings and the setup_tui.sh message tables a user reads at the
# menu, so a stale set here is not merely a comment.
readonly _DERIVED_FIGURES_CODE_ROOT='dist'

# The setup.conf overview, and the heading whose figure is pinned. The
# heading text is part of the contract: renaming it makes this lint fail
# loudly (naming the expected form) rather than silently stop checking.
readonly _DERIVED_FIGURES_README='README.md'
readonly _DERIVED_FIGURES_CONF_HEADING_RE='^### One conf, ([0-9]+) sections$'
readonly _DERIVED_FIGURES_CONF_HEADING='### One conf, <N> sections'

# A brace-set literal: an opening brace, a lowercase-initial token, then
# only the characters a comma-separated identifier list can contain. The
# restricted class is what keeps a match from spanning unrelated prose
# once the file has been flattened to one line, and what makes `${_var}`
# (leading underscore) and `${VAR}` (uppercase) non-matches.
readonly _DERIVED_FIGURES_SET_RE='\{[a-z][a-z0-9_,. -]*\}'

# A single stage name.
readonly _DERIVED_FIGURES_NAME_RE='^[a-z][a-z0-9_-]*$'

# _derived_join_comma <token>... -- "a, b, c".
_derived_join_comma() {
  local _joined=''
  printf -v _joined '%s, ' "$@"
  printf '%s' "${_joined%, }"
}

# _derived_baseline_arms -- emit one line per baseline case arm of
# _validate_stage_name, tokens space-separated, in source order.
#
# Reads `declare -f`, i.e. bash's own re-rendering of the parsed function,
# so the arms arrive one-per-line in a fixed shape no matter how the source
# file wraps or comments them. An arm counts when its body is exactly
# `return 2` -- the baseline-collision verdict. The reserved-tag arms
# (`return 3`) and the format check are not baseline and are skipped.
_derived_baseline_arms() {
  local -a _lines=()
  mapfile -t _lines < <(declare -f _validate_stage_name 2>/dev/null)
  if [[ "${#_lines[@]}" -eq 0 ]]; then
    return 1
  fi

  local _i _pat _body
  local -a _toks=()
  for (( _i = 0; _i + 1 < ${#_lines[@]}; _i++ )); do
    [[ "${_lines[_i]}" =~ ^[[:space:]]*([a-z][a-z0-9|_\ -]*)\)$ ]] || continue
    _pat="${BASH_REMATCH[1]//|/ }"
    _body="${_lines[_i+1]}"
    _body="${_body#"${_body%%[![:space:]]*}"}"
    _body="${_body%"${_body##*[![:space:]]}"}"
    [[ "${_body}" == 'return 2' ]] || continue
    read -r -a _toks <<< "${_pat}"
    printf '%s\n' "${_toks[*]}"
  done
}

# _derived_baseline_names -- every baseline stage name, one per line.
_derived_baseline_names() {
  local _arm _name
  while read -r -a _arm; do
    for _name in "${_arm[@]}"; do
      printf '%s\n' "${_name}"
    done
  done < <(_derived_baseline_arms)
}

# _derived_baseline_renderings -- the canonical `{a, b, c}` rendering of
# each baseline arm, one per line. This is the ONLY spelling documents may
# use; a set that names a baseline stage and is not one of these is the
# drift this lint exists to catch.
_derived_baseline_renderings() {
  local -a _arm=()
  while read -r -a _arm; do
    printf '{%s}\n' "$(_derived_join_comma "${_arm[@]}")"
  done < <(_derived_baseline_arms)
}

# _derived_flatten <file> <flat_var> <offsets_var> -- render <file> as one
# line, and record where each source line starts inside it.
#
# All three live drift shapes wrap the set: README.md breaks it across two
# markdown lines, stage.sh's docstring breaks it across two `#` comment
# lines, and setup_tui.sh breaks it with an escaped `\n` inside a $'...'
# message. A line-at-a-time matcher would have reported none of them, so
# the file is joined into a single string first, with the leading comment
# marker dropped so the continuation's `#` does not land inside the set.
# Markdown code ticks and tabs become spaces for the same reason (the set
# is written inside backticks in every README).
#
# <offsets_var> receives "<start-offset>:<line-number>" entries, so a match
# found at a flattened offset can still be reported at its source line.
_derived_flatten() {
  local _file="$1"
  local -n _flat_out="$2"
  local -n _offsets_out="$3"
  _flat_out=''
  _offsets_out=()

  local _line _seg
  local _lineno=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    _seg="${_line//\`/ }"
    _seg="${_seg//'\n'/ }"
    _seg="${_seg//$'\t'/ }"
    if [[ "${_seg}" =~ ^[[:space:]]*#[[:space:]]?(.*)$ ]]; then
      _seg="${BASH_REMATCH[1]}"
    fi
    _offsets_out+=( "${#_flat_out}:${_lineno}" )
    _flat_out+="${_seg} "
  done < "${_file}"
}

# _derived_lineno_at <offset> <offsets_var> -- the source line a flattened
# offset came from.
_derived_lineno_at() {
  local _offset="$1"
  local -n _offsets_in="$2"
  local _entry _start _lineno='1'
  for _entry in "${_offsets_in[@]}"; do
    _start="${_entry%%:*}"
    (( _start > _offset )) && break
    _lineno="${_entry#*:}"
  done
  printf '%s' "${_lineno}"
}

# _derived_scan_baseline_sets <file> <rel> <renderings_var> <names_var>
#
# Report every brace-set literal in <file> that names a baseline stage and
# is not one of the canonical renderings. Prints one violation per hit and
# returns the count.
_derived_scan_baseline_sets() {
  local _file="$1" _rel="$2"
  local -n _renderings_in="$3"
  local -n _names_in="$4"

  local _flat=''
  local -a _offsets=()
  _derived_flatten "${_file}" _flat _offsets

  local _violations=0
  local _rest="${_flat}" _consumed=0
  local _match _prefix _offset _inner _tok _canonical _rendering
  local _names_hit _shape_ok _is_canonical
  local -a _toks=()
  while [[ "${_rest}" =~ ${_DERIVED_FIGURES_SET_RE} ]]; do
    _match="${BASH_REMATCH[0]}"
    _prefix="${_rest%%"${_match}"*}"
    _offset=$(( _consumed + ${#_prefix} ))
    _consumed=$(( _offset + ${#_match} ))
    _rest="${_rest:${#_prefix} + ${#_match}}"

    # A brace group glued to a path separator is a shell brace EXPANSION,
    # not a prose set -- `test/bats/smoke/{shared,devel-test,runtime-test}/`
    # is a real directory layout, and rewriting it to the baseline set
    # would be nonsense. Prose always delimits the set with whitespace, a
    # code tick or a bracket.
    if [[ "${_prefix: -1}" == '/' || "${_rest:0:1}" == '/' ]]; then
      continue
    fi

    # Split on commas and trim. A token that is not a bare stage name
    # (an embedded dot, an empty slot) means this is not a stage set at
    # all -- a `${dir}/name` expansion, a brace expansion, prose.
    _inner="${_match#\{}"
    _inner="${_inner%\}}"
    _toks=()
    _shape_ok=1
    local _old_ifs="${IFS}"
    IFS=','
    for _tok in ${_inner}; do
      _tok="${_tok#"${_tok%%[![:space:]]*}"}"
      _tok="${_tok%"${_tok##*[![:space:]]}"}"
      if [[ ! "${_tok}" =~ ${_DERIVED_FIGURES_NAME_RE} ]]; then
        _shape_ok=0
        break
      fi
      _toks+=( "${_tok}" )
    done
    IFS="${_old_ifs}"
    (( _shape_ok )) || continue
    [[ "${#_toks[@]}" -gt 0 ]] || continue

    # Only sets that talk about the baseline are this lint's business.
    _names_hit=0
    for _tok in "${_toks[@]}"; do
      for _canonical in "${_names_in[@]}"; do
        if [[ "${_tok}" == "${_canonical}" ]]; then
          _names_hit=1
          break 2
        fi
      done
    done
    (( _names_hit )) || continue

    # Compare as a SET rendering, not byte-for-byte: spacing is the
    # author's business, membership and order are the code's.
    _rendering="{$(_derived_join_comma "${_toks[@]}")}"
    _is_canonical=0
    for _canonical in "${_renderings_in[@]}"; do
      if [[ "${_rendering}" == "${_canonical}" ]]; then
        _is_canonical=1
        break
      fi
    done
    (( _is_canonical )) && continue

    printf '%s:%s: baseline stage set %s -- expected %s\n' \
      "${_rel}" "$(_derived_lineno_at "${_offset}" _offsets)" \
      "${_rendering}" \
      "$(_derived_join_comma "${_renderings_in[@]}")"
    _violations=$(( _violations + 1 ))
  done

  return "${_violations}"
}

# _derived_check_conf_sections -- pin README.md's setup.conf overview to
# SCHEMA_SECTIONS: the announced count must be the list's length, and the
# `[section]` lines under the heading must be the sections themselves, in
# template order. Prints each violation; returns the count.
_derived_check_conf_sections() {
  local _readme="${REPO_ROOT}/${_DERIVED_FIGURES_README}"
  local -a _lines=()
  mapfile -t _lines < "${_readme}"

  local _i _count='' _heading_idx=-1
  for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
    if [[ "${_lines[_i]}" =~ ${_DERIVED_FIGURES_CONF_HEADING_RE} ]]; then
      _count="${BASH_REMATCH[1]}"
      _heading_idx="${_i}"
      break
    fi
  done

  local _expected_list
  _expected_list="$(_derived_join_comma "${SCHEMA_SECTIONS[@]}")"

  if (( _heading_idx < 0 )); then
    printf "%s: no '%s' heading -- the setup.conf section figure has nowhere to be pinned. Restore the heading (the count is %s) or move the pin in drivers/derived_figures.sh.\\n" \
      "${_DERIVED_FIGURES_README}" "${_DERIVED_FIGURES_CONF_HEADING}" \
      "${#SCHEMA_SECTIONS[@]}"
    return 1
  fi

  local _violations=0
  if [[ "${_count}" != "${#SCHEMA_SECTIONS[@]}" ]]; then
    printf '%s:%s: setup.conf section count is %s, SCHEMA_SECTIONS declares %s\n' \
      "${_DERIVED_FIGURES_README}" "$(( _heading_idx + 1 ))" \
      "${_count}" "${#SCHEMA_SECTIONS[@]}"
    _violations=$(( _violations + 1 ))
  fi

  local -a _found=()
  for (( _i = _heading_idx + 1; _i < ${#_lines[@]}; _i++ )); do
    [[ "${_lines[_i]}" =~ ^#{1,6}[[:space:]] ]] && break
    [[ "${_lines[_i]}" =~ ^\[([a-z_]+)\] ]] && _found+=( "${BASH_REMATCH[1]}" )
  done

  if [[ "${_found[*]}" != "${SCHEMA_SECTIONS[*]}" ]]; then
    printf '%s:%s: setup.conf sections listed as [%s], SCHEMA_SECTIONS declares [%s]\n' \
      "${_DERIVED_FIGURES_README}" "$(( _heading_idx + 1 ))" \
      "$(_derived_join_comma "${_found[@]}")" "${_expected_list}"
    _violations=$(( _violations + 1 ))
  fi

  return "${_violations}"
}

_run_derived_figures() {
  echo "--- Running derived-figure lint ---"

  if ! declare -F _validate_stage_name >/dev/null \
    || [[ ! -v SCHEMA_SECTIONS ]]; then
    _die ci_derived_figures \
      "the shipped lib is not loaded (_validate_stage_name / SCHEMA_SECTIONS missing) -- the figures cannot be derived, and a lint that cannot derive them must not pass."
    return 1
  fi

  local -a _renderings=() _names=()
  mapfile -t _renderings < <(_derived_baseline_renderings)
  mapfile -t _names < <(_derived_baseline_names)
  if [[ "${#_renderings[@]}" -eq 0 || "${#_names[@]}" -eq 0 ]]; then
    _die ci_derived_figures \
      "read no baseline case arms out of _validate_stage_name -- the extraction is broken, so the canonical set is unknown."
    return 1
  fi

  # Probe every extracted name back through the predicate. The extractor
  # reads case arms; this is what proves it read them right, and it is the
  # difference between pinning prose to the code and pinning it to a
  # parser's guess.
  local _name _rc
  for _name in "${_names[@]}"; do
    _rc=0
    _validate_stage_name "${_name}" || _rc=$?
    if [[ "${_rc}" -ne 2 ]]; then
      _die ci_derived_figures \
        "extracted baseline name '${_name}' does not collide with the baseline (_validate_stage_name returned ${_rc}, expected 2) -- the case-arm extraction misread the function."
      return 1
    fi
  done

  # Assemble the scan surface, failing loudly on anything missing.
  local -a _files=()
  local _rel _abs
  for _rel in "${_DERIVED_FIGURES_DOC_FILES[@]}"; do
    _abs="${REPO_ROOT}/${_rel}"
    if [[ ! -f "${_abs}" ]]; then
      _die ci_derived_figures \
        "'${_rel}' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the prose that repeats the figures."
      return 1
    fi
    _files+=( "${_abs}" )
  done

  local _nullglob_was_set=0
  shopt -q nullglob && _nullglob_was_set=1
  shopt -s nullglob
  local _localized
  for _localized in \
    "${REPO_ROOT}/${_DERIVED_FIGURES_DOC_DIR}"/${_DERIVED_FIGURES_DOC_GLOB}; do
    _files+=( "${_localized}" )
  done
  [[ "${_nullglob_was_set}" -eq 1 ]] || shopt -u nullglob

  local _code_root="${REPO_ROOT}/${_DERIVED_FIGURES_CODE_ROOT}"
  if [[ ! -d "${_code_root}" ]]; then
    _die ci_derived_figures \
      "scan root '${_DERIVED_FIGURES_CODE_ROOT}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the shipped runtime tree."
    return 1
  fi
  local _file
  while IFS= read -r -d '' _file; do
    _files+=( "${_file}" )
  done < <(find "${_code_root}" -name '*.sh' -type f -print0 2>/dev/null \
    | sort -z)

  local _violations=0 _hits
  for _file in "${_files[@]}"; do
    _hits=0
    _derived_scan_baseline_sets \
      "${_file}" "${_file#"${REPO_ROOT}"/}" _renderings _names || _hits=$?
    _violations=$(( _violations + _hits ))
  done

  _hits=0
  _derived_check_conf_sections || _hits=$?
  _violations=$(( _violations + _hits ))

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_derived_figures \
      "${_violations} document figure(s) disagree with the code that defines them. The baseline stage blocklist is whatever _validate_stage_name returns 2 for -- currently $(_derived_join_comma "${_renderings[@]}") -- and 'devel-test' is NOT in it (it is emitted as the 'test' service). The setup.conf section list and its count are SCHEMA_SECTIONS. Fix the prose, not the predicate."
    return 1
  fi
  echo "derived-figure lint: clean"
}
