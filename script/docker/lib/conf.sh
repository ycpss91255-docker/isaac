#!/usr/bin/env bash
#
# conf.sh - INI section dump helper.
#
# Provides _dump_conf_section for emitting key=value lines from a named
# INI section. Used by setup.sh's section reader and by
# config_summary.sh's _print_config_summary section-by-section dump.
#
# Split out from _lib.sh in #284.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_CONF_SOURCED=1

# _dump_conf_section <file> <section>
#
# Emit key=value lines from the named INI section of <file>, skipping
# blank lines and comments. Stops at the next section header or EOF.
# Silent on missing file or missing section.
_dump_conf_section() {
  local _file="$1" _sec="$2"
  [[ -f "${_file}" ]] || return 0
  # Filter out empty values (`key =` / `key = `). An empty value means
  # "use the Docker / template default" and is noise in the summary.
  # Populated keys print as-is; cleared list slots (arg_N = / mount_N =)
  # are also hidden so they don't show up as blank rows.
  awk -v sec="[${_sec}]" '
    $0 == sec { in_sec=1; next }
    /^\[/ && in_sec { in_sec=0 }
    in_sec && /^[[:space:]]*#/ { next }
    in_sec && /^[[:space:]]*$/ { next }
    in_sec && /^[[:space:]]*[^#=]+=[[:space:]]*$/ { next }
    in_sec { print }
  ' "${_file}"
}

# _parse_ini_section <file> <section> <keys_outvar> <values_outvar>
#
# Reads one section [<section>] from <file> into parallel arrays.
# Skips comments (#) and empty lines. Trims key/value whitespace.
# If a key is defined both in <base_path>/setup.conf and in .base/setup.conf,
# caller should use _load_setup_conf which handles the merge (replace strategy).
#
# Moved from script/docker/wrapper/setup.sh in #402 (PR-B) so init.sh
# can call _collect_logging (lib/conf_logging.sh) -> _parse_ini_section
# without sourcing setup.sh; init.sh only pulls in lib/_lib.sh.
_parse_ini_section() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _pis_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _pis_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _pis_keys=()
  _pis_values=()
  [[ -f "${_file}" ]] || return 0

  local __pis_line __pis_current="" __pis_k __pis_v
  while IFS= read -r __pis_line || [[ -n "${__pis_line}" ]]; do
    [[ -z "${__pis_line}" || "${__pis_line}" =~ ^[[:space:]]*# ]] && continue

    # Trim
    __pis_line="${__pis_line#"${__pis_line%%[![:space:]]*}"}"
    __pis_line="${__pis_line%"${__pis_line##*[![:space:]]}"}"
    [[ -z "${__pis_line}" ]] && continue

    # Section header
    if [[ "${__pis_line}" =~ ^\[(.+)\]$ ]]; then
      __pis_current="${BASH_REMATCH[1]}"
      continue
    fi

    # Only collect entries for the requested section
    [[ "${__pis_current}" == "${_section}" ]] || continue

    # Require key = value
    [[ "${__pis_line}" != *=* ]] && continue
    __pis_k="${__pis_line%%=*}"
    __pis_v="${__pis_line#*=}"
    __pis_k="${__pis_k#"${__pis_k%%[![:space:]]*}"}"
    __pis_k="${__pis_k%"${__pis_k##*[![:space:]]}"}"
    __pis_v="${__pis_v#"${__pis_v%%[![:space:]]*}"}"
    __pis_v="${__pis_v%"${__pis_v##*[![:space:]]}"}"

    _pis_keys+=("${__pis_k}")
    _pis_values+=("${__pis_v}")
  done < "${_file}"
}
