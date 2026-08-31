#!/usr/bin/env bash
#
# conf_logging.sh -- shared parsers for the [logging] / [logging.<svc>]
# sections of setup.conf.
#
# Extracted from script/docker/wrapper/setup.sh during the
# lifecycle refactor (PR-A). Both setup.sh's compose generator and
# lib/gitignore.sh's logging-block sync (added in PR-B) read the same
# values, so the parser belongs in a shared lib rather than ping-pong
# sourcing setup.sh from gitignore.sh.
#
# Surface:
#   _parse_logging_svc_sections <file> <out_array>
#     Emit each "<svc>" found in a `[logging.<svc>]` header in <file>,
#     in file order.
#
#   _collect_logging <base_path> <global_out> <per_svc_out>
#     Resolve effective [logging] and each per-service [logging.<svc>]
#     through the setup.conf layer chain (section-replace) into two
#     newline-joined strings.

# Guard against double-sourcing -- setup.sh sources us, and so does
# lib/gitignore.sh in PR-B; the apply pipeline pulls both in.
if [[ -n "${_DOCKER_LIB_CONF_LOGGING_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_CONF_LOGGING_SOURCED=1

# Self-source the dependencies (Part A): _collect_logging resolves through
# the setup.conf layer chain (lib/setup_conf.sh's _setup_conf_layers /
# _load_setup_conf), which in turn builds on lib/conf.sh's INI primitives.
# Pull both in directly -- idempotent via their own double-source guards --
# so _lib.sh load order is not load-bearing and a caller sourcing
# conf_logging.sh alone (init.sh / upgrade.sh via gitignore.sh) still works.
# (_SETUP_SCRIPT_DIR, which locates the template layer, is a
# caller-provided global, not a sourced module; without it that layer's
# path simply does not resolve and contributes nothing.)
_conf_logging_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/conf.sh
source "${_conf_logging_dir}/conf.sh"
# shellcheck source=dist/script/docker/lib/setup_conf.sh
source "${_conf_logging_dir}/setup_conf.sh"
unset _conf_logging_dir

# _parse_logging_svc_sections <file> <out_array>
#
# Emit each service name that has a `[logging.<svc>]` section in <file>
# (in the order they appear). Mirrors `_parse_stage_sections` but for
# the per-service logging override namespace.
_parse_logging_svc_sections() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _plss_out="${2:?"${FUNCNAME[0]}: missing out array"}"
  _plss_out=()
  [[ -f "${_file}" ]] || return 0
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ^\[logging\.([a-z][a-z0-9_-]*)\][[:space:]]*$ ]]; then
      _plss_out+=("${BASH_REMATCH[1]}")
    fi
  done < "${_file}"
}

# _collect_logging <base_path> <global_out> <per_svc_out>
#
# Resolve [logging] + [logging.<svc>] for the compose generator. Output
# layout:
#
#   global_out   newline-separated KEY=VALUE for the effective global
#                [logging] section, resolved through the conf chain with
#                the chain's one rule: the highest layer that defines
#                [logging] replaces it wholesale, no key-level merge
#                inside a section.
#
#   per_svc_out  newline-separated "<svc>:KEY=VALUE" rows for any
#                [logging.<svc>] sections, resolved the same way -- each
#                per-service section is its own section, so a local layer
#                may add one the repo lacks or replace one it has.
#                Key-level merge against global_out happens in
#                `_emit_logging_block` at compose-emit time -- only
#                keys present in [logging.<svc>] override the
#                corresponding global key; absent keys fall through.
#
# Callable without setup.sh sourced: init.sh / upgrade.sh reach this via
# _sync_logging_gitignore with no _SETUP_SCRIPT_DIR, in which case the
# template layer's path does not resolve and simply contributes nothing.
_collect_logging() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _cl_global="${2:?"${FUNCNAME[0]}: missing global outvar"}"
  local -n _cl_per_svc="${3:?"${FUNCNAME[0]}: missing per_svc outvar"}"
  _cl_global=""
  _cl_per_svc=""

  local -a _cl_layers=()
  _setup_conf_layers "${_base}" _cl_layers

  # Global [logging], section-replace across the chain.
  local -a _g_keys=() _g_vals=()
  _load_setup_conf "${_base}" "logging" _g_keys _g_vals
  local i
  local -a _g_lines=()
  for (( i = 0; i < ${#_g_keys[@]}; i++ )); do
    _g_lines+=("${_g_keys[i]}=${_g_vals[i]}")
  done
  (( ${#_g_lines[@]} > 0 )) && _cl_global="$(printf '%s\n' "${_g_lines[@]}")"

  # Per-service [logging.<svc>] sections. The service SET is the union
  # across the chain (a layer may introduce a service the layers below do
  # not mention); each service's section is then resolved section-replace
  # like any other, so a local layer that names one service does not
  # disturb the rest.
  local -a _svcs=() _layer_svcs=()
  local _layer _svc _known _seen
  for _layer in "${_cl_layers[@]}"; do
    [[ -f "${_layer}" ]] || continue
    _layer_svcs=()
    _parse_logging_svc_sections "${_layer}" _layer_svcs
    for _svc in "${_layer_svcs[@]+"${_layer_svcs[@]}"}"; do
      _seen=0
      for _known in "${_svcs[@]+"${_svcs[@]}"}"; do
        [[ "${_known}" == "${_svc}" ]] && { _seen=1; break; }
      done
      (( _seen )) || _svcs+=("${_svc}")
    done
  done

  local -a _ps_lines=()
  for _svc in "${_svcs[@]+"${_svcs[@]}"}"; do
    local -a _sk=() _sv=()
    _load_setup_conf "${_base}" "logging.${_svc}" _sk _sv
    for (( i = 0; i < ${#_sk[@]}; i++ )); do
      _ps_lines+=("${_svc}:${_sk[i]}=${_sv[i]}")
    done
  done
  (( ${#_ps_lines[@]} > 0 )) && _cl_per_svc="$(printf '%s\n' "${_ps_lines[@]}")"
  return 0
}
