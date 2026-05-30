#!/usr/bin/env bash
#
# smoke.sh -- runtime image install-check (#430).
#
# Scans a directory for .so files and runs `ldd` on each. Fails if any
# library has a "not found" dependency, which catches missing runtime
# shared-library installs that the old bash-only smoke check missed
# (ros1_bridge#123: libboost_regex.so absent, runtime-test still passed).
#
# Usage: smoke.sh [SCAN_ROOT...]
#   SCAN_ROOT  Directory to scan recursively for .so files. Defaults to
#              /usr/local/lib and /opt/ros/*/lib when no args given.
#
# Exit: 0 = all libs link cleanly. 1 = at least one MISSING dep found.

set -uo pipefail

main() {
  local -a _roots=()
  if (( $# > 0 )); then
    _roots=("$@")
  else
    _roots=(/usr/local/lib /opt/ros/*/lib)
  fi

  local _exit=0 _root _so _ldd_out
  for _root in "${_roots[@]}"; do
    [[ -d "${_root}" ]] || continue
    while IFS= read -r -d '' _so; do
      _ldd_out="$(ldd "${_so}" 2>&1)" || continue
      if grep -q 'not found' <<< "${_ldd_out}"; then
        printf 'MISSING DEP: %s\n' "${_so}" >&2
        grep 'not found' <<< "${_ldd_out}" >&2
        _exit=1
      fi
    done < <(find "${_root}" -name '*.so*' -type f -print0 2>/dev/null)
  done
  return "${_exit}"
}

main "$@"
