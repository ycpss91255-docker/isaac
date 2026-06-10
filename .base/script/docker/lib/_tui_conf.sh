#!/usr/bin/env bash
#
# _tui_conf.sh — Pure-logic helpers for validating setup.conf values and
# assembling mount/GPU fields. Sourced by setup_tui.sh, setup.sh, and
# bats tests.
#
# The INI read/write primitives (_load_setup_conf_full, _parse_ini_section,
# _write_setup_conf, _upsert_conf_value) moved to lib/conf.sh in #411;
# this file sources conf.sh below so callers that pull in only
# _tui_conf.sh still get them.
#
# Style: Google Shell Style Guide. No interactive I/O here; all dialog
# interactions live in _tui_backend.sh.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_TUI_CONF_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_TUI_CONF_SOURCED=1

# INI read/write primitives now live in conf.sh. Source it directly
# (idempotent via conf.sh's own guard) so any consumer of _tui_conf.sh
# gets them without depending on _lib.sh's umbrella load order. Mirrors
# how compose.sh / config_summary.sh pull in their lib deps.
_tui_conf_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=script/docker/lib/conf.sh
source "${_tui_conf_dir}/conf.sh"
unset _tui_conf_dir

# ════════════════════════════════════════════════════════════════════
# Validators
# ════════════════════════════════════════════════════════════════════

# _validate_mount <value>
#
# Valid forms:
#   <host>:<container>
#   <host>:<container>:<mode>
# where <mode> is one or more of: ro, rw, rslave, rshared, rprivate,
# slave, shared, private — comma-separated (e.g. rw,rslave).
# Both path parts must be non-empty. Exactly 1 or 2 ':' separators.
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
      local _mode
      IFS=',' read -ra _mode <<< "${_parts[2]}"
      local _m
      for _m in "${_mode[@]}"; do
        case "${_m}" in
          ro|rw|rslave|rshared|rprivate|slave|shared|private) ;;
          *) return 1 ;;
        esac
      done
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# _assemble_mount_value <host> <container> [<mode>]
#
# Builds the host:container[:mode] string for [devices] device_* and
# [volumes] mount_* entries. Lets the TUI collect pieces separately
# (path inputbox + mode picker) and assemble them safely (#461).
_assemble_mount_value() {
  local _host="${1:?_assemble_mount_value requires host}"
  local _container="${2:?_assemble_mount_value requires container}"
  local _mode_str="${3-}"
  if [[ -n "${_mode_str}" ]]; then
    printf '%s:%s:%s\n' "${_host}" "${_container}" "${_mode_str}"
  else
    printf '%s:%s\n' "${_host}" "${_container}"
  fi
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

# _validate_restart <value>
#
# #478: docker restart policy. One of no / always / unless-stopped /
# on-failure / on-failure:N (N a positive integer). Returns 0 if valid.
_validate_restart() {
  case "${1-}" in
    no|always|unless-stopped|on-failure) return 0 ;;
    on-failure:*)
      # N must be a positive integer (no extglob dependency).
      [[ "${1#on-failure:}" =~ ^[1-9][0-9]*$ ]] ;;
    *) return 1 ;;
  esac
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

# _validate_log_driver <value>
#
# Docker logging drivers (registered names). The daemon also accepts
# external plugins not in this list, so the validator is lenient on
# the name shape; we reject only obviously malformed values (empty,
# whitespace, or names with characters outside the registered set).
_validate_log_driver() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ "${_v}" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] && return 0
  return 1
}

# _validate_log_max_size <value>
#
# Compose `logging.options.max-size`: `<num><unit>` where unit is one
# of k/m/g (case-insensitive, single-letter). Docker's docs also list
# `b` (bytes), so accept it too.
_validate_log_max_size() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  shopt -s nocasematch
  if [[ "${_v}" =~ ^[0-9]+[bkmg]$ ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  return 1
}

# _validate_log_max_file <value>
#
# Compose `logging.options.max-file`: positive integer >= 1.
_validate_log_max_file() {
  local _v="${1-}"
  [[ "${_v}" =~ ^[1-9][0-9]*$ ]] && return 0
  return 1
}

# _validate_log_compress <value>
#
# Compose `logging.options.compress`: boolean `true` or `false`.
_validate_log_compress() {
  local _v="${1-}"
  case "${_v}" in
    true|false) return 0 ;;
    *) return 1 ;;
  esac
}

# _validate_log_local_path <value>
#
# Host-side log directory for the [logging] local_path feature
# (#328). Lenient: accepts any non-empty string; the resolver does
# `~`-expansion and relative-to-repo-root normalisation at apply
# time, and the dir is created with `mkdir -p` if missing then.
# Reject whitespace-only and embedded-newline values up front --
# both would produce broken compose YAML.
_validate_log_local_path() {
  local _v="${1-}"
  [[ -z "${_v}" ]] && return 1
  [[ -z "${_v// /}" ]] && return 1
  [[ "${_v}" == *$'\n'* ]] && return 1
  return 0
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
