#!/usr/bin/env bash
# drivers/stale_setup_conf.sh - "no stale config/docker/setup.conf path in
# runtime shell code" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_stale_setup_conf, the guard against the pre-relocation setup.conf
# path creeping back into shipped runtime code.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/issueref.sh / drivers/adr_numbering.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why: setup.conf is `just setup`-managed, not hand-edited, so it left the
# hand-editable config/ surface for the repo-root .setup.conf dotfile, and
# the path constants in lib/setup_conf.sh, lib/resolve.sh and the wrapper /
# init / upgrade paths moved in lockstep (ADR-00000006 requires that
# lockstep). A newly added lib that hardcodes the legacy path reads a
# location that no longer exists: the repo's config knobs are then silently
# ignored, with no error and no test to catch it. This lint is the
# recurrence guard.
#
# Scope: dist/**/*.sh -- the shipped runtime tree, the only place where a
# stale read is a live defect. Docs and CHANGELOG legitimately discuss the
# old path and are deliberately NOT scanned.
#
# Allowlist: an explicit, region-delimited opt-out rather than a per-file
# exclusion, so a NEW stale reference elsewhere in an allowlisted file is
# still caught. Bracket the legitimate lines with
#   # stale-path-lint: allow-begin -- <why>
#   ...
#   # stale-path-lint: allow-end
# The one live region is the legacy-migration block in
# dist/script/base/upgrade.sh, which must name the old path in order to
# relocate a downstream still carrying it. Unbalanced markers (an
# unterminated begin, an unmatched end) fail the lint -- a silently
# swallowed region would re-open exactly the hole this guard closes.

# ── Stale setup.conf path lint ───────────────────────────────────────────────

# The relocated file's basename, kept separate from the legacy directory
# so the driver's own source never carries the stale path as one token
# (it lives under script/, outside the scanned tree, but keeping it split
# means a grep for the stale literal reports only genuine call sites).
readonly _STALE_SETUP_CONF_BASENAME='setup.conf'
readonly _STALE_SETUP_CONF_LEGACY="config/docker/${_STALE_SETUP_CONF_BASENAME}"
readonly _STALE_SETUP_CONF_REPLACEMENT=".${_STALE_SETUP_CONF_BASENAME}"

# The scanned tree, repo-root-relative. Must exist: a missing root would
# make the scan pass vacuously.
readonly _STALE_SETUP_CONF_SCAN_ROOT='dist'

# Region markers for the explicit opt-out (see the header note).
readonly _STALE_SETUP_CONF_ALLOW_BEGIN='stale-path-lint: allow-begin'
readonly _STALE_SETUP_CONF_ALLOW_END='stale-path-lint: allow-end'

_run_stale_setup_conf() {
  echo "--- Running stale setup.conf path lint ---"
  local _violations=0
  local _file _rel _line _lineno _in_allow _begin_line

  # Fail loudly on a missing scan root: an empty find root would pass
  # vacuously and silently disable the lint if the shipped tree ever moves.
  local _scan_root="${REPO_ROOT}/${_STALE_SETUP_CONF_SCAN_ROOT}"
  if [[ ! -d "${_scan_root}" ]]; then
    _die ci_stale_setup_conf_path \
      "scan root '${_STALE_SETUP_CONF_SCAN_ROOT}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the shipped runtime tree."
    return 1
  fi

  local -a _files=()
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_scan_root}" -name '*.sh' -type f -print0 2>/dev/null \
    | sort -z)

  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if [[ "${_line}" == *"${_STALE_SETUP_CONF_ALLOW_BEGIN}"* ]]; then
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_STALE_SETUP_CONF_ALLOW_END}"* ]]; then
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        continue
      fi

      [[ "${_in_allow}" -eq 1 ]] && continue

      if [[ "${_line}" == *"${_STALE_SETUP_CONF_LEGACY}"* ]]; then
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
    _die ci_stale_setup_conf_path \
      "${_violations} stale '${_STALE_SETUP_CONF_LEGACY}' reference(s) / unbalanced allow marker(s) under dist/. The per-repo override and the template default live at the repo-root '${_STALE_SETUP_CONF_REPLACEMENT}' dotfile; use that path. A legitimate legacy-migration line opts out by bracketing it with '# ${_STALE_SETUP_CONF_ALLOW_BEGIN} -- <why>' / '# ${_STALE_SETUP_CONF_ALLOW_END}'."
    return 1
  fi
  echo "stale setup.conf path lint: clean"
}
