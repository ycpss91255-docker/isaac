#!/usr/bin/env bash
# stream_smoke.sh -- producer-side GPU smoke for the stream stage.
#
# Verifies the GPU-only path that hosted CI runners cannot: the Isaac Sim
# stream container boots, its WebRTC streaming server starts, AND it
# survives a real client attaching to it. No browser -- that is Tier B
# (#173). Runs on a GPU host or a self-hosted GPU runner.
#
# Flow: `./script/run.sh -t stream -d` (idle container + viewer via post-run
# hook) -> `docker exec -d runheadless-host-config.sh` (launch Isaac) ->
# wait for the "Streaming server started." marker in OUR Isaac's kit log ->
# attach a client to the signaling port -> wait for the stream-start
# sequence -> hold the connection for a dwell window asserting Kit stays
# alive and the streams do not stop -> PASS / FAIL -> tear down (always).
#
# Why the client attach exists (#233): until it did, this script asserted
# only that the server came up. "Port is listening" and "streaming actually
# works" are different claims. A Kit that boots, opens the signaling
# socket, then is SIGKILLed the moment the media pipeline allocates on
# first client attach (observed on the GPU host: a container left with only
# the default 64 MB private /dev/shm) satisfied the first claim while
# failing the second, and Tier A still went green. Any regression in the
# media path -- shm, encoder, GPU capability flags, device bindings -- was
# invisible.
#
# Readiness is asserted from OUR container's redirected kit log, not from a
# host port: the container runs with `network=host`, so `ss :PORT` would also
# match any unrelated Isaac left on the host (false pass), and the signaling
# socket binds early in startup -- before the stream server is actually up.
# `[carb.livestream-rtc.plugin] Streaming server started.` is the real
# "server up, waiting for a client" event and is scoped to our log.
#
# The pass/fail decision logic lives in stream_smoke_lib.sh so it is unit
# tested on every image build (test/smoke/bats/stream_smoke_lib_spec.bats)
# even though this GPU path only runs nightly.
#
# Env knobs:
#   SMOKE_TIMEOUT          seconds to wait for the server marker (default 600)
#   SMOKE_CONNECT_TIMEOUT  seconds to wait for the stream-start sequence
#                          after the client attaches (default 120)
#   SMOKE_DWELL            seconds to hold the connection (default 30)
#   SMOKE_POLL             poll interval for both waits (default 5)
#   SMOKE_LOG_TAIL         kit log lines printed on failure (default 60)
#   SMOKE_STREAM_MARKERS   newline-separated ordered kit-log markers that
#                          define "a client is really streaming"
#   SMOKE_CLIENT_CMD       shell command (run on the host, detached) that
#                          attaches the client; replaces the default probe
#   SMOKE_LIB              path to stream_smoke_lib.sh (default: alongside)
#   HOST_YAML_LIB          path to host_yaml.sh (default: ../host_yaml.sh)
#
# The default client probe is browser-free by design (a browser + rendered
# frame is Tier B): it performs the WebSocket upgrade handshake against the
# livestream signaling port from inside the container (network=host, so
# 127.0.0.1 is the same socket a host client would use) and holds the
# connection open for the whole window. Point SMOKE_CLIENT_CMD at a fuller
# WebRTC client if a deployment needs the media path driven further; the
# assertions below do not change.
#
# Exit 0 = a client streamed and Kit survived the dwell; 1 = container
# died / timed out / streams dropped (kit log tailed on every failure).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
timeout_s="${SMOKE_TIMEOUT:-600}"
connect_timeout_s="${SMOKE_CONNECT_TIMEOUT:-120}"
dwell_s="${SMOKE_DWELL:-30}"
poll_s="${SMOKE_POLL:-5}"
log_tail_n="${SMOKE_LOG_TAIL:-60}"
ready_marker='Streaming server started.'

# shellcheck source=stream_smoke_lib.sh
. "${SMOKE_LIB:-$(dirname "${BASH_SOURCE[0]}")/stream_smoke_lib.sh}"

# Ordered kit-log markers of a healthy attach, as observed on the GPU host:
# signaling headers received -> peer connected -> all streams up.
stream_markers=(
  'NetStreamServer::onSignalingHeaders'
  'NVST_CCE_CONNECTED'
  'All Streams connected.'
)
if [[ -n "${SMOKE_STREAM_MARKERS:-}" ]]; then
  mapfile -t stream_markers <<< "${SMOKE_STREAM_MARKERS}"
fi

# Identity + workspace from .env.generated (base A2 model), .env overlays.
# WS_PATH (not repo_root) anchors the bind-mounted kit/logs: the compose mount
# is ${WS_PATH}/isaac-sim/kit/logs, and WS_PATH may differ from the repo root.
USER_NAME=""
IMAGE_NAME="isaac"
WS_PATH=""
# shellcheck source=/dev/null
[ -f "${repo_root}/.env.generated" ] && . "${repo_root}/.env.generated"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env" ] && . "${repo_root}/.env"

# Compose-project isolation (owv#55). The nightly smoke brings its stack up
# under a DEDICATED instance and tears it down by the instance-scoped names,
# so it can never reap a co-hosted manually-run DEFAULT stream stack
# (`./script/run.sh -t stream -d`) on a shared GPU host, nor no-op on the
# stale pre-isaac#238 literal `owv` viewer name. `--instance ${instance}`
# makes run.sh export INSTANCE_SUFFIX=-${instance}; compose.yaml suffixes the
# stream container and post/run.sh suffixes the viewer to match, so the
# names below are exactly what this run creates. Default `smoke`; override
# SMOKE_COMPOSE_INSTANCE (e.g. the CI run id) for a per-run-unique project.
instance="${SMOKE_COMPOSE_INSTANCE:-smoke}"
container="${USER_NAME}-${IMAGE_NAME}-stream-${instance}"
viewer="${USER_NAME}-${IMAGE_NAME}-owv-${instance}"
smoke_log="${WS_PATH:-${repo_root}}/isaac-sim/kit/logs/stream-smoke.log"
client_pid=""

