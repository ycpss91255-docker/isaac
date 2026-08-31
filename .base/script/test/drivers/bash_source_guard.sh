#!/usr/bin/env bash
# drivers/bash_source_guard.sh - "no unguarded BASH_SOURCE self-location
# read" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_bash_source_guard, the recurrence guard for the self-locating read
# every script here opens with.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/home_literal.sh / drivers/stale_setup_conf.sh
# conventions (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why: nearly every script here follows the same two-line shape -- enable
# strict mode, then resolve its own directory from the source array. That
# read has no default, so it aborts under the nounset the script itself
# just turned on, in every context where bash does not populate the array
# for the running file. The sharpest case is the kcov-instrumented shell
# of the coverage shard, where the failure is environment-specific and
# therefore found in CI rather than locally, one round trip at a time.
# Worse, it is not always loud: inside a command substitution only the
# SUBSHELL dies, the outer command still exits 0, and the diagnostic on
# stderr is consumed as if it were the value -- a wrong value with the
# success assertion passing.
#
# The fix the tree standardises on is to default the read to $0. Under
# direct execution both expand to the same path, so it is inert in
# production; where the array is unpopulated it degrades instead of
# aborting. This lint is the mechanical half; the behavioural half is
# test/bats/unit/sourceable_scripts_spec.bats, which actually LOADS every
# sourceable file and proves control comes back.
#
# Scope: *.sh under dist/ (the shipped runtime tree, where a downstream
# repo inherits the shape) and script/ (base's own tooling, where the
# coverage shard runs). Symlinks are skipped by -type f, so a wrapper
# symlink is linted once, at its real path.
#
# What is a violation: an INDEXED read with no default -- ${BASH_SOURCE},
# ${BASH_SOURCE[0]}, ${BASH_SOURCE[1]}, and the suffix-stripped
# ${BASH_SOURCE[0]%/*} shorthand, which is exactly as unbound-fatal as the
# plain form.
#
# What is NOT: the whole-array expansions (${BASH_SOURCE[@]},
# ${BASH_SOURCE[*]}, ${#BASH_SOURCE[@]}), for which bash yields an empty
# list on an unset array even under nounset -- they are not the hazard,
# and flagging them would push authors toward noise. Comment lines are
# skipped for the same reason: prose that explains the rule (this header,
# the ADR, every sibling note) must not be a violation of it.
#
# Allowlist: an explicit, region-delimited opt-out rather than a per-file
# exclusion, so a NEW unguarded read elsewhere in an allowlisted file is
# still caught. Bracket the legitimate lines with
#   # bash-source-lint: allow-begin -- <why>
#   ...
#   # bash-source-lint: allow-end
# There is no live region today. Unbalanced markers (an unterminated
# begin, an unmatched end) fail the lint -- a silently swallowed region
# would re-open exactly the hole this guard closes.

# ── Unguarded BASH_SOURCE read lint ──────────────────────────────────────────

# The scanned trees, repo-root-relative. Each must exist: a missing root
# would make the scan pass vacuously.
readonly _BASH_SOURCE_SCAN_ROOTS=('dist' 'script')

# The array name and the expansion opener are assembled from parts, for the
# same reason stale_setup_conf.sh splits its literal: this driver lives
# INSIDE a scanned tree, so its own source must not carry the very token it
# hunts for.
readonly _BASH_SOURCE_NAME='BASH_SOURCE'
# The opener is data, not an expansion: single quotes are the point.
# shellcheck disable=SC2016
readonly _BASH_SOURCE_OPEN='${'

# An expansion of the array in any form -- what must be gone from a line
# after the accepted forms below have been stripped out of it.
readonly _BASH_SOURCE_ANY="${_BASH_SOURCE_OPEN}${_BASH_SOURCE_NAME}"

# Whole-array / element-count expansions: safe under nounset, so they are
# consumed before the check. Matches an optional '#' (count), the '[@]' or
# '[*]' subscript, and whatever modifier follows up to the closing brace.
readonly _BASH_SOURCE_RE_ARRAY="\\\$\\{#?${_BASH_SOURCE_NAME}\\[[@*]\\][^}]*\\}"

