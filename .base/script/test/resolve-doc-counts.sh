#!/usr/bin/env bash
#
# resolve-doc-counts.sh - resolve a doc/test/*.md merge conflict in ONE
# command: collapse the conflict markers, regenerate the derived figures
# authoritatively, verify, stage.
#
# Usage:
#   ./script/test/resolve-doc-counts.sh            # repo root via git
#   ./script/test/resolve-doc-counts.sh <ABS root> # explicit, ABSOLUTE
#
# Exit status: 0 = resolved (or nothing to resolve, and the tree verifies);
# 1 = refused, with the reason on stderr. Nothing is staged on a refusal.
#
# Why this exists
# ---------------
# Every merge of main into a queued branch conflicts on doc/test/TEST.md and
# doc/test/unit.md, because both sides bumped the same generated counters. The
# resolution never needs judgement -- collapse to either side, then regenerate
# -- yet it was retyped by hand six times in a single review batch and pasted
# verbatim into every dispatched agent prompt, awk one-liner included.
#
# Why it is not just the awk one-liner
# ------------------------------------
# A mechanical collapse adopts whichever side it keeps, INCLUDING for content
# the generator does not derive. That already bit this repo: the "System (N)
# and smoke (N)" prose in TEST.md was hand-maintained, and a collapse silently
# carried the stale side through three times before the generator learned to
# regenerate it. Per-test catalog rows reopened the same hazard from the other
# end -- the row NAMES are generated, the DESCRIPTIONS are hand-written prose
# the generator preserves but cannot re-derive, so a collapse can drop a
# sentence nothing will ever put back.
#
# So this script never trusts one side. It regenerates BOTH collapses and
# reconciles them:
#
#   * A description present on one side and absent (placeholder `-`) on the
#     other is adopted -- prose is additive, and a branch that predates a row
#     is not an opinion about it.
#   * Two different descriptions for the same test are a genuine editorial
#     conflict: refused, naming the test and both wordings.
#   * Any remaining difference between the two regenerated sides is, by
#     construction, content the generator does not own: refused with the diff.
#     That check is what keeps this script honest as the generator grows --
#     it does not carry a list of "figures that are generated" to fall out of
#     date, it simply refuses to adopt anything regeneration cannot justify.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_RESOLVE_DOC_COUNTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# The read-only twin sources the generator, so this one source gives both
# _sync_doc_counts (regenerate) and _check_test_md_drift (verify), plus the
# catalog-row primitives -- no third copy of the parsing rules.
# shellcheck source=script/test/check_test_md_drift.sh
source "${_RESOLVE_DOC_COUNTS_DIR}/check_test_md_drift.sh"

# Conflict-marker line shapes, as git writes them: the two-way pair, the
# diff3 base section, and the separator.
_RESOLVE_MARKER_RE='^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)([[:space:]]|$)'
_RESOLVE_SEP_RE='^=======$'

# _resolve_err <message> -- diagnostic to stderr. Block-redirected rather than
# a bare `printf ... >&2`: this is a standalone, log.sh-free CI tool (same
# rationale class as check_test_md_drift.sh) and the bare-stderr lint scans
# script/test/.
_resolve_err() {
  {
    printf 'resolve-doc-counts: %s\n' "$1"
  } >&2
}

