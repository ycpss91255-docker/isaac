#!/usr/bin/env bash
# stream_smoke_lib.sh -- pass/fail decision logic for the Tier A stream
# smoke (isaac#233). Sourced by script/ci/stream_smoke.sh; baked into
# /smoke_test/ next to stream_smoke_lib_spec.bats by the devel-test stage.
#
# Everything here is GPU-free and side-effect-free (reads a Kit log, calls
# the `smoke_alive` hook, sleeps). That is deliberate: the GPU path stays
# nightly-only, but the assertions it makes are unit-tested on every build
# (test/bats/smoke/stream_smoke_lib_spec.bats).
#
# Why it exists: before #233 the smoke asserted only "Streaming server
# started." -- a liveness probe. "Port is listening" and "streaming
# actually works" are different claims, and a Kit that dies the moment a
# client attaches (e.g. the media pipeline allocating into a 64 MB private
# /dev/shm) satisfied the first while failing the second.
#
# Observed healthy attach sequence on the GPU host:
#   NetStreamServer::onSignalingHeaders numHeaders: N
#   Stream server: connected stream ...
#   onClientEventRaised: NVST_CCE_CONNECTED
#   Stream Server: stream0/1/2 ... started
#   All Streams connected.
# Teardown/disconnect shows NVST_CCE_DISCONNECTED and
# "Stream Server: streamN ... stopped" -- the drop markers below.
#
# Contract of the exit codes (callers map them to messages):
#   smoke_wait_for : 0 reached | 1 timeout          | 2 liveness lost
#   smoke_dwell    : 0 survived | 2 liveness lost    | 3 streams dropped
#
# Env knobs:
#   SMOKE_DROP_REGEX  ERE for a stream drop (default below)

# ERE matched against kit log lines after the connect anchor. Either the
# client-event disconnect or an individual stream stopping counts as the
# stream going away mid-dwell.
if [[ -z "${SMOKE_DROP_REGEX:-}" ]]; then
  SMOKE_DROP_REGEX='NVST_CCE_DISCONNECTED'
  SMOKE_DROP_REGEX+='|Stream Server: stream[0-9]+.*stopped'
fi

# Liveness hook. Fail-closed on purpose: a caller that forgets to bind a
# real probe must make the smoke FAIL, never silently assume the container
# is up -- a silent pass on a dead Kit is the bug #233 fixes.
# stream_smoke.sh overrides this with a `docker inspect ${cid}` running-state
# check (the container is resolved by compose project id); specs stub it.
smoke_alive() {
  echo "[smoke] smoke_alive: no liveness probe bound (caller must override)" >&2
  return 1
}

# Print the 1-based line number of the first fixed-string match of
# <marker> in <log>.
#
# Usage: smoke_marker_line <log> <marker>
# Returns: 0 + line number on stdout; 1 if absent or the log is missing.
smoke_marker_line() {
  local _log="${1:?smoke_marker_line: missing log}"
  local _marker="${2:?smoke_marker_line: missing marker}"
  local _line=""
  [[ -f "${_log}" ]] || return 1
  _line="$(grep -nF -m1 -e "${_marker}" "${_log}" 2>/dev/null | cut -d: -f1)"
  [[ -n "${_line}" ]] || return 1
  printf '%s\n' "${_line}"
}

