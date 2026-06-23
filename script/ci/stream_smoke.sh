#!/usr/bin/env bash
# stream_smoke.sh -- producer-side GPU smoke for the stream stage.
#
# Verifies the GPU-only path that hosted CI runners cannot: the Isaac Sim
# stream container boots and its WebRTC streaming server actually starts.
# No browser -- that is Tier B (#173). Runs on a GPU host or a self-hosted
# GPU runner.
#
# Flow: `./script/run.sh -t stream -d` (idle container + viewer via post-run
# hook) -> `docker exec -d runheadless-host-config.sh` (launch Isaac) -> wait
# for the "Streaming server started." marker in OUR Isaac's kit log -> PASS /
# FAIL -> tear down (always).
#
# Readiness is asserted from OUR container's redirected kit log, not from a
# host port: the container runs with `network=host`, so `ss :PORT` would also
# match any unrelated Isaac left on the host (false pass), and the signaling
# socket binds early in startup -- before the stream server is actually up.
# `[carb.livestream-rtc.plugin] Streaming server started.` is the real
# "server up, waiting for a client" event and is scoped to our log.
#
# Env knobs:
#   SMOKE_TIMEOUT   seconds to wait for the marker (default 600)
#
# Exit 0 = streaming server up; 1 = container died / timeout (kit log tailed).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
timeout_s="${SMOKE_TIMEOUT:-600}"
ready_marker='Streaming server started.'

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
container="${USER_NAME}-${IMAGE_NAME}-stream"
smoke_log="${WS_PATH:-${repo_root}}/isaac-sim/kit/logs/stream-smoke.log"

cleanup() {
  echo "[smoke] teardown: removing ${container} + owv"
  docker rm -f "${container}" owv >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Start clean: drop any stale container/viewer from a prior run so we never
# mistake a leftover for this run's Isaac, and so the kit log is fresh.
echo "[smoke] pre-clean stale ${container} + owv"
docker rm -f "${container}" owv >/dev/null 2>&1 || true
rm -f "${smoke_log}" 2>/dev/null || true

echo "[smoke] bring up stream stage (idle container + viewer)"
# Direct wrapper call (matches the repo's own CI convention; no `just`
# dependency on the runner). The justfile `run` recipe is a 1:1 forward to this.
( cd "${repo_root}" && ./script/run.sh -t stream -d )

echo "[smoke] launch Isaac (detached) in ${container}"
docker exec -d "${container}" \
  sh -c '/usr/local/bin/runheadless-host-config.sh > /isaac-sim/kit/logs/stream-smoke.log 2>&1'

echo "[smoke] wait up to ${timeout_s}s for: ${ready_marker}"
deadline=$(( SECONDS + timeout_s ))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
    echo "[smoke] FAIL: container ${container} is no longer running"
    tail -n 60 "${smoke_log}" 2>/dev/null || true
    exit 1
  fi
  if grep -qF "${ready_marker}" "${smoke_log}" 2>/dev/null; then
    echo "[smoke] PASS: Isaac WebRTC streaming server started"
    exit 0
  fi
  sleep 5
done

echo "[smoke] FAIL: streaming server did not start within ${timeout_s}s"
tail -n 60 "${smoke_log}" 2>/dev/null || true
exit 1
