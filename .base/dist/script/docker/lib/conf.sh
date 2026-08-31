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
# from setup.sh in (PR-B); the full-file tokenizer + the writers
# moved here from _tui_conf.sh in so every INI read/write path
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
# Opaque accessor interface
# ════════════════════════════════════════════════════════════════════
#
# Callers load a file once into a named handle and query it by
# (section, key) via the accessor verbs below, without touching the
# parallel-array representation or the `<section>.<key>` namespacing rule.
# A "handle" is just a name prefix; _conf_load creates the backing global
# arrays (`<handle>__es` / `<handle>__keys` / `<handle>__vals` +
# `<handle>__sects`) so the accessors can find them by prefix.

# _conf_load <file> <handle>
#
# Tokenize <file> once into the global arrays backing <handle>. Safe to
# call on a missing file (yields an empty handle).
_conf_load() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _h="${2:?"${FUNCNAME[0]}: missing handle"}"
  declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"
  local -n _cl_s="${_h}__sects" _cl_es="${_h}__es" _cl_k="${_h}__keys" _cl_v="${_h}__vals"
  _ini_tokenize "${_file}" _cl_s _cl_es _cl_k _cl_v
}

# _conf_get <handle> <section> <key> [default]
#
# Echo the value for <section>.<key> from <handle>, or [default] (empty
# if omitted) when absent. Last occurrence wins (override semantics).
_conf_get() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _def="${4-}"
  local -n _cg_es="${_h}__es" _cg_k="${_h}__keys" _cg_v="${_h}__vals"
  local _cg_i _cg_val="${_def}"
  for (( _cg_i = 0; _cg_i < ${#_cg_k[@]}; _cg_i++ )); do
    if [[ "${_cg_es[_cg_i]}" == "${_sec}" && "${_cg_k[_cg_i]}" == "${_key}" ]]; then
      _cg_val="${_cg_v[_cg_i]}"
    fi
  done
  printf '%s\n' "${_cg_val}"
}

# _conf_get_into <handle> <section> <key> <default> <outvar>
#
# Outvar variant of _conf_get: assign the value for <section>.<key> (or
# <default> when absent) to the caller's <outvar>, with no $() subshell.
# Same lookup + last-occurrence-wins semantics. Lets a hot resolver read many
# keys from one parsed handle without a fork per lookup.
_conf_get_into() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _def="${4-}"
  local -n _cgi_out="${5:?"${FUNCNAME[0]}: missing outvar"}"
  local -n _cgi_es="${_h}__es" _cgi_k="${_h}__keys" _cgi_v="${_h}__vals"
  local _cgi_i
  _cgi_out="${_def}"
  for (( _cgi_i = 0; _cgi_i < ${#_cgi_k[@]}; _cgi_i++ )); do
    if [[ "${_cgi_es[_cgi_i]}" == "${_sec}" && "${_cgi_k[_cgi_i]}" == "${_key}" ]]; then
      _cgi_out="${_cgi_v[_cgi_i]}"
    fi
  done
}

# _conf_sections <handle>
#
# Echo the handle's section names (deduped, first-appearance order), one
# per line.
_conf_sections() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local -n _cs_s="${_h}__sects"
  local _cs_i
  for (( _cs_i = 0; _cs_i < ${#_cs_s[@]}; _cs_i++ )); do
    printf '%s\n' "${_cs_s[_cs_i]}"
  done
}

# _conf_list <handle> <section>
#
# Echo the keys present in <section> from <handle>, one per line, in file
# order (duplicates preserved). Empty output for an absent section. Use to
# iterate list-style sections (e.g. volumes `mount_*`, environment `env_*`).
_conf_list() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _ls_es="${_h}__es" _ls_k="${_h}__keys"
  local _ls_i
  for (( _ls_i = 0; _ls_i < ${#_ls_k[@]}; _ls_i++ )); do
    [[ "${_ls_es[_ls_i]}" == "${_sec}" ]] && printf '%s\n' "${_ls_k[_ls_i]}"
  done
  return 0
}

# _conf_load_layers <handle> <file>...
#
# Load the section-replace merge of an arbitrary-length layer chain into
# <handle>. Files are given in INCREASING precedence (baseline first, the
# most local override last): for each section, the entries come wholesale
# from the HIGHEST-precedence layer that defines it (>=1 entry); layers
# below contribute nothing to that section. Sections no layer above defines
# keep the layer that did. Section order is the order the layers introduced
# them, lowest layer first.
#
# Section-replace rather than per-key merge is the chain's one rule, and it
# is structural: eight of the sections are `<prefix>_N` ordered lists, and a
# per-key merge would assemble one ordered list out of several layers, would
# offer no way to REMOVE an item, and would require the author of an upper
# layer to know the highest N used by a layer they cannot see.
#
# Missing files are skipped (an absent layer contributes nothing), so callers
# pass the whole chain unconditionally.
_conf_load_layers() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  shift
  (( $# > 0 )) || { declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"; return 0; }

  # Tokenize every layer up front into flat, layer-tagged arrays: the
  # per-layer arrays cannot be kept as separate named arrays without
  # eval, so each entry carries its layer index instead.
  local -a _cll_layer_of=() _cll_es=() _cll_keys=() _cll_vals=()
  local -a _cll_order=()
  local -A _cll_order_seen=()
  # _cll_owner[<section>] = highest layer index that defines the section.
  local -A _cll_owner=()

  local _cll_idx=0 _cll_file _cll_i _cll_s
  for _cll_file in "$@"; do
    local -a _cll_fs=() _cll_fes=() _cll_fk=() _cll_fv=()
    _ini_tokenize "${_cll_file}" _cll_fs _cll_fes _cll_fk _cll_fv
    for (( _cll_i = 0; _cll_i < ${#_cll_fk[@]}; _cll_i++ )); do
      _cll_layer_of+=("${_cll_idx}")
      _cll_es+=("${_cll_fes[_cll_i]}")
      _cll_keys+=("${_cll_fk[_cll_i]}")
      _cll_vals+=("${_cll_fv[_cll_i]}")
      _cll_owner["${_cll_fes[_cll_i]}"]="${_cll_idx}"
    done
    # Section ORDER follows first appearance across the chain, so a
    # section introduced by the baseline keeps its slot even when an
    # upper layer redefines it.
    for _cll_s in "${_cll_fs[@]+"${_cll_fs[@]}"}"; do
      [[ -n "${_cll_order_seen[${_cll_s}]:-}" ]] && continue
      _cll_order+=("${_cll_s}")
      _cll_order_seen["${_cll_s}"]=1
    done
    _cll_idx=$(( _cll_idx + 1 ))
  done

  declare -g -a "${_h}__sects=()" "${_h}__es=()" "${_h}__keys=()" "${_h}__vals=()"
  local -n _cll_ms="${_h}__sects" _cll_mes="${_h}__es" _cll_mk="${_h}__keys" _cll_mv="${_h}__vals"

  # A section header with no entries names no owner; it still exists as a
  # section but contributes nothing, matching the pre-chain behaviour.
  for _cll_s in "${_cll_order[@]+"${_cll_order[@]}"}"; do
    _cll_ms+=("${_cll_s}")
    local _cll_win="${_cll_owner[${_cll_s}]:-}"
    [[ -n "${_cll_win}" ]] || continue
    for (( _cll_i = 0; _cll_i < ${#_cll_keys[@]}; _cll_i++ )); do
      [[ "${_cll_es[_cll_i]}" == "${_cll_s}" ]] || continue
      [[ "${_cll_layer_of[_cll_i]}" == "${_cll_win}" ]] || continue
      _cll_mes+=("${_cll_s}"); _cll_mk+=("${_cll_keys[_cll_i]}"); _cll_mv+=("${_cll_vals[_cll_i]}")
    done
  done
  return 0
}

# _conf_load_merged <template_file> <repo_file> <handle>
#
# Two-layer form of _conf_load_layers, kept as the name the explicit
# template/repo call sites read by. Same section-replace semantics.
_conf_load_merged() {
  local _tpl="${1:?"${FUNCNAME[0]}: missing template file"}"
  local _repo="${2:?"${FUNCNAME[0]}: missing repo file"}"
  local _h="${3:?"${FUNCNAME[0]}: missing handle"}"
  _conf_load_layers "${_h}" "${_tpl}" "${_repo}"
}

# _conf_list_sorted <handle> <section> <prefix> <outvar_array>
#
# Collect entries in <section> whose key is "<prefix><N>" (numeric suffix),
# skip empty values (opt-out), sort by the numeric suffix, and return the
# VALUES in that order into <outvar_array>. The opaque-handle equivalent of
# setup.sh's _get_conf_list_sorted (which reads raw parallel arrays).
_conf_list_sorted() {
  local _h="${1:?"${FUNCNAME[0]}: missing handle"}"
  local _sec="${2:?"${FUNCNAME[0]}: missing section"}"
  local _prefix="${3:?"${FUNCNAME[0]}: missing prefix"}"
  local -n _cls_out="${4:?"${FUNCNAME[0]}: missing outvar"}"
  local -n _cls_es="${_h}__es" _cls_k="${_h}__keys" _cls_v="${_h}__vals"

  _cls_out=()
  local -a _cls_pairs=()
  local _cls_i _cls_num
  for (( _cls_i = 0; _cls_i < ${#_cls_k[@]}; _cls_i++ )); do
    [[ "${_cls_es[_cls_i]}" == "${_sec}" ]] || continue
    [[ "${_cls_k[_cls_i]}" == "${_prefix}"* ]] || continue
    _cls_num="${_cls_k[_cls_i]#"${_prefix}"}"
    [[ "${_cls_num}" =~ ^[0-9]+$ ]] || continue
    [[ -z "${_cls_v[_cls_i]}" ]] && continue
    _cls_pairs+=("${_cls_num}:${_cls_v[_cls_i]}")
  done

  if (( ${#_cls_pairs[@]} > 0 )); then
    local _cls_sorted _cls_line
    _cls_sorted="$(printf '%s\n' "${_cls_pairs[@]}" | sort -t: -k1,1n)"
    while IFS= read -r _cls_line; do
      _cls_out+=("${_cls_line#*:}")
    done <<< "${_cls_sorted}"
  fi
  return 0
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

  # setup_tui's `_commit_and_setup` passes the same path for dst
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

  # Write to a sibling temp file and atomically `mv` it over _dst at the
  # very end. The previous in-place `: > "${_dst}"` truncated the user's
  # config FIRST, opening a data-loss window: any append failing after the
  # truncate (disk full / mid-write error) left setup.conf truncated with
  # no rollback. The temp+mv pattern means a mid-write failure leaves the
  # original _dst untouched. Guard mktemp so a failed temp creation
  # (read-only dir / no inodes) bails before touching _dst.
  local _out
  if ! _out="$(mktemp "${_dst}.XXXXXX" 2>/dev/null)" || [[ -z "${_out}" || ! -f "${_out}" ]]; then
    _log_err conf conf_write_tmp_failed "display=_write_setup_conf: cannot create temp file next to ${_dst}; destination left unchanged" "file=${_dst}"
    return 1
  fi

  local __current="" __k __rest
  : > "${_out}"
  for __line in "${__tpl_lines[@]}"; do
    if [[ "${__line}" =~ ^[[:space:]]*\[(.+)\][[:space:]]*$ ]]; then
      # Flush not-yet-emitted overrides belonging to the section we are
      # about to leave (those are "added" keys with no template line).
      if [[ -n "${__current}" ]]; then
        local __ovk
        for __ovk in "${!__override[@]}"; do
          if [[ "${__ovk}" == "${__current}."* && -z "${__emitted[${__ovk}]:-}" ]]; then
            [[ -n "${__removed[${__ovk}]+x}" ]] && { __emitted[${__ovk}]=1; continue; }
            printf '%s = %s\n' "${__ovk#"${__current}".}" "${__override[${__ovk}]}" >> "${_out}"
            __emitted[${__ovk}]=1
          fi
        done
        # Separate appended keys from the next section header with a blank line
        printf '\n' >> "${_out}"
      fi
      __current="${BASH_REMATCH[1]}"
      printf '%s\n' "${__line}" >> "${_out}"
      continue
    fi
    if [[ -z "${__line}" || "${__line}" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "${__line}" >> "${_out}"
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
        printf '%s = %s\n' "${__rest}" "${__override[${__nskey}]}" >> "${_out}"
        __emitted[${__nskey}]=1
        continue
      fi
    fi
    printf '%s\n' "${__line}" >> "${_out}"
  done

  # Flush leftovers belonging to the final section
  if [[ -n "${__current}" ]]; then
    local __ovk
    for __ovk in "${!__override[@]}"; do
      if [[ "${__ovk}" == "${__current}."* && -z "${__emitted[${__ovk}]:-}" ]]; then
        [[ -n "${__removed[${__ovk}]+x}" ]] && continue
        printf '%s = %s\n' "${__ovk#"${__current}".}" "${__override[${__ovk}]}" >> "${_out}"
        __emitted[${__ovk}]=1
      fi
    done
  fi

  # Append NEW sections — overrides whose `<section>.<key>` namespace
  # references a section never seen in the template. Per-stage
  # `[stage:NAME]` sections are the typical case: template's
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
    printf '\n[%s]\n' "${__ns}" >> "${_out}"
    for (( _wsc_i = 0; _wsc_i < ${#_wsc_keys[@]}; _wsc_i++ )); do
      local __key="${_wsc_keys[_wsc_i]}"
      [[ "${__key}" == "${__ns}."* ]] || continue
      [[ -n "${__emitted[${__key}]:-}" ]] && continue
      [[ -n "${__removed[${__key}]+x}" ]] && continue
      printf '%s = %s\n' "${__key#"${__ns}".}" "${_wsc_values[_wsc_i]}" >> "${_out}"
      __emitted[${__key}]=1
    done
  done

  # Atomically replace _dst only after the full rewrite succeeded. A
  # failed mv (e.g. _dst on a read-only mount) is surfaced rather than
  # leaving a stray temp file silently behind: remove the orphan temp,
  # log an actionable error, and bail with the original _dst untouched.
  mv "${_out}" "${_dst}" || {
    rm -f "${_out}"
    _log_err conf conf_write_mv_failed "display=_write_setup_conf: could not replace ${_dst}; destination left unchanged" "file=${_dst}"
    return 1
  }
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

  [[ -f "${_file}" ]] || { _log_err conf conf_upsert_file_missing "display=_upsert_conf_value: file missing: ${_file}"; return 1; }

  # A value (or key) bearing a newline would be written by the
  # `printf '%s = %s\n'` lines below as multiple physical lines, leaving
  # an orphan, un-keyed line that corrupts the INI on the next read. The
  # scalar validators are line-anchored (`.*$` matches up to a newline)
  # so a newline-bearing value can pass validation upstream; refuse it
  # here at the writer sink so every caller (set / add / TUI / WS_PATH)
  # is protected.
  if [[ "${_key}" == *$'\n'* || "${_value}" == *$'\n'* ]]; then
    _log_err conf conf_upsert_newline_rejected "display=_upsert_conf_value: refusing newline-bearing key/value"
    return 1
  fi

  # Guard the temp-file creation. An unchecked `mktemp` failure (read-only
  # dir / no inodes) leaves _tmp empty, the per-line `>> ""` writes
  # silently no-op, and the final `mv "" "${_file}"` either aborts under
  # set -e with no actionable message or, worse, truncates the user's
  # config. Bail BEFORE touching the original file so a failed write is
  # never destructive.
  local _tmp
  if ! _tmp="$(mktemp "${_file}.XXXXXX" 2>/dev/null)" || [[ -z "${_tmp}" || ! -f "${_tmp}" ]]; then
    _log_err conf conf_upsert_tmp_failed "display=_upsert_conf_value: cannot create temp file next to ${_file}; original left unchanged" "file=${_file}"
    return 1
  fi

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

  # Atomically replace _file only after the rewrite succeeded. A failed
  # mv (e.g. _file on a read-only mount) removes the orphan temp, logs an
  # actionable error, and bails with the original _file untouched.
  mv "${_tmp}" "${_file}" || {
    rm -f "${_tmp}"
    _log_err conf conf_upsert_mv_failed "display=_upsert_conf_value: could not replace ${_file}; original left unchanged" "file=${_file}"
    return 1
  }
}
