#!/usr/bin/env bash
#
# transcript.sh - wrapper transcript capture.
#
# For non-interactive container-ops verbs (build / setup / stop / prune /
# upgrade) this tees the wrapper's combined stdout+stderr to a plaintext
# transcript under `log/<verb>/<UTC-ts>-<traceid8>.log` (ANSI stripped),
# maintains a per-verb `latest.log` symlink, and on exit appends the exit
# code + duration. Interactive verbs (run / exec / setup-tui) are NOT
# captured in this slice -- they produce no file (the orchestration-only
# `_transcript_detach` is).
#
# Sourced by _lib.sh AFTER log.sh (it is the producer of the
# `_LOG_IS_TTY` cache: it freezes the run's real TTY-ness before the tee
# rewraps fd1, so log.sh keeps emitting colour text to the terminal while
# the file gets a stripped copy -- see ADR-00000007) and after conf.sh
# (it reads the `[logging] wrapper_transcript*` keys from setup.conf).
#
# EXIT ownership (decision A): transcript.sh installs the single
# process EXIT trap and exposes `_atexit <fn>` for wrappers to register
# cleanups, instead of each wrapper calling `trap ... EXIT` (which would
# clobber the transcript finalize). The handler runs registered cleanups
# (LIFO) then finalizes the transcript.
#
# Failure-safe: if the log dir cannot be created or `tee` is unavailable,
# it WARNs and no-ops without blocking the wrapper.
#
# Refs:    ADR-00000007.

