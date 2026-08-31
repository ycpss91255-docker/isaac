#!/usr/bin/env bash
#
# check_test_md_drift.sh - validate that doc/test/*.md count figures match
# the specs. The read-only twin of sync-doc-counts.sh: it re-derives every
# count from the SAME single source of truth (`grep -c '^@test'` per spec,
# via sync-doc-counts.sh's _sync_doc_counts) and exits non-zero when the
# committed docs have drifted -- so a PR that adds or removes a @test without
# running `just test sync-docs` fails the gate instead of shipping stale
# numbers. ISTQB taxonomy (ADR-00000018): unit / integration / system /
# acceptance levels + the shipped smoke type; empty level dirs count 0.
#
# Usage:
#   ./script/test/check_test_md_drift.sh            # check REPO_ROOT/doc/test
#   ./script/test/check_test_md_drift.sh <root>     # check <root>/doc/test
#
# <root> may be relative or absolute -- it is resolved to an absolute path
# before use, so both call styles give the same verdict (the sibling
# sync-doc-counts.sh accepts a relative root, so passing `.` to both is the
# natural thing to do).
#
# Exit status: 0 = in sync; 1 = drift (the offending unified diff is printed
# to stderr), or an unusable scan root (missing, no doc/test/, no specs).
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

_CHECK_DRIFT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# Reuse the generator as the single source of truth: rather than re-implement
# the count parsing (and risk the validator and generator disagreeing), run
# the real _sync_doc_counts against a throwaway copy of doc/test and diff the
# result against the committed docs. Identical output => in sync.
# shellcheck source=script/test/sync-doc-counts.sh
source "${_CHECK_DRIFT_DIR}/sync-doc-counts.sh"

# Spec trees the count generator walks, root-relative. Used only by the
# "did the scan root actually yield any specs" guard below: if NONE of them
# matches, every level would compare 0 against 0 and the gate would pass
# vacuously -- exactly what a relocation of the spec tree must not do.
_CHECK_DRIFT_SPEC_GLOBS=(
  'test/bats/**/*_spec.bats'
  'dist/test/bats/smoke/**/*.bats'
)

# _check_drift_err <message> -- diagnostic to stderr. Block-redirected rather
# than a bare `printf ... >&2` because this script is a standalone, log.sh-free
# CI tool (same rationale class as drivers/coverage_gate.sh) and the bare-stderr
# lint scans script/test/.
_check_drift_err() {
  {
    printf 'check_test_md_drift: %s\n' "$1"
  } >&2
}

# _check_drift_resolve_root <root> -- print <root> as an absolute,
# symlink-resolved path; fail (naming <root>) when it does not exist.
#
# Why this is not optional: the comparison below copies doc/test into a temp
# dir and symlinks the spec trees in from <root>. A relative <root> would be
# recorded as a relative symlink target, i.e. resolved against the TEMP dir on
# that hop -- every spec glob then misses and every count comes back 0, so the
# gate reports total drift instead of erroring. sync-doc-counts.sh has no such
# hop, which is why it takes a relative root fine and the asymmetry surprises.
_check_drift_resolve_root() {
  local _root="$1" _abs
  if ! _abs="$(cd -- "${_root}" 2>/dev/null && pwd -P)"; then
    _check_drift_err "scan root '${_root}' does not exist or is not a directory."
    return 1
  fi
  printf '%s\n' "${_abs}"
}

# _check_drift_count_specs <root> -- number of spec files under <root> across
# _CHECK_DRIFT_SPEC_GLOBS.
_check_drift_count_specs() {
  local _root="$1" _glob _f _n=0
  # globstar for the `**` segments; saved/restored so sourcing this lib does
  # not leak the option to the caller (same idiom as _dir_test_count).
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _glob in "${_CHECK_DRIFT_SPEC_GLOBS[@]}"; do
    for _f in "${_root}"/${_glob}; do
      [[ -f "${_f}" ]] && _n=$(( _n + 1 ))
    done
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_n}"
}

# _check_test_md_drift [root] -- return 0 when <root>/doc/test/*.md already
# match what _sync_doc_counts would generate, 1 (with a diff on stderr) when
# they drift. Non-mutating: the generator runs against a temp copy; the spec
# source trees (test/, dist/) are symlinked in so their globs resolve without
# being copied.
#
# [root] may be relative; it is resolved to an absolute path first. An
# unusable scan root (missing, no doc/test/, no spec files) is an ERROR, not
# an observation of "0 tests everywhere": reporting zeros would either look
# like total drift (the caller concludes their change broke every count) or,
# once the docs said 0 too, pass vacuously.
_check_test_md_drift() {
  local _root="${1:-${REPO_ROOT:-.}}"

  local _abs
  _abs="$(_check_drift_resolve_root "${_root}")" || return 1
  _root="${_abs}"

  if [[ ! -d "${_root}/doc/test" ]]; then
    _check_drift_err \
      "no doc/test/ under scan root ${_root} -- nothing to validate, so the gate would pass vacuously."
    return 1
  fi

  local _specs
  _specs="$(_check_drift_count_specs "${_root}")"
  if (( _specs == 0 )); then
    _check_drift_err \
      "no spec files under scan root ${_root} (looked for ${_CHECK_DRIFT_SPEC_GLOBS[*]}) -- every count would compare 0 against 0. Point the gate at the repo root, or update the spec globs if the spec tree moved."
    return 1
  fi

  local _tmp
  _tmp="$(mktemp -d)" || return 1

  mkdir -p "${_tmp}/doc"
  cp -R "${_root}/doc/test" "${_tmp}/doc/test"
  ln -s "${_root}/test" "${_tmp}/test"
  [[ -d "${_root}/dist" ]] && ln -s "${_root}/dist" "${_tmp}/dist"

  _sync_doc_counts "${_tmp}" >/dev/null

  local _diff _rc=0
  _diff="$(diff -ru "${_root}/doc/test" "${_tmp}/doc/test" 2>/dev/null)" || _rc=1
  rm -rf "${_tmp}"

  if (( _rc != 0 )); then
    {
      printf 'doc/test count drift detected. Run: just test sync-docs (then commit):\n'
      printf '%s\n' "${_diff}"
    } >&2
    return 1
  fi
  return 0
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  # Resolve here too so the success line names the same absolute root the
  # comparison actually used, whatever the caller passed.
  local _abs
  _abs="$(_check_drift_resolve_root "${_root}")" || return 1
  if _check_test_md_drift "${_abs}"; then
    printf 'doc/test counts are in sync under %s\n' "${_abs}/doc/test"
    return 0
  fi
  return 1
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
