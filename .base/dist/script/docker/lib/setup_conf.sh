#!/usr/bin/env bash
#
# setup_conf.sh - setup.conf accessors (template+repo section-replace merge).
#
# The readers setup.sh and the other libs use to query the effective
# setup.conf: the per-section merge loader (_load_setup_conf), the parse-once
# handle model (_setup_conf_handle / _setup_effective_full) feeding the
# _conf_get / _conf_list_sorted accessors in lib/conf.sh, the convenience
# scalar/list getters (_get_conf_value / _get_conf_list_sorted), and the
# [image]-rule applicators (_rule_prefix / _rule_suffix / _rule_basename) used
# by detect_image_name.
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). The low-level
# _parse_ini_section + the handle accessors live in lib/conf.sh; this file is the
# setup.conf-path-resolving layer above them. Calls into _SETUP_SCRIPT_DIR +
# _parse_ini_section + the conf.sh accessors, all resolved at call-time via the
# _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SETUP_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SETUP_CONF_SOURCED=1

# The layer resolvers below are thin wrappers over conf.sh's INI
# primitives (_parse_ini_section / _ini_tokenize / _conf_load_layers), so
# pull conf.sh in directly (idempotent via its own double-source guard)
# rather than depending on _lib.sh's load order -- same shape as schema.sh
# pulling in _tui_conf.sh. Keeps this file sourceable on its own by the
# lighter callers (init.sh / upgrade.sh reach it through conf_logging.sh).
_setup_conf_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/conf.sh
source "${_setup_conf_lib_dir}/conf.sh"
unset _setup_conf_lib_dir

# ════════════════════════════════════════════════════════════════════
# INI parser for setup.conf
#
# _parse_ini_section moved to lib/conf.sh in (PR-B) so init.sh
# can reach it via _lib.sh without sourcing setup.sh. The function
# stays callable from this file via the same name (_lib.sh sources
# conf.sh in the umbrella loader near setup.sh's top).
# ════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════
# The conf layer chain
#
# Three files, lowest precedence first:
#
#   <template>/.setup.conf        the shipped default (inside .base)
#   <repo>/.setup.conf            the repo's committed override -- ours,
#                                 shared, what CI and every other checkout
#                                 of this repo uses
#   <repo>/.setup.conf.local      the operator's per-worktree override --
#                                 gitignored, never touched by tooling,
#                                 visible only on this machine
#
# The `.local` suffix means exactly what the repo's file-naming convention
# says it means: the standard name is ours, a suffix marks the operator's
# local variant. `.setup.conf.local` is the local variant OF `.setup.conf`
# and therefore shares its grammar -- same sections, same keys, same
# section-replace rule -- rather than being a second schema.
#
# It acts BEFORE compose.yaml is generated (one compose.yaml per worktree),
# which is what distinguishes it from the ADR-00000022 runtime `.env`
# overlay that isolates multi_run's Nth instance on ONE already-generated
# compose.yaml. Neither substitutes for the other.
# ════════════════════════════════════════════════════════════════════

# _setup_conf_layers <base_path> <outarray>
#
# Fill <outarray> with the chain's paths in INCREASING precedence. Paths
# are returned whether or not they exist -- an absent layer contributes
# nothing, and every reader passes the whole chain unconditionally so the
# precedence lives in exactly one place.
#
# The template layer is OMITTED when _SETUP_SCRIPT_DIR is unset (init.sh /
# upgrade.sh reach the readers via conf_logging.sh without sourcing
# setup.sh). Omitted rather than left to resolve: an empty prefix would
# make the path `/../../../.setup.conf`, i.e. `/.setup.conf` -- a real,
# readable path that has nothing to do with this repo.
_setup_conf_layers() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _scl_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _scl_out=()
  [[ -n "${_SETUP_SCRIPT_DIR:-}" ]] \
    && _scl_out+=("${_SETUP_SCRIPT_DIR}/../../../.setup.conf")
  _scl_out+=(
    "${_base}/.setup.conf"
    "${_base}/.setup.conf.local"
  )
}

# _setup_conf_local_path <base_path>
#
# Echo the per-worktree override path. One spelling of the filename for
# every caller that has to name it in a message.
_setup_conf_local_path() {
  printf '%s/.setup.conf.local' "${1:?"${FUNCNAME[0]}: missing base_path"}"
}