# Assert <marker...> appear in <log> in the given order, each strictly
# after the previous one.
#
# Usage: smoke_sequence_line <log> <marker> [<marker>...]
# Returns: 0 + the line number of the LAST marker on stdout; 1 with the
#          first unmet marker named on stderr (also 1 on misuse: no
#          markers, or a missing log -- misuse must never read as a pass).
smoke_sequence_line() {
  local _log="${1:?smoke_sequence_line: missing log}"
  shift
  if (( $# == 0 )); then
    echo "[smoke] smoke_sequence_line: no markers given" >&2
    return 1
  fi
  if [[ ! -f "${_log}" ]]; then
    echo "[smoke] smoke_sequence_line: no kit log at ${_log}" >&2
    return 1
  fi
  local _from=0 _marker="" _rel=""
  for _marker in "$@"; do
    _rel="$(tail -n "+$(( _from + 1 ))" "${_log}" \
      | grep -nF -m1 -e "${_marker}" | cut -d: -f1)"
    if [[ -z "${_rel}" ]]; then
      printf '[smoke] missing marker (in order): %s\n' "${_marker}" >&2
      return 1
    fi
    _from=$(( _from + _rel ))
  done
  printf '%s\n' "${_from}"
}

# Print the 1-based line number of the first stream-drop marker occurring
# strictly after <after_line>. The anchor keeps a previous session's
# teardown (or this run's own pre-connect noise) from failing the dwell.
#
# Usage: smoke_drop_line <log> [<after_line>]
# Returns: 0 + line number on stdout; 1 if no drop after the anchor.
smoke_drop_line() {
  local _log="${1:?smoke_drop_line: missing log}"
  local _after="${2:-0}"
  [[ -f "${_log}" ]] || return 1
  awk -v after="${_after}" -v re="${SMOKE_DROP_REGEX}" '
    NR <= after { next }
    $0 ~ re     { print NR; found = 1; exit }
    END         { if (!found) exit 1 }
  ' "${_log}"
}

# Print the tail of the Kit log, framed, for failure attribution. Never
# fails: it runs on error paths where the log may not exist at all.
#
# Usage: smoke_log_tail <log> [<lines>]
# Returns: always 0.
smoke_log_tail() {
  local _log="${1:?smoke_log_tail: missing log}"
  local _n="${2:-60}"
  printf -- '---- kit log tail (%s, last %s lines) ----\n' "${_log}" "${_n}"
  if [[ -f "${_log}" ]]; then
    tail -n "${_n}" "${_log}" || true
  else
    printf '(no kit log at %s)\n' "${_log}"
  fi
  printf -- '---- end kit log tail ----\n'
}

# Poll <log> until <marker...> appear in order, bounded by <timeout_s>.
# Liveness is re-checked every tick so a dead Kit is reported as a death
# (rc 2) rather than being mistaken for a slow one (rc 1).
#
# Usage: smoke_wait_for <log> <timeout_s> <poll_s> <marker> [<marker>...]
# Returns: 0 sequence reached | 1 timeout | 2 liveness lost.
smoke_wait_for() {
  local _log="${1:?smoke_wait_for: missing log}"
  local _timeout="${2:?smoke_wait_for: missing timeout}"
  local _poll="${3:?smoke_wait_for: missing poll}"
  shift 3
  local _deadline=$(( SECONDS + _timeout ))
  while :; do
    if ! smoke_alive; then
      echo "[smoke] wait: liveness lost before the sequence was reached" >&2
      return 2
    fi
    if smoke_sequence_line "${_log}" "$@" >/dev/null 2>&1; then
      return 0
    fi
    (( SECONDS < _deadline )) || break
    sleep "${_poll}"
  done
  smoke_sequence_line "${_log}" "$@" >/dev/null || true
  printf '[smoke] wait: sequence not reached within %ss\n' "${_timeout}" >&2
  return 1
}

# Hold the established connection for <dwell_s>, asserting on every tick
# that the process is still alive and that no stream has dropped since
# <anchor_line>. This is the assertion a boot-only smoke cannot make.
#
# Usage: smoke_dwell <log> <dwell_s> <poll_s> [<anchor_line>]
# Returns: 0 survived | 2 liveness lost | 3 streams dropped.
smoke_dwell() {
  local _log="${1:?smoke_dwell: missing log}"
  local _dwell="${2:?smoke_dwell: missing dwell}"
  local _poll="${3:?smoke_dwell: missing poll}"
  local _anchor="${4:-0}"
  local _start="${SECONDS}"
  local _deadline=$(( SECONDS + _dwell ))
  local _drop=""
  while (( SECONDS < _deadline )); do
    sleep "${_poll}"
    if ! smoke_alive; then
      printf '[smoke] dwell: process died after %ss of the %ss window\n' \
        "$(( SECONDS - _start ))" "${_dwell}" >&2
      return 2
    fi
    if _drop="$(smoke_drop_line "${_log}" "${_anchor}")"; then
      printf '[smoke] dwell: streams dropped at line %s, %ss into %ss\n' \
        "${_drop}" "$(( SECONDS - _start ))" "${_dwell}" >&2
      return 3
    fi
  done
  return 0
}