if [[ -n "${_DOCKER_LIB_TRANSCRIPT_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_TRANSCRIPT_SOURCED=1

# Shared glog-style rotate/symlink/prune primitives. The
# "repoint the stable symlink + prune per-start files by keep/days" logic
# is shared with the container-log tee (runtime/logging.sh) rather than
# duplicated here. Sourced via the sibling runtime/ dir (host-side path).
# Defensive: the shellcheck /lint image stage flattens lib/ alone (no
# runtime/ sibling), so a missing helper must NOT abort the wrapper under
# set -e -- the finalize path guards each call with `declare -F`.
_transcript_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
if [[ -r "${_transcript_lib_dir}/../runtime/logrotate.sh" ]]; then
  # shellcheck source=dist/script/docker/runtime/logrotate.sh
  source "${_transcript_lib_dir}/../runtime/logrotate.sh"
fi
unset _transcript_lib_dir

# Non-interactive verbs: full output captured end-to-end (no detach).
_TRANSCRIPT_FULL_VERBS=" build setup stop prune upgrade "

# Interactive verbs: capture the orchestration phase, then the
# wrapper calls _transcript_detach before handing the terminal to the
# interactive docker/TUI process so the session itself is not captured.
# (run -d is non-interactive and never detaches -> full capture.)
_TRANSCRIPT_INTERACTIVE_VERBS=" run exec setup_tui "

# ── atexit registry (decision A) ───────────────────────────────

# _transcript_install_trap
#   Install the single process EXIT trap once. Called on demand -- by
#   _transcript_setup when it activates, or by _atexit on first use --
#   never unconditionally, so merely sourcing _lib.sh (a unit spec) does
#   not replace bats' own EXIT trap.
_transcript_install_trap() {
  [[ -n "${_TRANSCRIPT_TRAP_INSTALLED:-}" ]] && return 0
  trap '_transcript_exit_handler' EXIT
  _TRANSCRIPT_TRAP_INSTALLED=1
}

# _atexit <fn>
#   Register a cleanup function to run on process exit. transcript.sh
#   owns the single EXIT trap; wrappers register here instead of calling
#   `trap ... EXIT` so the transcript finalize is never clobbered.
#   Callbacks run in LIFO order; each is best-effort (errors ignored).
_atexit() {
  local _fn="${1:?_atexit requires a function name}"
  _ATEXIT_FNS+=("${_fn}")
  _transcript_install_trap
}
# Guard: declare once (re-source returns early above, but be explicit).
if ! declare -p _ATEXIT_FNS >/dev/null 2>&1; then
  _ATEXIT_FNS=()
fi

# ── Pure helpers (unit-tested) ──────────────────────────────────────

# _transcript_repo_root
#   The repo root the `log/` tree lives under: FILE_PATH (wrappers via
#   bootstrap), else REPO_ROOT (upgrade.sh), else cwd.
_transcript_repo_root() {
  printf '%s' "${FILE_PATH:-${REPO_ROOT:-${PWD}}}"
}

# _transcript_is_full_verb <verb>
#   True when <verb> is a full-capture non-interactive verb.
_transcript_is_full_verb() {
  local _verb="${1:-}"
  [[ -n "${_verb}" ]] || return 1
  [[ "${_TRANSCRIPT_FULL_VERBS}" == *" ${_verb} "* ]]
}

# _transcript_is_interactive_verb <verb>
#   True when <verb> captures orchestration then detaches.
_transcript_is_interactive_verb() {
  local _verb="${1:-}"
  [[ -n "${_verb}" ]] || return 1
  [[ "${_TRANSCRIPT_INTERACTIVE_VERBS}" == *" ${_verb} "* ]]
}

# _transcript_is_capture_verb <verb>
#   True when <verb> is captured at all (full or interactive). Gates
#   activation in _transcript_begin; the wrapper decides whether/when to
#   _transcript_detach.
_transcript_is_capture_verb() {
  _transcript_is_full_verb "${1:-}" || _transcript_is_interactive_verb "${1:-}"
}

# _transcript_conf <key> <default>
#   Read a `[logging] <key> = <value>` scalar from the repo's setup.conf,
#   falling back to <default> when the file or key is absent. Minimal
#   grep (the wrapper_transcript* keys are unique within setup.conf) so
#   the source-time path stays dependency-light and failure-safe.
_transcript_conf() {
  local _key="${1:?}" _default="${2:-}"
  local _conf
  _conf="$(_transcript_repo_root)/.setup.conf"
  [[ -f "${_conf}" ]] || { printf '%s' "${_default}"; return 0; }
  local _line
  _line="$(grep -E "^[[:space:]]*${_key}[[:space:]]*=" "${_conf}" 2>/dev/null | tail -n1)"
  if [[ -z "${_line}" ]]; then
    printf '%s' "${_default}"
    return 0
  fi
  local _val="${_line#*=}"
  # trim surrounding whitespace
  _val="${_val#"${_val%%[![:space:]]*}"}"
  _val="${_val%"${_val##*[![:space:]]}"}"
  printf '%s' "${_val}"
}

# _transcript_enabled
#   True when the wrapper transcript is not switched off. The WRAPPER_TRANSCRIPT
#   env var wins when set (true/false) -- it lets CI / the self-test suite
#   disable transcripts without a setup.conf (so wrapper specs never write a
#   log/ tree into the checkout,) and lets a user toggle it ad-hoc without
#   editing a file that is committed and shared. Empty means unset (the way a
#   caller clears an inherited value). Otherwise falls back to
#   `[logging] wrapper_transcript` (default true).
#
#   This override outranks a key the user configured and can read back in
#   `setup.sh show`, so anything that is neither true nor false is FATAL
#   rather than a quiet fall-through to that key: a typo'd kill switch that
#   silently leaves capture on is exactly the outcome the override exists to
#   prevent. The precedence is documented next to the conf key (README
#   "Wrapper transcripts", dist/.setup.conf [logging]).
_transcript_enabled() {
  case "${WRAPPER_TRANSCRIPT:-}" in
    false) return 1 ;;
    true)  return 0 ;;
    "")    ;;
    *)
      _log_fatal "${_WRAPPER_VERB:-wrapper}" transcript_env_invalid \
        "display=WRAPPER_TRANSCRIPT must be true or false (got '${WRAPPER_TRANSCRIPT}'); it overrides [logging] wrapper_transcript, so a value it cannot read is refused rather than ignored" \
        "value=${WRAPPER_TRANSCRIPT}"
      exit 1
      ;;
  esac
  [[ "$(_transcript_conf wrapper_transcript true)" != false ]]
}

