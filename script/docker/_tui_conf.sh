#!/usr/bin/env bash
#
# _tui_conf.sh — Pure-logic helpers for reading, validating, and writing
# setup.conf. Sourced by setup_tui.sh, setup.sh (for writeback), and bats tests.
#
# Style: Google Shell Style Guide. No interactive I/O here; all dialog
# interactions live in _tui_backend.sh.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_TUI_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_TUI_CONF_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# Validators
# ════════════════════════════════════════════════════════════════════

# _validate_mount <value>
#
# Valid forms:
#   <host>:<container>
#   <host>:<container>:ro
#   <host>:<container>:rw
# Both parts must be non-empty. Exactly 1 or 2 ':' separators (env-var
# forms like ${FOO} count as host path, not separators).
_validate_mount() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1

  local -a _parts=()
  IFS=':' read -ra _parts <<< "${_v}"
  case "${#_parts[@]}" in
    2)
      [[ -n "${_parts[0]}" && -n "${_parts[1]}" ]] || return 1
      ;;
    3)
      [[ -n "${_parts[0]}" && -n "${_parts[1]}" ]] || return 1
      [[ "${_parts[2]}" == "ro" || "${_parts[2]}" == "rw" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# _validate_gpu_count <value>
#
# Accepts "all" or a positive integer.
_validate_gpu_count() {
  local _v="${1-}"
  [[ "${_v}" == "all" ]] && return 0
  [[ "${_v}" =~ ^[1-9][0-9]*$ ]] && return 0
  return 1
}

# _validate_enum <value> <opt1> [opt2...]
#
# Returns 0 if <value> matches any option exactly.
_validate_enum() {
  local _v="${1-}"; shift
  [[ -z "${_v}" ]] && return 1
  local _opt
  for _opt in "$@"; do
    [[ "${_v}" == "${_opt}" ]] && return 0
  done
  return 1
}

# _validate_shm_size <value>
#
# Docker `shm_size` accepts `<num><unit>` where unit ∈ b/k/m/g or kb/mb/gb
# (case-insensitive).
_validate_shm_size() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  shopt -s nocasematch
  if [[ "${_v}" =~ ^[0-9]+(b|k|m|g|kb|mb|gb)$ ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  return 1
}

# _validate_port_mapping <value>
#
# compose `ports:` short form: <host>:<container>[/protocol]
# protocol ∈ tcp | udp.
_validate_port_mapping() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" =~ ^[0-9]+:[0-9]+(/(tcp|udp))?$ ]] && return 0
  return 1
}

# _validate_cgroup_rule <value>
#
# docker compose `device_cgroup_rules:` entry. Format:
#   <type> <major>:<minor|*> <perms>
# where type is one of c / b / a, major/minor are integers or `*`
# (all), perms is any non-empty subset of {r, w, m}.
_validate_cgroup_rule() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" =~ ^[cba][[:space:]]+([0-9]+|\*):([0-9]+|\*)[[:space:]]+[rwm]+$ ]] \
    && return 0
  return 1
}

# _validate_env_kv <value>
#
# Linux env var format: KEY must start with letter or underscore,
# followed by letters / digits / underscores. VALUE may be empty.
_validate_env_kv() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] && return 0
  return 1
}

# _validate_additional_context <value>
#
# Compose `build.additional_contexts` entry. Format:
#   <name>=<value>
# <name> follows BuildKit's named-context naming: starts with a letter
# or digit, then alphanumerics plus underscore / dot / hyphen.
# <value> is a free-form context source (relative path, docker-image://,
# https://, oci-layout://, etc.) and must be non-empty.
_validate_additional_context() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" != *"="* ]] && return 1
  local _name="${_v%%=*}"
  local _val="${_v#*=}"
  [[ -z "${_name}" || -z "${_val}" ]] && return 1
  [[ "${_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && return 0
  return 1
}

# _validate_network_name <value>
#
# Docker network name: start with [a-zA-Z0-9], then alphanumerics plus
# underscore, dot, hyphen. Matches moby/libnetwork's NetworkName regex.
_validate_network_name() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] && return 0
  return 1
}

# _validate_capability <value>
#
# Linux capability names (used in cap_add / cap_drop) are all-uppercase
# ASCII with underscores (e.g. SYS_ADMIN, NET_ADMIN, ALL).
_validate_capability() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" =~ ^[A-Z_]+$ ]] && return 0
  return 1
}

# _validate_target_arch <value>
#
# Accepts the Docker BuildKit-recognised architectures or an empty
# string (empty = let BuildKit auto-fill from host/--platform).
_validate_target_arch() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 0
  case "${_v}" in
    amd64|arm64|arm|386|ppc64le|s390x|riscv64) return 0 ;;
    *) return 1 ;;
  esac
}

