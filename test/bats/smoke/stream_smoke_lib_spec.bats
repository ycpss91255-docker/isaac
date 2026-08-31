#!/usr/bin/env bats
#
# Unit guard for script/ci/stream_smoke_lib.sh -- the pass/fail decision
# logic of the Tier A stream smoke (#233).
#
# Why a library: before #233 the smoke only waited for "Streaming server
# started." and exited 0. A Kit that boots, opens the signaling socket and
# then dies the moment a real client attaches passed green. The new probe
# attaches a client, asserts the stream-start sequence, then holds a dwell
# window asserting the Kit is still alive and the streams have not stopped.
# That decision logic is GPU-free, so it lives in a sourceable library and
# is unit-tested here; the GPU path itself stays nightly-only.
#
# The liveness probe is the overridable `smoke_alive` hook: the real script
# binds it to `docker ps`, these specs bind it to stubs (including one that
# flips to dead mid-dwell, which is the exact regression #233 is about).
#
# Baked into /smoke_test/ next to host_yaml.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=/dev/null
  source "${BATS_TEST_DIRNAME}/stream_smoke_lib.sh"
  LOG="$(mktemp)"
  STATE="$(mktemp -d)"
}

teardown() {
  rm -f "${LOG}"
  rm -rf "${STATE}"
}

# A healthy client attach, as observed on the GPU host (#233):
#   onSignalingHeaders -> connected stream -> NVST_CCE_CONNECTED ->
#   streamN started -> All Streams connected.
write_connected_log() {
  cat > "${LOG}" <<'LOG'
[carb.livestream-rtc.plugin] Streaming server started.
[carb] NetStreamServer::onSignalingHeaders numHeaders: 12
[carb] Stream server: connected stream 0
[carb] onClientEventRaised: NVST_CCE_CONNECTED
[carb] Stream Server: stream0 (video) started
[carb] Stream Server: stream1 (audio) started
[carb] Stream Server: stream2 (input) started
[carb] All Streams connected.
LOG
}

# Stub liveness: alive for the first ${1} calls, dead afterwards. Used to
# simulate a Kit that is SIGKILLed part-way through the dwell window.
alive_for() {
  local _n="$1"
  printf '0\n' > "${STATE}/calls"
  smoke_alive() {
    local _c
    _c="$(cat "${STATE}/calls")"
    _c=$(( _c + 1 ))
    printf '%s\n' "${_c}" > "${STATE}/calls"
    [ "${_c}" -le "${_n}" ]
  }
}

# ── smoke_marker_line ───────────────────────────────────────────────────────

@test "marker_line: present marker prints its 1-based line number" {
  write_connected_log
  run --separate-stderr smoke_marker_line "${LOG}" 'All Streams connected.'
  [ "$status" -eq 0 ]
  [ "${output}" = "8" ]
}

@test "marker_line: absent marker -> rc 1, no stdout" {
  write_connected_log
  run --separate-stderr smoke_marker_line "${LOG}" 'No Such Marker'
  [ "$status" -eq 1 ]
  [ -z "${output}" ]
}

@test "marker_line: missing log file -> rc 1 (no crash)" {
  run --separate-stderr smoke_marker_line "${STATE}/absent.log" 'anything'
  [ "$status" -eq 1 ]
}

# ── smoke_sequence_line ─────────────────────────────────────────────────────

@test "sequence_line: in-order markers -> rc 0 + line of the LAST marker" {
  write_connected_log
  run --separate-stderr smoke_sequence_line "${LOG}" \
    'NetStreamServer::onSignalingHeaders' 'NVST_CCE_CONNECTED' \
    'All Streams connected.'
  [ "$status" -eq 0 ]
  [ "${output}" = "8" ]
}

@test "sequence_line: out-of-order markers -> rc 1 naming the unmet marker" {
  write_connected_log
  # 'All Streams connected.' precedes the headers line only if asked for in
  # the wrong order -- the second marker must be found AFTER the first.
  run --separate-stderr smoke_sequence_line "${LOG}" \
    'All Streams connected.' 'NetStreamServer::onSignalingHeaders'
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *"NetStreamServer::onSignalingHeaders"* ]]
}

@test "sequence_line: truncated attach (no All Streams connected.) -> rc 1" {
  # The exact half-connect a boot-only Tier A used to pass green.
  cat > "${LOG}" <<'LOG'
[carb.livestream-rtc.plugin] Streaming server started.
[carb] NetStreamServer::onSignalingHeaders numHeaders: 12
LOG
  run --separate-stderr smoke_sequence_line "${LOG}" \
    'NetStreamServer::onSignalingHeaders' 'All Streams connected.'
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *"All Streams connected."* ]]
}

@test "sequence_line: no markers given -> rc 1 (misuse is not a pass)" {
  write_connected_log
  run --separate-stderr smoke_sequence_line "${LOG}"
  [ "$status" -eq 1 ]
}

# ── smoke_drop_line ─────────────────────────────────────────────────────────

