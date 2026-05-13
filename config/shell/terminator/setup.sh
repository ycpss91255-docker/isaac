#!/usr/bin/env bash

# Only set strict mode when running directly
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

check_deps() {
  local -r _deps=("terminator")
  local _dep=""

  for _dep in "${_deps[@]}"; do
    if ! command -v "${_dep}" &> /dev/null; then
      printf "Error: %s is not installed." "${_dep}" >&2
      return 1
    fi
  done
  return 0
}

main() {
  local -r _username="${1:-"${USER:-$(id -un)}"}"
  local -r _usergroup="${2:-"$(id -gn "${_username}")"}"
  local -r _script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

  mkdir -p -- "${HOME}/.config/terminator"
  cp -r "${_script_path}/config" "${HOME}/.config/terminator/config"
  chown -R "${_username}":"${_usergroup}" "${HOME}/.config/terminator"
}

_entry_point() {
  if check_deps; then
    main "$@"
  else
    printf "Error: Missing dependencies." >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _entry_point "$@" || exit $?
fi