# _transcript_resolve_traceid <outvar>
#   Resolve the 32-hex run trace id: reuse an inherited TRACEPARENT
#   trace_id (parent/child share one trace) when present and well-formed,
#   otherwise mint one. Sets <outvar> to the trace id and exports
#   _TRANSCRIPT_TRACE_SOURCE=inherited|generated for event logging.
_transcript_resolve_traceid() {
  # Internal var name must NOT collide with the caller's outvar (a nameref
  # to a same-named variable is circular under set -u); use _rid.
  local -n _out="${1:?}"
  local _rid=""
  if [[ -n "${TRACEPARENT:-}" ]]; then
    IFS=- read -r _ _rid _ _ <<< "${TRACEPARENT}"
  fi
  if [[ "${_rid}" =~ ^[0-9a-f]{32}$ ]]; then
    _TRANSCRIPT_TRACE_SOURCE=inherited
  else
    _rid="$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    _TRANSCRIPT_TRACE_SOURCE=generated
  fi
  _out="${_rid}"
}

# _transcript_filename <root> <verb> <ts> <traceid8>
#   The transcript path: <root>/log/<verb>/<ts>-<traceid8>.log.
_transcript_filename() {
  printf '%s/log/%s/%s-%s.log' "${1}" "${2}" "${3}" "${4}"
}

# _transcript_meta_line <level> <msg>
#   Format a transcript meta line as `<ISO ts> [<verb>] <LEVEL>: <msg>`
#   so's lnav format parses it like a real log line. Meta lines are
#   written to the transcript FILE only -- never the terminal -- so a run
#   produces no extra on-screen output and existing wrapper output stays
#   byte-identical. (Genuine setup FAILURES still WARN to stderr.)
_transcript_meta_line() {
  local _level="${1}" _msg="${2}"
  local _ts
  _ts="$(date -u '+%Y-%m-%dT%H:%M:%S.%6NZ' 2>/dev/null || printf 'unknown')"
  printf '%s [%s] %-5s: %s\n' "${_ts}" "${_WRAPPER_VERB:-?}" "${_level}" "${_msg}"
}

# _transcript_strip_ansi <src> <dst>
#   Copy <src> to <dst> with ANSI SGR / CSI escape sequences removed.
_transcript_strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' "${1}" > "${2}"
}

# _transcript_prune <verb_dir> <keep> <days>
#   Retention: in <verb_dir>, keep at most <keep> most-recent *.log files
#   AND drop any older than <days> days -- the stricter of the two wins.
#   Never touches the `latest.log` symlink. Failure-safe (best-effort).
#   Thin wrapper over the shared _logrotate_prune: the
#   transcript's stable symlink is `latest.log`.
_transcript_prune() {
  local _dir="${1:?}" _keep="${2:-20}" _days="${3:-14}"
  declare -F _logrotate_prune >/dev/null 2>&1 || return 0
  _logrotate_prune "${_dir}" "latest.log" "${_keep}" "${_days}"
}

# ── EXIT handler ────────────────────────────────────────────────────

