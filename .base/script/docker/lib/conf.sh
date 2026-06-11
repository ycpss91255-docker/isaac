#!/usr/bin/env bash
#
# conf.sh - INI read/write primitives for setup.conf.
#
# The single shared home for setup.conf I/O:
#   _dump_conf_section    - emit key=value lines from one section
#   _load_setup_conf_full - parse every section into namespaced arrays
#   _parse_ini_section    - parse one section into flat arrays
#   _write_setup_conf     - rewrite from a template + overrides,
#                           preserving comments and ordering
#   _upsert_conf_value    - update/append a single key in place
#
# Sourced via _lib.sh (the umbrella loader) and directly by
# config_summary.sh and _tui_conf.sh. _parse_ini_section moved here
# from setup.sh in #402 (PR-B); the full-file tokenizer + the writers
# moved here from _tui_conf.sh in #411 so every INI read/write path
# shares one module instead of the core CLI reaching into the TUI lib.

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

# ════════════════════════════════════════════════════════════════════
# INI reader (single-pass tokenizer + projections)
# ════════════════════════════════════════════════════════════════════

# _ini_tokenize <file> <sections_out> <entry_sections_out> <keys_out> <values_out>
#
# Single-pass INI tokenizer shared by the public readers below. Walks
# <file> once and populates four parallel-ish arrays:
#   sections[]        - unique section names, first-appearance order
#   entry_sections[i] - the section each key/value entry belongs to
#   keys[i]           - raw key, NOT namespaced (may contain '.', e.g.
#                       the per-stage override key `gui.mode`)
#   values[i]         - trimmed value
# entry_sections / keys / values are index-aligned (one slot per entry);
# sections[] is the deduped header list and is independent.
#
# Skips comments (#) and blank lines, trims key/value whitespace, and
# ignores key=value lines that appear before any section header. Keeping
# the section per entry (instead of pre-joining `<section>.<key>`) lets
# _parse_ini_section match sections exactly even when keys themselves
# contain '.', which a namespaced-string split cannot do unambiguously.
_ini_tokenize() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _it_sections="${2:?"${FUNCNAME[0]}: missing sections outvar"}"
  local -n _it_entry_sects="${3:?"${FUNCNAME[0]}: missing entry-sections outvar"}"
  local -n _it_keys="${4:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _it_values="${5:?"${FUNCNAME[0]}: missing values outvar"}"

  _it_sections=()
  _it_entry_sects=()
  _it_keys=()
  _it_values=()
  [[ -f "${_file}" ]] || return 0

  local __it_line __it_current="" __it_k __it_v
  local -A __it_seen=()
  while IFS= read -r __it_line || [[ -n "${__it_line}" ]]; do
    # Strip comments / blanks before trimming (comment marker may be
    # preceded by leading whitespace).
    [[ -z "${__it_line}" || "${__it_line}" =~ ^[[:space:]]*# ]] && continue

    # Trim surrounding whitespace.
    __it_line="${__it_line#"${__it_line%%[![:space:]]*}"}"
    __it_line="${__it_line%"${__it_line##*[![:space:]]}"}"
    [[ -z "${__it_line}" ]] && continue

    # Section header.
    if [[ "${__it_line}" =~ ^\[(.+)\]$ ]]; then
      __it_current="${BASH_REMATCH[1]}"
      if [[ -z "${__it_seen[${__it_current}]:-}" ]]; then
        _it_sections+=("${__it_current}")
        __it_seen[${__it_current}]=1
      fi
      continue
    fi

    # Require key = value inside a section.
    [[ -z "${__it_current}" || "${__it_line}" != *=* ]] && continue
    __it_k="${__it_line%%=*}"
    __it_v="${__it_line#*=}"
    __it_k="${__it_k#"${__it_k%%[![:space:]]*}"}"
    __it_k="${__it_k%"${__it_k##*[![:space:]]}"}"
    __it_v="${__it_v#"${__it_v%%[![:space:]]*}"}"
    __it_v="${__it_v%"${__it_v##*[![:space:]]}"}"

    _it_entry_sects+=("${__it_current}")
    _it_keys+=("${__it_k}")
    _it_values+=("${__it_v}")
  done < "${_file}"
}

# _load_setup_conf_full <file> <sections_outvar> <keys_outvar> <values_outvar>
#
# Reads an INI file into three parallel arrays:
#   sections[] — unique section names in first-appearance order
#   keys[i]    — "<section>.<key>" (namespaced)
#   values[i]  — trimmed value
#
# Comments and blank lines are skipped. Thin projection over
# _ini_tokenize that re-joins each entry's section and key.
_load_setup_conf_full() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _lsf_sections="${2:?}"
  local -n _lsf_keys="${3:?}"
  local -n _lsf_values="${4:?}"

  _lsf_sections=()
  _lsf_keys=()
  _lsf_values=()
  [[ -f "${_file}" ]] || return 0

  local -a __lsf_s=() __lsf_es=() __lsf_k=() __lsf_v=()
  _ini_tokenize "${_file}" __lsf_s __lsf_es __lsf_k __lsf_v

  local __lsf_i
  for (( __lsf_i = 0; __lsf_i < ${#__lsf_s[@]}; __lsf_i++ )); do
    _lsf_sections+=("${__lsf_s[__lsf_i]}")
  done
  for (( __lsf_i = 0; __lsf_i < ${#__lsf_k[@]}; __lsf_i++ )); do
    _lsf_keys+=("${__lsf_es[__lsf_i]}.${__lsf_k[__lsf_i]}")
    _lsf_values+=("${__lsf_v[__lsf_i]}")
  done
}

# _parse_ini_section <file> <section> <keys_outvar> <values_outvar>
#
# Reads one section [<section>] from <file> into parallel flat arrays
# (raw keys, no namespace). Thin projection over _ini_tokenize keeping
# only entries whose owning section equals <section> EXACTLY.
#
# Exact matching is load-bearing: [logging] and [logging.web] are
# distinct sections, and per-stage sections carry dotted keys like
# `gui.mode` under [stage:NAME]. Because _ini_tokenize tracks the owning
# section per entry (rather than a lossy "<section>.<key>" string), both
# cases resolve correctly with no dot heuristics.
#
# Skips comments/blanks, trims whitespace, and preserves duplicate keys
# plus reopened sections in file order. Silent (empty arrays) on missing
# file or absent section.
_parse_ini_section() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _pis_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _pis_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _pis_keys=()
  _pis_values=()
  [[ -f "${_file}" ]] || return 0

  local -a __pis_s=() __pis_es=() __pis_k=() __pis_v=()
  _ini_tokenize "${_file}" __pis_s __pis_es __pis_k __pis_v

  local __pis_i
  for (( __pis_i = 0; __pis_i < ${#__pis_k[@]}; __pis_i++ )); do
    [[ "${__pis_es[__pis_i]}" == "${_section}" ]] || continue
    _pis_keys+=("${__pis_k[__pis_i]}")
    _pis_values+=("${__pis_v[__pis_i]}")
  done
}

# ════════════════════════════════════════════════════════════════════
# INI writer (comment-preserving)
# ════════════════════════════════════════════════════════════════════

# _write_setup_conf <dst_file> <template_src> <sections_ref> <keys_ref> <values_ref> [<removed_keys>]
#
# Copies <template_src> to <dst_file> line-by-line. `key = value` lines
# whose namespaced key `<section>.<key>` appears in the overrides arrays
# are replaced with `key = <override>`. Keys present in the space-
# separated <removed_keys> argument are dropped entirely (line removed).
# Comments, blank lines and untouched keys are preserved verbatim.
#
# Extra override entries that do not correspond to any template line
# (e.g. Add rule_5 / mount_5) are appended to the end of their section.
_write_setup_conf() {
  local _dst="${1:?}"
  local _tpl="${2:?}"
  local -n _wsc_sections="${3:?}"
  local -n _wsc_keys="${4:?}"
  local -n _wsc_values="${5:?}"
  local _removed_keys="${6:-}"

  [[ -f "${_tpl}" ]] || return 1

  local -A __override=()
  local -A __emitted=()
  local -A __removed=()
  local i
  for (( i=0; i<${#_wsc_keys[@]}; i++ )); do
    __override["${_wsc_keys[i]}"]="${_wsc_values[i]}"
  done
  for i in ${_removed_keys}; do
    __removed["${i}"]=1
  done
  # Silence unused-nameref warning; the declaration is part of the API.
  : "${_wsc_sections[*]:-}"

  # #187: setup_tui's `_commit_and_setup` passes the same path for dst
  # and tpl when the per-repo file already exists. Truncating dst before
  # reading from tpl (the original `: > "${_dst}"` followed by `done <
  # "${_tpl}"`) collapses the read to zero lines under that aliasing and
  # silently destroys the user's config. Slurp the template into memory
  # first so the subsequent truncate-and-rewrite is safe regardless of
  # whether dst and tpl are distinct files.
  local -a __tpl_lines=()
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    __tpl_lines+=("${__line}")
  done < "${_tpl}"

  local __current="" __k __rest
  : > "${_dst}"
  for __line in "${__tpl_lines[@]}"; do
    if [[ "${__line}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      # Flush not-yet-emitted overrides belonging to the section we are
      # about to leave (those are "added" keys with no template line).
      if [[ -n "${__current}" ]]; then
        local __ovk
        for __ovk in "${!__override[@]}"; do
          if [[ "${__ovk}" == "${__current}."* && -z "${__emitted[${__ovk}]:-}" ]]; then
            [[ -n "${__removed[${__ovk}]+x}" ]] && { __emitted[${__ovk}]=1; continue; }
            printf '%s = %s\n' "${__ovk#"${__current}".}" "${__override[${__ovk}]}" >> "${_dst}"
            __emitted[${__ovk}]=1
          fi
        done
        # Separate appended keys from the next section header with a blank line
        printf '\n' >> "${_dst}"
      fi
      __current="${BASH_REMATCH[1]}"
      printf '%s\n' "${__line}" >> "${_dst}"
      continue
    fi
    if [[ -z "${__line}" || "${__line}" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "${__line}" >> "${_dst}"
      continue
    fi
    if [[ -n "${__current}" && "${__line}" == *=* ]]; then
      __k="${__line%%=*}"
      __rest="${__k#"${__k%%[![:space:]]*}"}"
      __rest="${__rest%"${__rest##*[![:space:]]}"}"
      local __nskey="${__current}.${__rest}"
      if [[ -n "${__removed[${__nskey}]+x}" ]]; then
        __emitted[${__nskey}]=1
        continue
      fi
      if [[ -n "${__override[${__nskey}]+x}" ]]; then
        printf '%s = %s\n' "${__rest}" "${__override[${__nskey}]}" >> "${_dst}"
        __emitted[${__nskey}]=1
        continue
      fi
    fi
    printf '%s\n' "${__line}" >> "${_dst}"
  done

  # Flush leftovers belonging to the final section
  if [[ -n "${__current}" ]]; then
    local __ovk
    for __ovk in "${!__override[@]}"; do
      if [[ "${__ovk}" == "${__current}."* && -z "${__emitted[${__ovk}]:-}" ]]; then
        [[ -n "${__removed[${__ovk}]+x}" ]] && continue
        printf '%s = %s\n' "${__ovk#"${__current}".}" "${__override[${__ovk}]}" >> "${_dst}"
        __emitted[${__ovk}]=1
      fi
    done
  fi

  # Append NEW sections — overrides whose `<section>.<key>` namespace
  # references a section never seen in the template. Per-stage
  # `[stage:NAME]` sections (#220) are the typical case: template's
  # setup.conf carries no per-repo stage overrides, so the first time
  # a user adds `[stage:headless]` via TUI Save the section is brand
  # new and would otherwise be silently dropped here.
  #
  # Section-name extraction uses the `<section>.<key>` split rule
  # established by `_load_setup_conf_full`: section name has no `.`,
  # key may. `stage:headless.gui.mode` → section=stage:headless,
  # key=gui.mode.
  local -A __template_sections=()
  local __l
  for __l in "${__tpl_lines[@]}"; do
    if [[ "${__l}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      __template_sections["${BASH_REMATCH[1]}"]=1
    fi
  done

  # Walk override keys in the order the caller provided them so new
  # sections appear in user-input order (predictable for tests + Save
  # output diffs). Bash associative-array iteration is unspecified.
  local -a __new_section_order=()
  local -A __new_section_seen=()
  local _wsc_i
  for (( _wsc_i = 0; _wsc_i < ${#_wsc_keys[@]}; _wsc_i++ )); do
    local __ovk_key="${_wsc_keys[_wsc_i]}"
    local __ovk_sect="${__ovk_key%%.*}"
    if [[ -z "${__template_sections[${__ovk_sect}]:-}" ]] \
       && [[ -z "${__new_section_seen[${__ovk_sect}]:-}" ]]; then
      __new_section_order+=("${__ovk_sect}")
      __new_section_seen[${__ovk_sect}]=1
    fi
  done

  # Emit each new section + its keys (skip emitted / removed entries
  # so re-saves don't double-write).
  local __ns
  for __ns in "${__new_section_order[@]}"; do
    printf '\n[%s]\n' "${__ns}" >> "${_dst}"
    for (( _wsc_i = 0; _wsc_i < ${#_wsc_keys[@]}; _wsc_i++ )); do
      local __key="${_wsc_keys[_wsc_i]}"
      [[ "${__key}" == "${__ns}."* ]] || continue
      [[ -n "${__emitted[${__key}]:-}" ]] && continue
      [[ -n "${__removed[${__key}]+x}" ]] && continue
      printf '%s = %s\n' "${__key#"${__ns}".}" "${_wsc_values[_wsc_i]}" >> "${_dst}"
      __emitted[${__key}]=1
    done
  done
}

# ════════════════════════════════════════════════════════════════════
# Single-key upsert (used by setup.sh for WS_PATH writeback)
# ════════════════════════════════════════════════════════════════════

# _upsert_conf_value <file> <section> <key> <value>
#
# Updates the given key's value within the given section in-place,
# preserving all other content. If the key does not exist under the
# section, appends it to the end of the section. If the section does
# not exist, appends a new section + key at end of file.
_upsert_conf_value() {
  local _file="${1:?}"
  local _section="${2:?}"
  local _key="${3:?}"
  local _value="${4-}"

  [[ -f "${_file}" ]] || { printf "[_upsert_conf_value] file missing: %s\n" "${_file}" >&2; return 1; }

  local _tmp
  _tmp="$(mktemp "${_file}.XXXXXX")"

  local __line __current="" __k __rest __matched=0 __in_sect=0 __sect_found=0
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    if [[ "${__line}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      # Leaving target section without finding key → append key before next section
      if (( __in_sect && !__matched )); then
        printf '%s = %s\n' "${_key}" "${_value}" >> "${_tmp}"
        __matched=1
      fi
      __current="${BASH_REMATCH[1]}"
      __in_sect=0
      if [[ "${__current}" == "${_section}" ]]; then
        __in_sect=1
        __sect_found=1
      fi
      printf '%s\n' "${__line}" >> "${_tmp}"
      continue
    fi
    if (( __in_sect )) && [[ -n "${__line}" ]] && [[ "${__line}" != *[[:space:]]\#* ]] \
       && [[ "${__line}" != \#* ]] && [[ "${__line}" == *=* ]]; then
      __k="${__line%%=*}"
      __rest="${__k#"${__k%%[![:space:]]*}"}"
      __rest="${__rest%"${__rest##*[![:space:]]}"}"
      if [[ "${__rest}" == "${_key}" ]]; then
        printf '%s = %s\n' "${_key}" "${_value}" >> "${_tmp}"
        __matched=1
        continue
      fi
    fi
    printf '%s\n' "${__line}" >> "${_tmp}"
  done < "${_file}"

  # Still in target section at EOF and key not matched → append
  if (( __in_sect && !__matched )); then
    printf '%s = %s\n' "${_key}" "${_value}" >> "${_tmp}"
    __matched=1
  fi

  # Section not found at all → append new section + key
  if (( !__sect_found )); then
    printf '\n[%s]\n%s = %s\n' "${_section}" "${_key}" "${_value}" >> "${_tmp}"
  fi

  mv "${_tmp}" "${_file}"
}