# _resolve_doc_counts_root <root> -- print <root> unchanged after checking it
# is absolute and exists; fail naming it otherwise.
#
# A relative root is REFUSED rather than resolved. The reconciliation below
# copies doc/test into two temp dirs and symlinks the spec trees in from
# <root>: a relative target is recorded relative to the TEMP dir, every spec
# glob then misses, every count comes back 0 -- and 0 == 0 on both sides
# reconciles perfectly. The failure mode of guessing here is a confidently
# resolved, entirely wrong tree, so the caller is told to be explicit.
_resolve_doc_counts_root() {
  local _root="${1:-}"
  if [[ "${_root}" != /* ]]; then
    _resolve_err "scan root '${_root}' is relative -- pass an ABSOLUTE path. The spec trees are symlinked into a temp dir here, so a relative root resolves against that temp dir and every count silently becomes 0."
    return 1
  fi
  if [[ ! -d "${_root}" ]]; then
    _resolve_err "scan root '${_root}' does not exist or is not a directory."
    return 1
  fi
  printf '%s\n' "${_root}"
}

# _resolve_conflicted_docs <root> -- the doc/test/*.md files that still carry
# conflict markers, one per line.
_resolve_conflicted_docs() {
  local _root="$1" _doc
  for _doc in "${_root}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    if grep -qE -e "${_RESOLVE_MARKER_RE}" -e "${_RESOLVE_SEP_RE}" "${_doc}"; then
      printf '%s\n' "${_doc}"
    fi
  done
}

# _resolve_assert_no_markers <root> -- fail, naming file and line, if any
# doc/test/*.md still carries a conflict marker. Post-condition check: the
# collapse is meant to be total, and a survivor means it was not.
_resolve_assert_no_markers() {
  local _root="$1" _doc _hits _rel _hit _rc=0
  for _doc in "${_root}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    _hits="$(grep -nE -e "${_RESOLVE_MARKER_RE}" -e "${_RESOLVE_SEP_RE}" \
      "${_doc}" || true)"
    [[ -n "${_hits}" ]] || continue
    _rel="${_doc#"${_root}"/}"
    while IFS= read -r _hit; do
      _resolve_err "conflict marker survived at ${_rel}:${_hit%%:*}"
    done <<< "${_hits}"
    _rc=1
  done
  return "${_rc}"
}

# _resolve_collapse <file> <ours|theirs> -- <file> with the conflict regions
# reduced to the named side, on stdout. The diff3 base section is dropped
# whichever side is kept.
_resolve_collapse() {
  local _file="$1" _side="$2"
  awk -v side="${_side}" '
    /^<<<<<<<([ \t]|$)/ { state = 1; next }
    /^\|\|\|\|\|\|\|([ \t]|$)/ { state = 2; next }
    /^=======$/ { state = 3; next }
    /^>>>>>>>([ \t]|$)/ { state = 0; next }
    {
      if (state == 0 \
          || (state == 1 && side == "ours") \
          || (state == 3 && side == "theirs")) {
        print
      }
    }
  ' "${_file}"
}

# _resolve_build_side <root> <dest> <side> <conflicted-doc>... -- a scratch
# tree holding <root>/doc/test with the conflicted docs collapsed to <side>,
# and the spec trees symlinked in so the generator's globs resolve.
_resolve_build_side() {
  local _root="$1" _dest="$2" _side="$3"
  shift 3
  mkdir -p "${_dest}/doc"
  cp -R "${_root}/doc/test" "${_dest}/doc/test"
  ln -s "${_root}/test" "${_dest}/test"
  [[ -d "${_root}/dist" ]] && ln -s "${_root}/dist" "${_dest}/dist"
  local _doc _base
  for _doc in "$@"; do
    _base="$(basename -- "${_doc}")"
    _resolve_collapse "${_doc}" "${_side}" > "${_dest}/doc/test/${_base}"
  done
  return 0
}

# _resolve_placeholder <desc> -- true when <desc> carries no information, so
# the other side's wording can be adopted without overruling anyone.
_resolve_placeholder() {
  [[ -z "$1" || "$1" == '-' ]]
}

# _resolve_merge_descriptions <ours-root> <theirs-root> <out-mapvar> --
# reconcile the catalog descriptions of the two regenerated sides into
# <out-mapvar>. Fails, naming every offender, when the two sides describe the
# same test differently: that is an editorial decision, not derived data, and
# it is the one thing this script must never quietly pick a winner for.
_resolve_merge_descriptions() {
  local _ours="$1" _theirs="$2"
  local -n _resolve_merge_out="$3"
  local -A _resolve_d_ours=() _resolve_d_theirs=()
  local _doc _key _o _t _bad=0

  for _doc in "${_ours}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] && _catalog_collect_descriptions "${_ours}" "${_doc}" \
      _resolve_d_ours
  done
  for _doc in "${_theirs}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] && _catalog_collect_descriptions "${_theirs}" "${_doc}" \
      _resolve_d_theirs
  done

  for _key in "${!_resolve_d_ours[@]}" "${!_resolve_d_theirs[@]}"; do
    [[ -n "${_resolve_merge_out[${_key}]+x}" ]] && continue
    _o="${_resolve_d_ours[${_key}]:-}"
    _t="${_resolve_d_theirs[${_key}]:-}"
    if [[ "${_o}" == "${_t}" ]]; then
      _resolve_merge_out["${_key}"]="${_o}"
    elif _resolve_placeholder "${_o}"; then
      _resolve_merge_out["${_key}"]="${_t}"
    elif _resolve_placeholder "${_t}"; then
      _resolve_merge_out["${_key}"]="${_o}"
    else
      _resolve_err "both sides describe ${_key%%$'\t'*} test '${_key#*$'\t'}' differently -- ours: '${_o}' / theirs: '${_t}'. Pick the wording by hand, then re-run."
      _bad=1
    fi
  done
  return "${_bad}"
}

# _resolve_doc_counts [root] -- the whole flow. See the file header for the
# reconciliation contract.
_resolve_doc_counts() {
  local _root
  _root="$(_resolve_doc_counts_root "${1:-}")" || return 1

  if [[ ! -d "${_root}/doc/test" ]]; then
    _resolve_err "no doc/test/ under scan root ${_root} -- nothing to resolve."
    return 1
  fi

  local -a _conflicted=()
  mapfile -t _conflicted < <(_resolve_conflicted_docs "${_root}")

  if (( ${#_conflicted[@]} == 0 )); then
    printf 'resolve-doc-counts: no conflicted doc/test/*.md under %s -- verifying the tree anyway.\n' \
      "${_root}"
    _check_test_md_drift "${_root}" || return 1
    printf 'resolve-doc-counts: doc/test counts are in sync under %s\n' \
      "${_root}/doc/test"
    return 0
  fi

  local _doc
  for _doc in "${_conflicted[@]}"; do
    printf 'resolve-doc-counts: conflicted %s\n' "${_doc#"${_root}"/}"
  done

  local _ours _theirs _rc=0
  _ours="$(mktemp -d)" || return 1
  if ! _theirs="$(mktemp -d)"; then
    rm -rf "${_ours}"
    return 1
  fi

  _resolve_reconcile "${_root}" "${_ours}" "${_theirs}" "${_conflicted[@]}" \
    || _rc=1
  rm -rf "${_ours}" "${_theirs}"
  (( _rc == 0 )) || return 1

  _resolve_assert_no_markers "${_root}" || return 1

  if ! _check_test_md_drift "${_root}"; then
    _resolve_err "the drift gate is unhappy after regeneration -- the tree was rewritten but NOTHING was staged. Fix the reported drift, then re-run."
    return 1
  fi

  _resolve_stage "${_root}" "${_conflicted[@]}" || return 1
  printf 'resolve-doc-counts: resolved %s doc/test file(s) under %s\n' \
    "${#_conflicted[@]}" "${_root}"
}

# _resolve_reconcile <root> <ours-dir> <theirs-dir> <conflicted>... -- build
# both collapses, regenerate both, reconcile, and write the result back into
# <root>/doc/test. Split out of _resolve_doc_counts so the scratch dirs get
# cleaned up on every exit path.
_resolve_reconcile() {
  local _root="$1" _ours="$2" _theirs="$3"
  shift 3
  local -a _conflicted=( "$@" )

  _resolve_build_side "${_root}" "${_ours}" ours "${_conflicted[@]}" || return 1
  _resolve_build_side "${_root}" "${_theirs}" theirs "${_conflicted[@]}" \
    || return 1
  _sync_doc_counts "${_ours}" >/dev/null
  _sync_doc_counts "${_theirs}" >/dev/null

  local -A _merged=()
  _resolve_merge_descriptions "${_ours}" "${_theirs}" _merged || return 1

  local _doc _base
  for _doc in "${_ours}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] && _catalog_apply_descriptions "${_ours}" "${_doc}" _merged
  done
  for _doc in "${_theirs}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] && _catalog_apply_descriptions "${_theirs}" "${_doc}" \
      _merged
  done

  local _diff
  if ! _diff="$(diff -ru "${_ours}/doc/test" "${_theirs}/doc/test" 2>/dev/null)"; then
    {
      printf 'resolve-doc-counts: the two sides do not agree on content the generator does not derive, so no collapse can be justified by regeneration. Resolve these by hand:\n'
      printf '%s\n' "${_diff}"
    } >&2
    return 1
  fi

  for _doc in "${_theirs}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    _base="$(basename -- "${_doc}")"
    cp -- "${_doc}" "${_root}/doc/test/${_base}"
  done
}

# _resolve_stage <root> <file>... -- mark the resolved files merged, so the
# merge can be committed without a second manual `git add`. A non-git root
# (a fixture tree) is simply left alone.
_resolve_stage() {
  local _root="$1"
  shift
  git -C "${_root}" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local _doc
  for _doc in "$@"; do
    git -C "${_root}" add -- "${_doc}" || return 1
  done
}

main() {
  local _root="${1:-}"
  if [[ -z "${_root}" ]]; then
    _root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  fi
  _resolve_doc_counts "${_root}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
