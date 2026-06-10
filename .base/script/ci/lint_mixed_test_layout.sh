#!/usr/bin/env bash
#
# lint_mixed_test_layout.sh - WARN when a test/<category>/ directory mixes
# files from more than one test runner at the same level (#495).
#
# ADR-00000004 (#473) establishes the convention: when a test/<category>/
# directory holds files from more than one runner (e.g. `.bats` + `test_*.py`),
# segregate them into test/<category>/<tool>/ subdirectories. This lint is the
# automated guard for that convention. It is WARNING-only and non-blocking:
# a mixed state is sometimes a legitimate mid-migration intermediate, so the
# script always exits 0 and only emits a `_log_warn` per offending category.
#
# Downstream repos inherit this via the .base/ subtree, so the convention is
# enforced everywhere base's ci.sh runs the lint phase (_run_shellcheck).
#
# Exit: always 0 (warnings are advisory). Usage error -> 2.

set -euo pipefail

_LMTL_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=script/docker/lib/log.sh
# shellcheck disable=SC1091
source "${_LMTL_SELF_DIR}/../docker/lib/log.sh"

# _runner_family <filename> -> echoes the runner family for a test file name,
# or empty for a non-test file. Extend here when a new runner is adopted.
_runner_family() {
  case "${1}" in
    *.bats)              echo "bats" ;;
    test_*.py|*_test.py) echo "python" ;;
    *)                   echo "" ;;
  esac
}

# _lint_mixed_test_layout <repo_root> -> WARN per test/<category>/ that mixes
# runner families directly at its top level. Subdirectories are not scanned
# here (test/<category>/<tool>/ is exactly the segregated target state).
_lint_mixed_test_layout() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _dir _cat _f _fam
  shopt -s nullglob
  for _dir in "${_root}"/test/*/; do
    [[ -d "${_dir}" ]] || continue
    _cat="$(basename "${_dir}")"
    local -A _families=()
    for _f in "${_dir}"*; do
      [[ -f "${_f}" ]] || continue
      _fam="$(_runner_family "$(basename "${_f}")")"
      [[ -n "${_fam}" ]] && _families["${_fam}"]=1
    done
    if (( ${#_families[@]} > 1 )); then
      _log_warn ci ci_mixed_test_layout \
        "display=test/${_cat}/ mixes test runners (${!_families[*]}) at one level; segregate into test/${_cat}/<tool>/ subdirs per ADR-00000004 (#473)."
    fi
  done
  return 0
}

main() {
  local _root="${1:-$(cd -- "${_LMTL_SELF_DIR}/../.." && pwd -P)}"
  [[ -d "${_root}" ]] || { _log_err ci ci_lint_bad_root "display=not a directory: ${_root}"; exit 2; }
  _lint_mixed_test_layout "${_root}"
}

# Guard: only run main when executed directly, not when sourced (for testing).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