# _validate_build_network <value>
#
# Accepts empty (Docker default = bridge) or one of the network modes
# that docker build / docker compose build accept via their --network
# flag. `host` is the common workaround for environments where bridge
# NAT is broken (stripped embedded kernels, iptables:false).
_validate_build_network() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 0
  case "${_v}" in
    auto|host|bridge|none|default|off) return 0 ;;
    *) return 1 ;;
  esac
}

# _validate_runtime <value>
#
# Validates [deploy] runtime override. Controls whether setup.sh emits
# `runtime: nvidia` at service level in compose.yaml (needed on Jetson
# / csv-mode nvidia-container-toolkit hosts).
#   auto   — auto-detect Jetson (/etc/nv_tegra_release); emit on match
#   nvidia — force emit on all hosts
#   off    — never emit (Docker default runc)
#   ""     — treated as off
_validate_runtime() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 0
  case "${_v}" in
    auto|nvidia|off) return 0 ;;
    *) return 1 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# Mount-string parsers
# ════════════════════════════════════════════════════════════════════

# _mount_host_path <mount_str> <outvar>
#
# Extracts the host-side path (everything before the first ':').
_mount_host_path() {
  local _v="${1-}"
  local -n _mhp_out="${2:?}"
  _mhp_out="${_v%%:*}"
}

# _mount_container_path <mount_str> <outvar>
#
# Extracts the container-side path (the middle component between the
# first ':' and the optional mode suffix).
_mount_container_path() {
  local _v="${1-}"
  local -n _mcp_out="${2:?}"

  local -a _parts=()
  IFS=':' read -ra _parts <<< "${_v}"
  _mcp_out="${_parts[1]:-}"
}

# ════════════════════════════════════════════════════════════════════
# NVIDIA MIG detection
#
# MIG (Multi-Instance GPU, A100/H100+) splits one physical GPU into
# isolated slices addressable by UUID. Docker's `count=N` reservation
# targets whole GPUs, so to pin a specific slice users must set
# NVIDIA_VISIBLE_DEVICES=<MIG-UUID> via [environment]. The TUI uses
# these helpers to detect MIG mode and show the user the available
# slice UUIDs before they edit the [deploy] count.
# ════════════════════════════════════════════════════════════════════

# _detect_mig
#
# Returns 0 when the host has NVIDIA MIG mode enabled on at least one
# GPU, 1 otherwise (including when nvidia-smi is missing).
_detect_mig() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local _mig_mode
  _mig_mode="$(nvidia-smi --query-gpu=mig.mode.current \
    --format=csv,noheader 2>/dev/null | head -1)"
  [[ "${_mig_mode}" == "Enabled" ]]
}

# _list_gpu_instances
#
# Prints `nvidia-smi -L` output verbatim (GPU and MIG lines with UUIDs).
# Emits nothing if nvidia-smi is missing or fails.
_list_gpu_instances() {
  nvidia-smi -L 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════
# INI reader (full file, preserving section order)
# ════════════════════════════════════════════════════════════════════

# _load_setup_conf_full <file> <sections_outvar> <keys_outvar> <values_outvar>
#
# Reads an INI file into three parallel arrays:
#   sections[] — unique section names in first-appearance order
#   keys[i]    — "<section>.<key>" (namespaced)
#   values[i]  — trimmed value
#
# Comments and blank lines are skipped.
_load_setup_conf_full() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _lsf_sections="${2:?}"
  local -n _lsf_keys="${3:?}"
  local -n _lsf_values="${4:?}"

  _lsf_sections=()
  _lsf_keys=()
  _lsf_values=()
  [[ -f "${_file}" ]] || return 0

  local __line __current="" __k __v __seen_sect
  local -A __sect_seen=()
  while IFS= read -r __line || [[ -n "${__line}" ]]; do
    # Strip comments / blanks
    [[ -z "${__line}" || "${__line}" =~ ^[[:space:]]*# ]] && continue

    # Trim surrounding whitespace
    __line="${__line#"${__line%%[![:space:]]*}"}"
    __line="${__line%"${__line##*[![:space:]]}"}"
    [[ -z "${__line}" ]] && continue

    # Section header
    if [[ "${__line}" =~ ^\[(.+)\]$ ]]; then
      __current="${BASH_REMATCH[1]}"
      __seen_sect="${__sect_seen[${__current}]:-}"
      if [[ -z "${__seen_sect}" ]]; then
        _lsf_sections+=("${__current}")
        __sect_seen[${__current}]=1
      fi
      continue
    fi

    # Require key = value inside a section
    [[ -z "${__current}" || "${__line}" != *=* ]] && continue
    __k="${__line%%=*}"
    __v="${__line#*=}"
    __k="${__k#"${__k%%[![:space:]]*}"}"
    __k="${__k%"${__k##*[![:space:]]}"}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"

    _lsf_keys+=("${__current}.${__k}")
    _lsf_values+=("${__v}")
  done < "${_file}"
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
      fi
    done
  fi
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