# A defaulted read: the array, an optional numeric subscript, then ':-'.
# Both ${BASH_SOURCE[0]:-$0} (the self-location form) and
# ${BASH_SOURCE[0]:-} (the sourced-vs-executed guard) match.
readonly _BASH_SOURCE_RE_GUARDED="\\\$\\{${_BASH_SOURCE_NAME}(\\[[0-9]+\\])?:-"

# Region markers for the explicit opt-out (see the header note).
readonly _BASH_SOURCE_ALLOW_BEGIN='bash-source-lint: allow-begin'
readonly _BASH_SOURCE_ALLOW_END='bash-source-lint: allow-end'

# _bash_source_unguarded <line> -- true when <line> still expands the array
# without a default once every accepted form has been removed from it.
# Subtractive rather than a single "bad" pattern: the accepted set is small
# and closed, while the ways to spell a bad read are not.
_bash_source_unguarded() {
  local _rest="${1}"
  while [[ "${_rest}" =~ ${_BASH_SOURCE_RE_ARRAY} ]]; do
    _rest="${_rest/"${BASH_REMATCH[0]}"/}"
  done
  while [[ "${_rest}" =~ ${_BASH_SOURCE_RE_GUARDED} ]]; do
    _rest="${_rest/"${BASH_REMATCH[0]}"/}"
  done
  [[ "${_rest}" == *"${_BASH_SOURCE_ANY}"* ]]
}

_run_bash_source_guard() {
  echo "--- Running unguarded BASH_SOURCE read lint ---"
  local _violations=0
  local _root _abs_root _file _rel _line _lineno _in_allow _begin_line

  local -a _files=()
  for _root in "${_BASH_SOURCE_SCAN_ROOTS[@]}"; do
    _abs_root="${REPO_ROOT}/${_root}"
    if [[ ! -d "${_abs_root}" ]]; then
      _die ci_bash_source_guard \
        "scan root '${_root}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the shipped runtime tree and base's own tooling tree."
      return 1
    fi
    while IFS= read -r -d '' _file; do
      _files+=("${_file}")
    done < <(find "${_abs_root}" -name '*.sh' -type f -print0 2>/dev/null \
      | sort -z)
  done

  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if [[ "${_line}" == *"${_BASH_SOURCE_ALLOW_BEGIN}"* ]]; then
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_BASH_SOURCE_ALLOW_END}"* ]]; then
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        continue
      fi

      [[ "${_in_allow}" -eq 1 ]] && continue
      # Comment lines: prose about the shape, not an instance of it.
      [[ "${_line}" =~ ^[[:space:]]*# ]] && continue

      if _bash_source_unguarded "${_line}"; then
        printf '%s:%d: %s\n' "${_rel}" "${_lineno}" "${_line}"
        _violations=$(( _violations + 1 ))
      fi
    done < "${_file}"

    if [[ "${_in_allow}" -eq 1 ]]; then
      printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
        "${_rel}" "${_begin_line}"
      _violations=$(( _violations + 1 ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_bash_source_guard \
      "${_violations} unguarded self-location read(s) / unbalanced allow marker(s) under ${_BASH_SOURCE_SCAN_ROOTS[*]}. An undefaulted read aborts under the nounset the script itself enables wherever bash does not populate the array for the running file -- inside a command substitution it kills only the subshell, so the caller sees a WRONG value and still exits 0. Default it: write \${${_BASH_SOURCE_NAME}[0]:-\$0} (identical under direct execution, degrades instead of aborting elsewhere). A genuinely deliberate read opts out by bracketing it with '# ${_BASH_SOURCE_ALLOW_BEGIN} -- <why>' / '# ${_BASH_SOURCE_ALLOW_END}'."
    return 1
  fi
  echo "unguarded BASH_SOURCE read lint: clean"
}
