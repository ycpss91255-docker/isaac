#!/usr/bin/env bash
#
# log.sh - OTel-aligned 5-level logger (#423, #438).
#
# 5 functions: _log_debug, _log_info, _log_warn, _log_err, _log_fatal.
# API: _log_<level> <service> <body> [attr=val]...
#
# Single-sink tty-detect dispatch: text when fd is a TTY, JSON when
# piped/redirected. Override with LOG_FORMAT=auto|text|json.
# Unregistered body (not in log-events.txt) is a fatal error.
#
# Stream routing (matches OTel severity mapping):
#   _log_debug / _log_info -> stdout
#   _log_warn / _log_err / _log_fatal -> stderr
#
# TRACEPARENT env (W3C Trace Context) propagation:
#   When set, trace_id and span_id are extracted and included in JSON.
#   Scoped wrappers: _log_with_trace / _log_with_span.
#
# Refs: #423, #438, OTel Logs Data Model, W3C Trace Context.

if [[ -n "${_DOCKER_LIB_LOG_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_LOG_SOURCED=1

readonly _LOG_LIB_DIR="${BASH_SOURCE[0]%/*}"
readonly _LOG_EVENTS_FILE="${_LOG_LIB_DIR}/log-events.txt"

# ── Event registry ─────────────────────────────────────────────────

_log_is_registered() {
  [[ -n "${1}" ]] && [[ "${1}" != \#* ]] && [[ -f "${_LOG_EVENTS_FILE}" ]] && \
    grep -Fxq "${1}" "${_LOG_EVENTS_FILE}" 2>/dev/null
}

# ── JSON helpers ───────────────────────────────────────────────────

_log_json_escape() {
  local s="${1}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "${s}"
}

_log_emit_json() {
  local severity_text="${1}"
  local severity_number="${2}"
  local service="${3}"
  local body="${4}"
  shift 4

  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%S.%6NZ')"

  local trace_id="" span_id=""
  if [[ -n "${TRACEPARENT:-}" ]]; then
    IFS=- read -r _ trace_id span_id _ <<< "${TRACEPARENT}"
  fi

  local caller_file="${BASH_SOURCE[2]:-unknown}"
  local caller_line="${BASH_LINENO[1]:-0}"

  local attrs=""
  attrs+="\"service.name\":\"$(_log_json_escape "${service}")\""
  attrs+=",\"service.lang\":\"bash\""
  attrs+=",\"code.filepath\":\"$(_log_json_escape "${caller_file}")\""
  attrs+=",\"code.lineno\":${caller_line}"
  attrs+=",\"thread.id\":\"$$\""

  local kv
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    attrs+=",\"$(_log_json_escape "${k}")\":\"$(_log_json_escape "${v}")\""
  done

  local json="{"
  json+="\"timestamp\":\"${timestamp}\""
  json+=",\"severity_text\":\"${severity_text}\""
  json+=",\"severity_number\":${severity_number}"
  json+=",\"body\":\"$(_log_json_escape "${body}")\""
  if [[ -n "${trace_id}" ]]; then
    json+=",\"trace_id\":\"${trace_id}\""
    json+=",\"span_id\":\"${span_id}\""
  fi
  json+=",\"attributes\":{${attrs}}"
  json+="}"

  printf '%s\n' "${json}"
}

# ── Text output helpers ─────────────────────────────────────────────

_log_color_enabled() {
  local fd="${1:?_log_color_enabled requires fd}"
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ -n "${FORCE_COLOR:-}" ]] && return 0
  test -t "${fd}"
}

_log_text() {
  local level="${1}" fd="${2}" tag="${3}"
  shift 3
  local msg="" display=""
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == display=* ]]; then
      display="${arg#display=}"
    elif [[ "${arg}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
      continue
    else
      msg+="${msg:+ }${arg}"
    fi
  done
  [[ -n "${display}" ]] && msg="${display}"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%S.%6NZ')"
  if [[ "${level}" == "ERROR" || "${level}" == "FATAL" ]] && _log_color_enabled "${fd}"; then
    printf '%s \033[1;31m[%s] %-5s:\033[0m %s\n' "${ts}" "${tag}" "${level}" "${msg}" >&"${fd}"
  elif [[ "${level}" == "WARN" ]] && _log_color_enabled "${fd}"; then
    printf '%s \033[33m[%s] %-5s:\033[0m %s\n' "${ts}" "${tag}" "${level}" "${msg}" >&"${fd}"
  else
    printf '%s [%s] %-5s: %s\n' "${ts}" "${tag}" "${level}" "${msg}" >&"${fd}"
  fi
}

# ── Core dispatch ──────────────────────────────────────────────────
#
# Single-sink tty-detect (#438): text when fd is a TTY, JSON when
# piped/redirected. LOG_FORMAT=auto|text|json overrides detection.
# Unregistered body is a fatal error (strict by default).

_log_dispatch() {
  local severity_text="${1}" severity_number="${2}" fd="${3}"
  local service="${4:?_log_${severity_text,,} requires service}"
  local body="${5:-}"
  shift 5 2>/dev/null || shift 4

  if [[ -n "${body}" ]] && [[ -f "${_LOG_EVENTS_FILE}" ]] \
     && ! _log_is_registered "${body}"; then
    printf 'FATAL: unregistered log body "%s" -- add it to %s\n' \
      "${body}" "${_LOG_EVENTS_FILE}" >&2
    return 1
  fi

  local format="${LOG_FORMAT:-auto}"
  case "${format}" in
    text)
      _log_text "${severity_text}" "${fd}" "${service}" "${body}" "$@"
      ;;
    json)
      _log_emit_json "${severity_text}" "${severity_number}" \
        "${service}" "${body}" "$@" >&"${fd}"
      ;;
    *)
      if test -t "${fd}"; then
        _log_text "${severity_text}" "${fd}" "${service}" "${body}" "$@"
      else
        _log_emit_json "${severity_text}" "${severity_number}" \
          "${service}" "${body}" "$@" >&"${fd}"
      fi
      ;;
  esac
}