# Signal port the client attaches to. Resolve it the same way the post-run
# hook does (#231): config/host.yaml `livestream.ports.signal` wins, then an
# ISAAC_SIGNAL_PORT already in env, then Kit's own default. Probing the
# wrong port would look exactly like "the client never reached Kit".
# shellcheck source=../host_yaml.sh
. "${HOST_YAML_LIB:-${repo_root}/script/host_yaml.sh}"
signal_port="$(resolve_port "${repo_root}/config/host.yaml" signal)" || exit 1
signal_port="${signal_port:-${ISAAC_SIGNAL_PORT:-49100}}"

cleanup() {
  echo "[smoke] teardown: removing ${container} + ${viewer}"
  if [[ -n "${client_pid}" ]]; then
    kill "${client_pid}" 2>/dev/null || true
  fi
  docker rm -f "${container}" "${viewer}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Bind the library's fail-closed liveness hook to this run's container.
smoke_alive() {
  docker ps --format '{{.Names}}' | grep -qx "${container}"
}

fail() {
  printf '[smoke] FAIL: %s\n' "$*"
  smoke_log_tail "${smoke_log}" "${log_tail_n}"
  exit 1
}

# Start clean: drop any stale container/viewer from a prior run so we never
# mistake a leftover for this run's Isaac, and so the kit log is fresh.
echo "[smoke] pre-clean stale ${container} + ${viewer}"
docker rm -f "${container}" "${viewer}" >/dev/null 2>&1 || true
rm -f "${smoke_log}" 2>/dev/null || true

echo "[smoke] bring up stream stage (idle container + viewer)"
# Direct wrapper call (matches the repo's own CI convention; no `just`
# dependency on the runner). The justfile `run` recipe is a 1:1 forward to this.
( cd "${repo_root}" && ./script/run.sh -t stream -d --instance "${instance}" )

echo "[smoke] launch Isaac (detached) in ${container}"
# Source the per-host livestream port env the post-run hook copied in when
# host.yaml pins any port (#231); absent => no-op, runheadless-host-config.sh
# (unchanged) falls back to its ISAAC_*_PORT-from-env defaults.
docker exec -d "${container}" \
  sh -c 'set -a; [ -f /etc/isaac/livestream-ports.env ] && . /etc/isaac/livestream-ports.env; set +a; /usr/local/bin/runheadless-host-config.sh > /isaac-sim/kit/logs/stream-smoke.log 2>&1'

echo "[smoke] wait up to ${timeout_s}s for: ${ready_marker}"
rc=0
smoke_wait_for "${smoke_log}" "${timeout_s}" "${poll_s}" \
  "${ready_marker}" || rc=$?
case "${rc}" in
  0) echo "[smoke] OK: Isaac WebRTC streaming server started" ;;
  2) fail "container ${container} is no longer running" ;;
  *) fail "streaming server did not start within ${timeout_s}s" ;;
esac

# Hold the client for the whole assertion window plus margin, so it cannot
# time out on its own and make the dwell look like a stream drop.
client_hold_s=$(( connect_timeout_s + dwell_s + 30 ))
default_client_cmd="docker exec -d ${container} sh -c \"curl -sS -N --http1.1 \
--max-time ${client_hold_s} \
-H 'Connection: Upgrade' -H 'Upgrade: websocket' \
-H 'Sec-WebSocket-Version: 13' \
-H 'Sec-WebSocket-Key: c3RyZWFtLXNtb2tlLTIzMw==' \
http://127.0.0.1:${signal_port}/ >/dev/null 2>&1\""
client_cmd="${SMOKE_CLIENT_CMD:-${default_client_cmd}}"

echo "[smoke] attach client to signaling port ${signal_port}"
sh -c "${client_cmd}" >/dev/null 2>&1 &
client_pid=$!

echo "[smoke] wait up to ${connect_timeout_s}s for the stream-start sequence:"
printf '[smoke]   -> %s\n' "${stream_markers[@]}"
rc=0
smoke_wait_for "${smoke_log}" "${connect_timeout_s}" "${poll_s}" \
  "${stream_markers[@]}" || rc=$?
case "${rc}" in
  0) echo "[smoke] OK: client attached, all streams connected" ;;
  2) fail "Kit died while the client was attaching (the #233 regression)" ;;
  *) fail "streams did not start within ${connect_timeout_s}s of the attach" ;;
esac

# Anchor the drop scan at the connect line so a stale disconnect from an
# earlier session (or this run's own pre-connect noise) cannot fail us.
anchor_line="$(smoke_sequence_line "${smoke_log}" "${stream_markers[@]}")"

echo "[smoke] hold the connection for ${dwell_s}s (poll ${poll_s}s)"
rc=0
smoke_dwell "${smoke_log}" "${dwell_s}" "${poll_s}" "${anchor_line}" || rc=$?
case "${rc}" in
  0) : ;;
  2) fail "Kit died during the ${dwell_s}s dwell (the #233 regression)" ;;
  3) fail "streams stopped during the ${dwell_s}s dwell" ;;
  *) fail "dwell failed with rc ${rc}" ;;
esac

echo "[smoke] PASS: client streamed and Kit survived the ${dwell_s}s dwell"
exit 0
