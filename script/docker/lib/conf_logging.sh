#!/usr/bin/env bash
#
# conf_logging.sh -- shared parsers for the [logging] / [logging.<svc>]
# sections of setup.conf.
#
# Extracted from script/docker/wrapper/setup.sh during the #402
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
#     Resolve effective [logging] (section-replace fallback to template)
#     and per-service [logging.<svc>] (per-repo only) into two
#     newline-joined strings.

# Guard against double-sourcing -- setup.sh sources us, and so does
# lib/gitignore.sh in PR-B; the apply pipeline pulls both in.
if [[ -n "${_DOCKER_LIB_CONF_LOGGING_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_CONF_LOGGING_SOURCED=1

# _parse_logging_svc_sections depends on the caller having sourced
# _parse_ini_section (in lib/conf.sh since #402; full INI handling
# consolidated there in #411). Same with _SETUP_SCRIPT_DIR for the
# template fallback in _collect_logging.

# _parse_logging_svc_sections <file> <out_array>
#
# Emit each service name that has a `[logging.<svc>]` section in <file>
# (in the order they appear). Mirrors `_parse_stage_sections` but for
# the per-service logging override namespace (#310).
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
#                [logging] section. Resolution rule mirrors [security]:
#                if the per-repo setup.conf has a [logging] section,
#                that section fully replaces the template default (per
#                CLAUDE.md "section-level replace, no key-level merge
#                inside a section"). If the per-repo file omits the
#                section, template defaults apply.
#
#   per_svc_out  newline-separated "<svc>:KEY=VALUE" rows for any
#                [logging.<svc>] sections in the per-repo setup.conf.
#                Key-level merge against global_out happens in
#                `_emit_logging_block` at compose-emit time -- only
#                keys present in [logging.<svc>] override the
#                corresponding global key; absent keys fall through.
#                Template setup.conf does not ship per-svc sections;
#                if one ever appears there it is honored too (parsed
#                only from the per-repo file in practice, since the
#                template loader path uses _SETUP_SCRIPT_DIR).
_collect_logging() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _cl_global="${2:?"${FUNCNAME[0]}: missing global outvar"}"
  local -n _cl_per_svc="${3:?"${FUNCNAME[0]}: missing per_svc outvar"}"
  _cl_global=""
  _cl_per_svc=""

  local _conf
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _conf="${SETUP_CONF}"
  else
    _conf="${_base}/config/docker/setup.conf"
  fi

  # Global [logging] -- per-repo first, fall back to template if absent.
  local -a _g_keys=() _g_vals=()
  [[ -f "${_conf}" ]] && _parse_ini_section "${_conf}" "logging" _g_keys _g_vals
  if (( ${#_g_keys[@]} == 0 )) && [[ -n "${_SETUP_SCRIPT_DIR:-}" ]]; then
    # _SETUP_SCRIPT_DIR is set by setup.sh; init.sh / upgrade.sh call
    # _collect_logging via _sync_logging_gitignore (#402 PR-B) without
    # sourcing setup.sh, so the template-fallback step is skipped in
    # that path. Per-repo setup.conf already covers downstream cases.
    local _tpl="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
    [[ -f "${_tpl}" ]] && _parse_ini_section "${_tpl}" "logging" _g_keys _g_vals
  fi
  local i
  local -a _g_lines=()
  for (( i = 0; i < ${#_g_keys[@]}; i++ )); do
    _g_lines+=("${_g_keys[i]}=${_g_vals[i]}")
  done
  (( ${#_g_lines[@]} > 0 )) && _cl_global="$(printf '%s\n' "${_g_lines[@]}")"

  # Per-service [logging.<svc>] sections (per-repo only).
  [[ -f "${_conf}" ]] || return 0
  local -a _svcs=()
  _parse_logging_svc_sections "${_conf}" _svcs
  local _svc
  local -a _ps_lines=()
  for _svc in "${_svcs[@]}"; do
    local -a _sk=() _sv=()
    _parse_ini_section "${_conf}" "logging.${_svc}" _sk _sv
    for (( i = 0; i < ${#_sk[@]}; i++ )); do
      _ps_lines+=("${_svc}:${_sk[i]}=${_sv[i]}")
    done
  done
  (( ${#_ps_lines[@]} > 0 )) && _cl_per_svc="$(printf '%s\n' "${_ps_lines[@]}")"
  return 0
}