@test "drop_line: NVST_CCE_DISCONNECTED after the anchor -> rc 0 + line" {
  write_connected_log
  printf '[carb] onClientEventRaised: NVST_CCE_DISCONNECTED\n' >> "${LOG}"
  run --separate-stderr smoke_drop_line "${LOG}" 8
  [ "$status" -eq 0 ]
  [ "${output}" = "9" ]
}

@test "drop_line: 'Stream Server: streamN ... stopped' after anchor -> rc 0" {
  write_connected_log
  printf '[carb] Stream Server: stream0 (video) stopped\n' >> "${LOG}"
  run --separate-stderr smoke_drop_line "${LOG}" 8
  [ "$status" -eq 0 ]
  [ "${output}" = "9" ]
}

@test "drop_line: a drop BEFORE the anchor is ignored (stale prior session)" {
  # A previous client's teardown must not fail this run's dwell.
  printf '[carb] onClientEventRaised: NVST_CCE_DISCONNECTED\n' > "${LOG}"
  printf '[carb] All Streams connected.\n' >> "${LOG}"
  run --separate-stderr smoke_drop_line "${LOG}" 2
  [ "$status" -eq 1 ]
}

@test "drop_line: healthy connected log -> rc 1 (nothing dropped)" {
  write_connected_log
  run --separate-stderr smoke_drop_line "${LOG}" 8
  [ "$status" -eq 1 ]
}

# ── smoke_alive (fail-closed default) ───────────────────────────────────────

@test "alive: default hook is fail-closed (never a silent pass)" {
  # If a caller forgets to bind a real liveness probe the smoke must FAIL,
  # not assume the container is up.
  run --separate-stderr smoke_alive
  [ "$status" -ne 0 ]
}

# ── smoke_wait_for ──────────────────────────────────────────────────────────

@test "wait_for: sequence already complete -> rc 0 without waiting" {
  write_connected_log
  smoke_alive() { return 0; }
  run --separate-stderr smoke_wait_for "${LOG}" 0 1 \
    'NetStreamServer::onSignalingHeaders' 'All Streams connected.'
  [ "$status" -eq 0 ]
}

@test "wait_for: sequence never appears -> rc 1 (timeout)" {
  write_connected_log
  smoke_alive() { return 0; }
  run --separate-stderr smoke_wait_for "${LOG}" 1 1 'Never Appears'
  [ "$status" -eq 1 ]
}

@test "wait_for: Kit dies while waiting -> rc 2 (death, not timeout)" {
  write_connected_log
  smoke_alive() { return 1; }
  run --separate-stderr smoke_wait_for "${LOG}" 5 1 'Never Appears'
  [ "$status" -eq 2 ]
}

# ── smoke_dwell (the #233 regression surface) ───────────────────────────────

@test "dwell: alive + no drop for the whole window -> rc 0" {
  write_connected_log
  smoke_alive() { return 0; }
  run --separate-stderr smoke_dwell "${LOG}" 2 1 8
  [ "$status" -eq 0 ]
}

@test "dwell: Kit SIGKILLed mid-dwell -> rc 2 (the #233 bug)" {
  write_connected_log
  alive_for 1
  run --separate-stderr smoke_dwell "${LOG}" 3 1 8
  [ "$status" -eq 2 ]
  [[ "${stderr}" == *"died"* ]]
}

@test "dwell: streams stop mid-dwell -> rc 3" {
  write_connected_log
  smoke_alive() { return 0; }
  # Drop lands after the first poll tick.
  ( sleep 1; printf '[carb] Stream Server: stream0 (video) stopped\n' >> "${LOG}" ) &
  run --separate-stderr smoke_dwell "${LOG}" 4 1 8
  wait
  [ "$status" -eq 3 ]
  [[ "${stderr}" == *"dropped"* ]]
}

@test "dwell: a pre-anchor drop does not fail the window" {
  printf '[carb] onClientEventRaised: NVST_CCE_DISCONNECTED\n' > "${LOG}"
  printf '[carb] All Streams connected.\n' >> "${LOG}"
  smoke_alive() { return 0; }
  run --separate-stderr smoke_dwell "${LOG}" 2 1 2
  [ "$status" -eq 0 ]
}

# ── smoke_log_tail (failure reporting) ──────────────────────────────────────

@test "log_tail: prints the last N lines between markers" {
  write_connected_log
  run --separate-stderr smoke_log_tail "${LOG}" 2
  [ "$status" -eq 0 ]
  [[ "${output}" == *"All Streams connected."* ]]
  [[ "${output}" == *"kit log tail"* ]]
  # N is honoured: the first log line must not be in a 2-line tail.
  [[ "${output}" != *"Streaming server started."* ]]
}

@test "log_tail: missing log -> rc 0 and says so (teardown stays safe)" {
  run --separate-stderr smoke_log_tail "${STATE}/absent.log" 5
  [ "$status" -eq 0 ]
  [[ "${output}" == *"no kit log"* ]]
}
