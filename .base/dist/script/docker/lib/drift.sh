#!/usr/bin/env bash
#
# drift.sh - setup drift detection (system+conf vs generated .env metadata).
#
# Compares current host state + setup.conf hash against the SETUP_* metadata
# baked into .env.generated, so build.sh / run.sh can auto-regenerate the
# derived artifacts when they drift: _check_setup_drift (the comparator),
# _setup_check_drift (the subcommand wrapper), and
# _announce_template_default_fallback (the template-default notice).
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). Calls into
# the conf accessors / resolvers / _setup_msg + globals in setup.sh; all
# resolve at call-time via the _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_DRIFT_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_DRIFT_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift <base_path>
#
# Compares current system state + setup.conf hash against .env's SETUP_*
# metadata. Prints drift descriptions to stderr when drift detected and
# returns 1 so the caller (build.sh / run.sh) can auto-regenerate the
# derived artifacts. Returns 0 (silent) when in sync.
#
# Requires .env to exist (caller checks first).
# ════════════════════════════════════════════════════════════════════
_check_setup_drift() {
  local _base="${1:?}"
  local _env_file="${_base}/.env.generated"
  [[ -f "${_env_file}" ]] || return 0

  # Read stored values from .env.generated without polluting caller's env
  local _stored_hash="" _stored_df_hash="" _stored_gui="" _stored_gpu="" _stored_uid=""
  _stored_hash="$(   grep -oP '^SETUP_CONF_HASH=\K.*'       "${_env_file}" 2>/dev/null || true)"
  _stored_df_hash="$(grep -oP '^SETUP_DOCKERFILE_HASH=\K.*' "${_env_file}" 2>/dev/null || true)"
  _stored_gui="$(    grep -oP '^SETUP_GUI_DETECTED=\K.*'    "${_env_file}" 2>/dev/null || true)"
  _stored_gpu="$(    grep -oP '^GPU_ENABLED=\K.*'           "${_env_file}" 2>/dev/null || true)"
  _stored_uid="$(    grep -oP '^USER_UID=\K.*'              "${_env_file}" 2>/dev/null || true)"

  local _now_hash="" _now_df_hash="" _now_gui="" _now_gpu=""
  _compute_conf_hash       "${_base}" _now_hash
  _compute_dockerfile_hash "${_base}" _now_df_hash
  detect_gui _now_gui
  detect_gpu _now_gpu
  local _now_uid=""
  _now_uid="$(id -u)"

  local -a _drift=()
  [[ -n "${_stored_hash}"    && "${_now_hash}"    != "${_stored_hash}"    ]] \
    && _drift+=("setup.conf modified since last setup")
  [[ -n "${_stored_df_hash}" && "${_now_df_hash}" != "${_stored_df_hash}" ]] \
    && _drift+=("Dockerfile stage list changed since last setup (added/removed FROM ... AS <stage>)")
  [[ -n "${_stored_gpu}"     && "${_now_gpu}"     != "${_stored_gpu}"     ]] \
    && _drift+=("GPU detection changed: ${_stored_gpu} → ${_now_gpu}")
  [[ -n "${_stored_gui}"     && "${_now_gui}"     != "${_stored_gui}"     ]] \
    && _drift+=("GUI detection changed: ${_stored_gui} → ${_now_gui}")
  [[ -n "${_stored_uid}"     && "${_now_uid}"     != "${_stored_uid}"     ]] \
    && _drift+=("USER_UID changed: ${_stored_uid} → ${_now_uid}")

  if (( ${#_drift[@]} > 0 )); then
    local _d
    _log_warn setup env_drift_detected "display=drift detected since last setup.sh run:"
    for _d in "${_drift[@]}"; do
      _log_warn setup env_drift_detail "display=  - ${_d}" "detail=${_d}"
    done
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_check_drift
#
# Subcommand handler for `setup.sh check-drift`. Parses --base-path /
# --lang flags then delegates to _check_setup_drift, which prints drift
# descriptions to stderr and returns 1 when the .env metadata no longer
# matches current system / setup.conf state.
#
# Build.sh / run.sh invoke this as a subprocess (instead of sourcing
# setup.sh) so internal helpers like _setup_msg can never shadow
# caller-side _msg keys ('s class of bug).
#
# Usage: _setup_check_drift [--base-path <path>] [--lang <code>]
# ════════════════════════════════════════════════════════════════════
_setup_check_drift() {
  local _base_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../../.." && pwd -P)"
  fi

  _announce_template_default_fallback "${_base_path}"
  _check_setup_drift "${_base_path}"
}

# ════════════════════════════════════════════════════════════════════
# _announce_template_default_fallback <base_path>
#
# Surface a one-shot WARN when the per-repo setup.conf provides no
# overrides — either missing entirely or present but containing no
# [section] headers. Called from both `_setup_apply` and
# `_setup_check_drift` so build.sh / run.sh's drift-check rebuild path
# also surfaces the heads-up (follow-up to).
# Emitted to stderr to keep stdout machine-parseable. promoted
# the level from INFO to WARN so the notice doesn't scroll past
# unnoticed in normal build.sh / run.sh output.
# ════════════════════════════════════════════════════════════════════
_announce_template_default_fallback() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  # Existence check tracks the per-repo override file (setup.conf), the
  # source of truth
  local _repo_conf="${_base}/.setup.conf"
  if [[ ! -f "${_repo_conf}" ]]; then
    _log_warn setup conf_no_repo_conf "display=$(_setup_msg warnings no_repo_conf)"
  elif ! grep -qE '^[[:space:]]*\[[^]]+\]' "${_repo_conf}"; then
    _log_warn setup conf_empty_repo_conf "display=$(_setup_msg warnings empty_repo_conf)"
  fi
}