# _setup_conf_local_sections <base_path> <outarray>
#
# Fill <outarray> with the sections <base>/.setup.conf.local actually
# DEFINES (>=1 entry), in file order; empty when the file is absent or
# defines nothing. Under section-replace these are exactly the sections in
# which the local layer wins, so this is the list every "your write is
# shadowed" / "a local layer is in effect" message names. A section is
# never silently shadowed: the section list, not a boolean, is what makes
# the message actionable.
_setup_conf_local_sections() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _scls_out="${2:?"${FUNCNAME[0]}: missing outvar"}"
  _scls_out=()

  local _local
  _local="$(_setup_conf_local_path "${_base}")"
  [[ -f "${_local}" ]] || return 0

  local -a _scls_s=() _scls_es=() _scls_k=() _scls_v=()
  _ini_tokenize "${_local}" _scls_s _scls_es _scls_k _scls_v

  local _sec _i _has
  for _sec in "${_scls_s[@]+"${_scls_s[@]}"}"; do
    _has=0
    for (( _i = 0; _i < ${#_scls_es[@]}; _i++ )); do
      [[ "${_scls_es[_i]}" == "${_sec}" ]] && { _has=1; break; }
    done
    (( _has )) && _scls_out+=("${_sec}")
  done
  return 0
}

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# Resolve one section through the layer chain, section-replace: the highest
# layer that defines the section supplies ALL of its entries; the layers
# below contribute nothing to it. Sections a layer omits fall through.
#
# The chain's surface is the fixed set of paths _setup_conf_layers names.
# There is no env var that relocates it: a relocation lever is a second,
# unchecked resolution path that silently wins over the real one.
_load_setup_conf() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _lsc_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lsc_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _lsc_keys=()
  _lsc_values=()

  local -a _lsc_layers=()
  _setup_conf_layers "${_base}" _lsc_layers

  # Walk highest precedence first and stop at the first layer that defines
  # the section -- the section-replace rule, expressed as a search.
  local _i
  for (( _i = ${#_lsc_layers[@]} - 1; _i >= 0; _i-- )); do
    [[ -f "${_lsc_layers[_i]}" ]] || continue
    local -a __lsc_k=() __lsc_v=()
    _parse_ini_section "${_lsc_layers[_i]}" "${_section}" __lsc_k __lsc_v
    if (( ${#__lsc_k[@]} > 0 )); then
      _lsc_keys=("${__lsc_k[@]}")
      _lsc_values=("${__lsc_v[@]}")
      return 0
    fi
  done
  return 0
}

# _setup_conf_handle <base> <handle>
#
# Load the effective setup.conf into an opaque conf.sh <handle>: the whole
# layer chain, section-replace (same precedence as _load_setup_conf, but as
# one queryable handle for the _conf_get / _conf_list_sorted accessors).
_setup_conf_handle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base"}"
  local _h="${2:?"${FUNCNAME[0]}: missing handle"}"
  local -a _sch_layers=()
  _setup_conf_layers "${_base}" _sch_layers
  _conf_load_layers "${_h}" "${_sch_layers[@]}"
}

# _setup_effective_full <base_path> <sections_outvar> <keys_outvar> <values_outvar>
#
# The section-replace-resolved view of the whole chain in the `*_full`
# array shape (sections list + parallel `<section>.<key>` / value arrays).
# What `show` / `list` and the store-time diagnostics read, so they report
# the values the emitters will actually use -- including the ones the local
# layer supplies.
_setup_effective_full() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _sef_sections="${2:?"${FUNCNAME[0]}: missing sections outvar"}"
  local -n _sef_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _sef_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _setup_conf_handle "${_base}" _SEF_CONF

  _sef_sections=()
  _sef_keys=()
  _sef_values=()

  local -n _sef_s=_SEF_CONF__sects
  local -n _sef_es=_SEF_CONF__es
  local -n _sef_k=_SEF_CONF__keys
  local -n _sef_v=_SEF_CONF__vals

  local _i
  for (( _i = 0; _i < ${#_sef_s[@]}; _i++ )); do
    _sef_sections+=("${_sef_s[_i]}")
  done
  for (( _i = 0; _i < ${#_sef_k[@]}; _i++ )); do
    _sef_keys+=("${_sef_es[_i]}.${_sef_k[_i]}")
    _sef_values+=("${_sef_v[_i]}")
  done
  return 0
}

# _get_conf_value <keys_ref> <values_ref> <key> <default> <outvar>
#
# Returns the value for <key> in the parallel arrays; <default> if missing.
_get_conf_value() {
  local -n _gcv_keys="${1:?}"
  local -n _gcv_values="${2:?}"
  local _key="${3:?}"
  local _default="${4-}"
  local -n _gcv_out="${5:?}"

  local i
  for (( i=0; i<${#_gcv_keys[@]}; i++ )); do
    if [[ "${_gcv_keys[i]}" == "${_key}" ]]; then
      _gcv_out="${_gcv_values[i]}"
      return 0
    fi
  done
  _gcv_out="${_default}"
}

# _get_conf_list_sorted <keys_ref> <values_ref> <prefix> <outvar_array>
#
# Collects entries whose key starts with <prefix> (e.g. "mount_") and sorts
# by the numeric suffix. Returns VALUES in sorted order.
_get_conf_list_sorted() {
  local -n _gcls_keys="${1:?}"
  local -n _gcls_values="${2:?}"
  local _prefix="${3:?}"
  local -n _gcls_out="${4:?}"

  _gcls_out=()
  local -a __gcls_pairs=()
  local i __gcls_k __gcls_num
  for (( i=0; i<${#_gcls_keys[@]}; i++ )); do
    __gcls_k="${_gcls_keys[i]}"
    if [[ "${__gcls_k}" == "${_prefix}"* ]]; then
      __gcls_num="${__gcls_k#"${_prefix}"}"
      # Only numeric suffixes participate; empty values mean opt-out
      [[ "${__gcls_num}" =~ ^[0-9]+$ ]] || continue
      [[ -z "${_gcls_values[i]}" ]] && continue
      __gcls_pairs+=("${__gcls_num}:${_gcls_values[i]}")
    fi
  done

  # Sort by numeric prefix before ":"
  if (( ${#__gcls_pairs[@]} > 0 )); then
    local __gcls_sorted
    __gcls_sorted=$(printf '%s\n' "${__gcls_pairs[@]}" | sort -t: -k1,1n)
    while IFS= read -r __gcls_k; do
      _gcls_out+=("${__gcls_k#*:}")
    done <<< "${__gcls_sorted}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# Rule applicators for [image] rules (used by detect_image_name)
# ════════════════════════════════════════════════════════════════════

_rule_prefix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part _last=""
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    _last="${_part}"
    break
  done
  if [[ "${_last}" == "${_value}"* ]]; then
    echo "${_last#"${_value}"}"
  fi
}

_rule_suffix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    if [[ "${_part}" == *"${_value}" ]]; then
      echo "${_part%"${_value}"}"
      return
    fi
  done
}

_rule_basename() {
  local _path="$1"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    echo "${_part}"
    return
  done
}