# ── Public API ─────────────────────────────────────────────────────

_log_debug() { _log_dispatch DEBUG 5 1 "$@"; }
_log_info()  { _log_dispatch INFO  9 1 "$@"; }
_log_warn()  { _log_dispatch WARN 13 2 "$@"; }
_log_err()   { _log_dispatch ERROR 17 2 "$@"; }
_log_fatal() { _log_dispatch FATAL 21 2 "$@"; }

# ── Dry-run dispatch ───────────────────────────────────────────────
#
# _dry_run_cmd <cmd> [args...]
#
# Under DRY_RUN=true, print the planned command (`[dry-run]` + %q-quoted
# argv) to stdout WITHOUT executing it; otherwise run it verbatim. This
# is a plain command echo, NOT a structured log event -- the wrapper
# dispatch specs assert the literal `[dry-run] <cmd>` line, so it must
# stay byte-stable (no timestamp / level / JSON). Unifies the inline
# `if DRY_RUN; then printf '[dry-run] ...'` blocks the wrappers used to
# duplicate. Refs #408 (sub-task B).
_dry_run_cmd() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# ── TRACEPARENT scoped wrappers ────────────────────────────────────

_log_with_trace() {
  local _prev_tp="${TRACEPARENT:-}"
  local _trace_id
  _trace_id="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local _span_id
  _span_id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export TRACEPARENT="00-${_trace_id}-${_span_id}-01"
  printf '[trace started: %s]\n' "${_trace_id}" >&2
  "$@"
  local _rc=$?
  if [[ -n "${_prev_tp}" ]]; then
    export TRACEPARENT="${_prev_tp}"
  else
    unset TRACEPARENT
  fi
  return "${_rc}"
}

_log_with_span() {
  local _span_name="${1:?_log_with_span requires span_name}"
  shift
  local _prev_tp="${TRACEPARENT:-}"
  local _trace_id=""
  if [[ -n "${_prev_tp}" ]]; then
    IFS=- read -r _ _trace_id _ _ <<< "${_prev_tp}"
  else
    _trace_id="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  local _span_id
  _span_id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  export TRACEPARENT="00-${_trace_id}-${_span_id}-01"
  "$@"
  local _rc=$?
  if [[ -n "${_prev_tp}" ]]; then
    export TRACEPARENT="${_prev_tp}"
  else
    unset TRACEPARENT
  fi
  return "${_rc}"
}
