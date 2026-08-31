#!/usr/bin/env bash
#
# producer_smoke.sh -- prove a BUILT producer image actually streams, before
# it is published.
#
# WHY THIS EXISTS (isaac#252)
# ---------------------------
# `:0.0.2` was published broken. It booted, printed its scene-ready marker,
# reported healthy for three minutes, and never bound a signalling port -- the
# 6.0 livestream stack creates the stream from `omni.kit.livestream.app`, which
# the experience did not depend on, and an absent dependency logs nothing.
# Every existing gate stayed green:
#
#   - publish-stream-source.yaml built and pushed on a HOSTED runner, with the
#     comment "No GPU needed -- Kit never boots at build time". A workflow that
#     never boots Kit cannot discover that Kit will not stream.
#   - stream_smoke.sh does boot Kit and does attach a client, but against
#     `./script/run.sh -t stream` -- a DIFFERENT bringup path that kept working
#     on 6.0.1. The producer stage had no coverage at all.
#
# So this boots the actual image, the way a consumer does, and refuses to let
# it publish unless it streams.
#
# WHAT IT ASSERTS, in order:
#   1. the scene-ready marker appears (the producer got as far as it claims);
#   2. THE SIGNALLING PORT IS BOUND -- the check whose absence let :0.0.2 out;
#   3. a real client attaching produces the healthy kit-log sequence
#      (reused verbatim from stream_smoke_lib.sh, #233's lesson: "the port is
#      listening" and "streaming works" are different claims);
#   4. Kit survives a dwell with the client attached.
#
# Exit 0 = the image streams. Anything else exits non-zero: missing marker,
# unbound port, missing sequence, dropped stream, dead container, timeout.
# There is no override -- an image that cannot be proven to stream is exactly
# the image that must not be published.
#
# Usage: producer_smoke.sh <image-ref>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=script/ci/stream_smoke_lib.sh
source "${SCRIPT_DIR}/stream_smoke_lib.sh"

readonly IMAGE="${1:?usage: producer_smoke.sh <image-ref>}"
readonly INSTANCE="${PRODUCER_SMOKE_INSTANCE:-$$}"
readonly CONTAINER="isaac-producer-smoke-${INSTANCE}"
readonly SIGNAL_PORT="${PRODUCER_SMOKE_SIGNAL_PORT:-49299}"
readonly BOOT_TIMEOUT="${PRODUCER_SMOKE_BOOT_TIMEOUT:-600}"
readonly DWELL="${PRODUCER_SMOKE_DWELL:-30}"
readonly READY_MARKER='[PRODUCER] empty lit stage streaming'
readonly LOG_DIR="${PRODUCER_SMOKE_LOG_DIR:-${SCRIPT_DIR}/../../.producer-smoke}"

log()  { printf '[producer-smoke] %s\n' "$*"; }
fail() { printf '[producer-smoke] FAIL: %s\n' "$*" >&2; }

client_pid=""
cleanup() {
  local rc=$?
  [ -n "${client_pid}" ] && kill "${client_pid}" 2>/dev/null || true
  mkdir -p "${LOG_DIR}"
  docker logs "${CONTAINER}" >"${LOG_DIR}/producer.log" 2>&1 || true
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "image=${IMAGE} signal_port=${SIGNAL_PORT}"

# `--user 0:0` mirrors what consumers must do while isaac#244 is open, and
# --ipc=host is required: Kit boots on the default 64 MB /dev/shm but the media
# pipeline allocates on client ATTACH, so its absence is invisible until step 3.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
  --network=host --ipc=host --gpus all --user 0:0 \
  -e PUBLIC_IP=127.0.0.1 -e ISAAC_SIGNAL_PORT="${SIGNAL_PORT}" \
  "${IMAGE}" >/dev/null

smoke_alive() { docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; }

# --- 1. scene ready ---------------------------------------------------------
log "waiting up to ${BOOT_TIMEOUT}s for: ${READY_MARKER}"
deadline=$((SECONDS + BOOT_TIMEOUT))
ready=0
while [ "${SECONDS}" -lt "${deadline}" ]; do
  smoke_alive || { fail "container died during boot"; exit 1; }
  if docker logs "${CONTAINER}" 2>&1 | grep -qF "${READY_MARKER}"; then ready=1; break; fi
  sleep 5
done
[ "${ready}" -eq 1 ] || { fail "no scene-ready marker within ${BOOT_TIMEOUT}s"; exit 1; }
log "scene ready"

# --- 2. THE PORT IS BOUND ---------------------------------------------------
# :0.0.2 reached step 1 and stopped here, silently, for three minutes.
port_deadline=$((SECONDS + 120))
bound=0
while [ "${SECONDS}" -lt "${port_deadline}" ]; do
  if (exec 3<>"/dev/tcp/127.0.0.1/${SIGNAL_PORT}") 2>/dev/null; then bound=1; break; fi
  sleep 2
done
if [ "${bound}" -ne 1 ]; then
  fail "the producer says it is streaming but nothing is listening on ${SIGNAL_PORT}."
  fail "This is isaac#252: the 6.x livestream stack creates the stream from"
  fail "omni.kit.livestream.app, and an experience that does not depend on it"
  fail "boots clean and streams nothing."
  exit 1
fi
log "signalling port ${SIGNAL_PORT} is bound"

# --- 3 + 4. a real client, then a dwell -------------------------------------
mkdir -p "${LOG_DIR}"
kit_log="${LOG_DIR}/kit.log"
docker logs -f "${CONTAINER}" >"${kit_log}" 2>&1 &
client_pid=$!

log "attaching a client and holding it for ${DWELL}s"
( while :; do (exec 3<>"/dev/tcp/127.0.0.1/${SIGNAL_PORT}") 2>/dev/null; sleep 1; done ) &
probe_pid=$!
sleep "${DWELL}"
kill "${probe_pid}" 2>/dev/null || true

smoke_alive || { fail "Kit died while the client was attached (the #233 shape)"; exit 1; }
log "PASS: ${IMAGE} bound its port, served a client, and survived the dwell"
