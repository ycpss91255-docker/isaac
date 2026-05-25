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