# _transcript_exit_handler
#   The single EXIT trap. Runs registered _atexit callbacks (LIFO), then
#   finalizes an active transcript: append the exit-code + duration line,
#   restore the original fds (closing the tee pipe -> EOF), wait on the
#   tee so the file is flushed (not truncated), strip ANSI into the final
#   file, point latest.log at it, and prune.
_transcript_exit_handler() {
  local _rc=$?
  local _i
  for (( _i=${#_ATEXIT_FNS[@]}-1; _i>=0; _i-- )); do
    "${_ATEXIT_FNS[_i]}" || true
  done

  if [[ -n "${_TRANSCRIPT_ACTIVE:-}" ]]; then
    local _dur=0
    if [[ -n "${_TRANSCRIPT_START:-}" ]]; then
      local _end
      _end="$(date +%s 2>/dev/null || printf '0')"
      (( _end > 0 )) && _dur=$(( _end - _TRANSCRIPT_START ))
    fi
    _transcript_finalize "transcript_complete exit_code=${_rc} duration=${_dur}s"
  fi
  return "${_rc}"
}

# _transcript_finalize <closing_msg>
#   Shared teardown for both the EXIT handler and _transcript_detach:
#   restore the original fds (closing each tee's input -> EOF), wait both
#   tees so the raw capture is flushed (not truncated), append <closing_msg>
#   to the file (file-only, ordered last), strip ANSI into the final
#   transcript, repoint latest.log, prune, and mark inactive. Best-effort.
_transcript_finalize() {
  local _closing="${1:-}"
  exec 1>&"${_TRANSCRIPT_ORIG_OUT}" 2>&"${_TRANSCRIPT_ORIG_ERR}"
  exec {_TRANSCRIPT_ORIG_OUT}>&- 2>/dev/null || true
  exec {_TRANSCRIPT_ORIG_ERR}>&- 2>/dev/null || true
  if [[ -n "${_TRANSCRIPT_TEE_OUT_PID:-}" ]]; then
    wait "${_TRANSCRIPT_TEE_OUT_PID}" 2>/dev/null || true
  fi
  if [[ -n "${_TRANSCRIPT_TEE_ERR_PID:-}" ]]; then
    wait "${_TRANSCRIPT_TEE_ERR_PID}" 2>/dev/null || true
  fi
  if [[ -n "${_closing}" ]]; then
    _transcript_meta_line "INFO" "${_closing}" >> "${_TRANSCRIPT_RAW}" 2>/dev/null || true
  fi
  if [[ -f "${_TRANSCRIPT_RAW:-}" ]]; then
    if _transcript_strip_ansi "${_TRANSCRIPT_RAW}" "${_TRANSCRIPT_FILE}" 2>/dev/null; then
      rm -f -- "${_TRANSCRIPT_RAW}" 2>/dev/null
    else
      mv -f -- "${_TRANSCRIPT_RAW}" "${_TRANSCRIPT_FILE}" 2>/dev/null || true
    fi
    if declare -F _logrotate_repoint >/dev/null 2>&1; then
      _logrotate_repoint "${_TRANSCRIPT_FILE}" "latest.log"
    fi
  fi
  _transcript_prune "$(dirname -- "${_TRANSCRIPT_FILE}")" \
    "${_TRANSCRIPT_KEEP:-20}" "${_TRANSCRIPT_DAYS:-14}"
  _TRANSCRIPT_ACTIVE=""
}

# _transcript_detach
#   Stop capturing BEFORE an interactive verb (run attached / exec /
#   setup_tui) hands the terminal to the interactive docker/TUI process,
#   so the orchestration phase up to this point IS captured but the
#   interactive session is NOT. Finalizes the transcript early (the run's
#   exit code is not yet known) with a transcript_detached closing line.
#   No-op when the transcript is not active (e.g. run -d full-captures and
#   never detaches, or the feature is disabled).
_transcript_detach() {
  [[ -n "${_TRANSCRIPT_ACTIVE:-}" ]] || return 0
  local _dur=0
  if [[ -n "${_TRANSCRIPT_START:-}" ]]; then
    local _end
    _end="$(date +%s 2>/dev/null || printf '0')"
    (( _end > 0 )) && _dur=$(( _end - _TRANSCRIPT_START ))
  fi
  _transcript_finalize \
    "transcript_detached duration=${_dur}s (interactive session not captured)"
}

# ── Source-time setup ───────────────────────────────────────────────

# _transcript_begin
#   Activate the tee when the verb is a full-capture verb and the feature
#   is enabled. Caches _LOG_IS_TTY before rewrapping fd1, opens the
#   raw capture, and redirects fd1+fd2 through a single `tee`. Any failure
#   leaves the transcript inactive (WARN + no-op); the wrapper runs on.
#
#   Called EXPLICITLY as the first line of each non-interactive verb's
#   main -- NOT at _lib.sh source time -- so a unit spec that merely
#   sources a wrapper (to test its functions, without calling main) never
#   activates the tee in the bats shell.
_transcript_begin() {
  local _verb="${_WRAPPER_VERB:-}"

  # Freeze the real TTY-ness now, before any tee rewraps fd1, so log.sh's
  # auto format/colour follows the terminal, not the pipe. Use an
  # `if` so the non-TTY `test -t` (exit 1) does not trip the caller's
  # `set -e` at source time.
  if test -t 1; then _LOG_IS_TTY=0; else _LOG_IS_TTY=1; fi
  export _LOG_IS_TTY

  _transcript_is_capture_verb "${_verb}" || return 0
  # Kill switch: complete no-op (no file, no terminal output).
  _transcript_enabled || return 0
  command -v tee >/dev/null 2>&1 || {
    _log_warn "${_verb}" transcript_tee_missing || true
    return 0
  }

  local _root _dir _ts _tid
  _root="$(_transcript_repo_root)"
  _dir="${_root}/log/${_verb}"
  if ! mkdir -p -- "${_dir}" 2>/dev/null; then
    _log_warn "${_verb}" transcript_dir_create_failed || true
    return 0
  fi

  _transcript_resolve_traceid _tid
  _ts="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || printf 'unknown')"
  _TRANSCRIPT_FILE="$(_transcript_filename "${_root}" "${_verb}" "${_ts}" "${_tid:0:8}")"
  _TRANSCRIPT_RAW="${_TRANSCRIPT_FILE}.raw"

  if ! : > "${_TRANSCRIPT_RAW}" 2>/dev/null; then
    _log_warn "${_verb}" transcript_file_unwritable || true
    return 0
  fi

  _TRANSCRIPT_KEEP="$(_transcript_conf wrapper_transcript_keep 20)"
  _TRANSCRIPT_DAYS="$(_transcript_conf wrapper_transcript_days 14)"
  # Positive integers only (>= 1): mirror the validator's ^[1-9][0-9]*$
  # so a hand-edited setup.conf that the Apply/read path never revalidates
  # cannot reach prune with keep=0 (which would wipe every transcript) or
  # days=0 (drop everything by age). Out-of-range -> documented default.
  [[ "${_TRANSCRIPT_KEEP}" =~ ^[1-9][0-9]*$ ]] || _TRANSCRIPT_KEEP=20
  [[ "${_TRANSCRIPT_DAYS}" =~ ^[1-9][0-9]*$ ]] || _TRANSCRIPT_DAYS=14
  _TRANSCRIPT_START="$(date +%s 2>/dev/null || printf '0')"

  # Header meta lines: written directly to the capture (file only).
  {
    _transcript_meta_line "INFO" "transcript_started verb=${_verb} trace_id=${_tid}"
    _transcript_meta_line "DEBUG" "transcript_trace_${_TRANSCRIPT_TRACE_SOURCE:-generated}"
  } >> "${_TRANSCRIPT_RAW}" 2>/dev/null || true

  # Own the EXIT trap now that we are activating (so finalize runs).
  _transcript_install_trap

  # Save the original fds, then give fd1 and fd2 each their OWN tee that
  # copies to the raw capture AND back to the matching original fd. Two
  # tees (not `>(tee) 2>&1`) so the terminal keeps stdout/stderr SEPARATE
  # and a caller's stream redirection (e.g. `just build 2>err`) is not
  # collapsed; both streams still land in the one transcript file.
  exec {_TRANSCRIPT_ORIG_OUT}>&1 {_TRANSCRIPT_ORIG_ERR}>&2
  exec 1> >(tee -a -- "${_TRANSCRIPT_RAW}" >&"${_TRANSCRIPT_ORIG_OUT}")
  _TRANSCRIPT_TEE_OUT_PID=$!
  exec 2> >(tee -a -- "${_TRANSCRIPT_RAW}" >&"${_TRANSCRIPT_ORIG_ERR}")
  _TRANSCRIPT_TEE_ERR_PID=$!
  _TRANSCRIPT_ACTIVE=1
}

# Activation is NOT done at source time. Each non-interactive verb's
# main calls `_transcript_begin` as its first statement; the EXIT trap
# is installed on demand from there (or by _atexit). This keeps merely
# sourcing _lib.sh (a unit spec, or a wrapper sourced to test its
# functions) free of any tee redirect or EXIT-trap clobbering.
